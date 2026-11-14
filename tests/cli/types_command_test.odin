package cli_test

import "aio:cli"
import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
types_takes_a_data_directory_and_force :: proc(t: ^testing.T) {
	args := [?]string{"types", "--force", "--data-dir", `D:\data`, "--json"}
	o, problem := cli.parse_options(args[:], "")
	testing.expect_value(t, problem, "")
	testing.expect(t, o.typing && o.lua_types.force && o.json)
	testing.expect_value(t, o.lua_types.data_dir, `D:\data`)
	plain_args := [?]string{"--instance", "work", "types"}
	plain, plain_problem := cli.parse_options(plain_args[:], "")
	testing.expect_value(t, plain_problem, "")
	testing.expect(t, plain.typing && !plain.lua_types.force && !plain.json)
	testing.expect_value(t, plain.instance, "work")
	testing.expect_value(t, plain.lua_types.data_dir, "")
	failures := [][]string {
		{"types", "--data-dir"},
		{"types", "--data-dir", ""},
		{"types", "--data-dir", "a", "--data-dir", "b"},
		{"types", "--force", "--force"},
		{"--json", "types", "--json"},
		{"types", "--other"},
		{"types", "init.lua"},
	}
	for args in failures {
		_, failure := cli.parse_options(args, "")
		testing.expectf(t, failure != "", "%v should fail", args)
	}
}

@(private = "file")
read_text :: proc(t: ^testing.T, parts: []string) -> string {
	path, _ := filepath.join(parts, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	testing.expectf(t, err == nil, "%s should be readable", path)
	return string(data)
}

@(test)
types_copy_the_built_ins_and_create_luarc :: proc(t: ^testing.T) {
	root, root_error := os.make_directory_temp("", "aio-types-*", context.allocator)
	if !testing.expect_value(t, root_error, nil) {return}
	defer delete(root)
	defer testing.expect_value(t, os.remove_all(root), nil)
	// The folder aio.exe sits in holds the packaged built-ins; the data folder starts empty.
	install_parts := [2]string{root, "install"}
	install, _ := filepath.join(install_parts[:], context.temp_allocator)
	builtins_parts := [2]string{install, "types"}
	builtins_folder, _ := filepath.join(builtins_parts[:], context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(builtins_folder), nil) {return}
	builtins_file := [2]string{builtins_folder, "aio.lua"}
	builtins_path, _ := filepath.join(builtins_file[:], context.temp_allocator)
	source :: "---@meta\n---@class aio\naio = {}\n"
	if !testing.expect_value(t, os.write_entire_file(builtins_path, source), nil) {return}
	text, found := cli.types_builtins(install, context.temp_allocator)
	testing.expect(t, found)
	testing.expect_value(t, text, source)
	_, found_elsewhere := cli.types_builtins(root, context.temp_allocator)
	testing.expect(t, !found_elsewhere)

	data_parts := [2]string{root, "data"}
	data, _ := filepath.join(data_parts[:], context.temp_allocator)
	written, problem := cli.types_write(data, text, false, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(t, written.state, cli.Luarc_State.Created)
	written_parts := [3]string{data, "types", "aio.lua"}
	expected_path, _ := filepath.join(written_parts[:], context.temp_allocator)
	testing.expect_value(t, written.path, expected_path)
	luarc_parts := [2]string{data, ".luarc.json"}
	expected_luarc, _ := filepath.join(luarc_parts[:], context.temp_allocator)
	testing.expect_value(t, written.luarc, expected_luarc)
	testing.expect_value(t, read_text(t, written_parts[:]), source)
	testing.expect_value(t, read_text(t, luarc_parts[:]), cli.LUARC_TEXT)
	// The writes went through temporary files that the renames consumed.
	types_parts := [2]string{data, "types"}
	types_folder, _ := filepath.join(types_parts[:], context.temp_allocator)
	expect_only(t, types_folder, "aio.lua")
	expect_only(t, data, "types", ".luarc.json")
}

@(test)
types_keep_an_existing_luarc_unless_forced :: proc(t: ^testing.T) {
	data, data_error := os.make_directory_temp("", "aio-types-*", context.allocator)
	if !testing.expect_value(t, data_error, nil) {return}
	defer delete(data)
	defer testing.expect_value(t, os.remove_all(data), nil)
	luarc_parts := [2]string{data, ".luarc.json"}
	luarc, _ := filepath.join(luarc_parts[:], context.temp_allocator)
	mine :: `{"diagnostics.globals": ["vim"]}`
	if !testing.expect_value(t, os.write_entire_file(luarc, mine), nil) {return}
	kept, kept_problem := cli.types_write(data, "first", false, context.temp_allocator)
	testing.expect_value(t, kept_problem, "")
	testing.expect_value(t, kept.state, cli.Luarc_State.Kept)
	testing.expect_value(t, read_text(t, luarc_parts[:]), mine)
	file_parts := [3]string{data, "types", "aio.lua"}
	testing.expect_value(t, read_text(t, file_parts[:]), "first")
	// A second run replaces the definitions; --force replaces .luarc.json too.
	forced, forced_problem := cli.types_write(data, "second", true, context.temp_allocator)
	testing.expect_value(t, forced_problem, "")
	testing.expect_value(t, forced.state, cli.Luarc_State.Replaced)
	testing.expect_value(t, read_text(t, luarc_parts[:]), cli.LUARC_TEXT)
	testing.expect_value(t, read_text(t, file_parts[:]), "second")
	types_parts := [2]string{data, "types"}
	types_folder, _ := filepath.join(types_parts[:], context.temp_allocator)
	expect_only(t, types_folder, "aio.lua")
}

@(test)
types_report_a_folder_they_cannot_create :: proc(t: ^testing.T) {
	data, data_error := os.make_directory_temp("", "aio-types-*", context.allocator)
	if !testing.expect_value(t, data_error, nil) {return}
	defer delete(data)
	defer testing.expect_value(t, os.remove_all(data), nil)
	// A file where the types folder belongs.
	types_parts := [2]string{data, "types"}
	blocker, _ := filepath.join(types_parts[:], context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(blocker, "x"), nil) {return}
	_, problem := cli.types_write(data, "text", false, context.temp_allocator)
	testing.expect(t, problem != "")
	luarc_parts := [2]string{data, ".luarc.json"}
	luarc, _ := filepath.join(luarc_parts[:], context.temp_allocator)
	testing.expect(t, !os.exists(luarc))
}

// The folder holds exactly the named entries.
@(private = "file")
expect_only :: proc(t: ^testing.T, folder: string, names: ..string) {
	entries, err := os.read_all_directory_by_path(folder, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	count := len(names)
	testing.expectf(t, len(entries) == count, "%s holds %d entries, not %d", folder, len(entries), count)
	for entry in entries {
		known := false
		for name in names {if entry.name == name {known = true}}
		testing.expectf(t, known, "%s holds unexpected %s", folder, entry.name)
	}
}
