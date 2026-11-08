package instance_test

import "base:runtime"
import "core:testing"
import "core:strings"
import "aio:instance"

@(test)
defaults :: proc(t: ^testing.T) {
	options, err := instance.parse(nil)
	testing.expect_value(t, err, instance.Parse_Error.None)
	testing.expect_value(t, options, instance.Options{})
	testing.expect_value(t, instance.APP_NAME, "AIODev")
	testing.expect(t, len(instance.USAGE) > 0)
}

@(test)
flags_and_borrowing :: proc(t: ^testing.T) {
	for args in ([][]string{
		{"--instance", "Verify_123-x", "--data-dir", "C:\\test data\\漢字", "--no-activate"},
		{"--no-activate", "--data-dir", "C:\\test data\\漢字", "--instance", "Verify_123-x"},
		{"--data-dir", "C:\\test data\\漢字", "--instance", "Verify_123-x", "--no-activate"},
	}) {
		options, err := instance.parse(args)
		testing.expect_value(t, err, instance.Parse_Error.None)
		testing.expect_value(t, options, instance.Options{"Verify_123-x", "C:\\test data\\漢字", true})
		for arg, i in args {
			if arg == "--instance" {
				testing.expect(t, raw_data(options.name) == raw_data(args[i+1]))
			}
			if arg == "--data-dir" {
				testing.expect(t, raw_data(options.data_dir) == raw_data(args[i+1]))
			}
		}
	}
	for args in ([][]string{{"--no-activate"}, {"--data-dir", "."}, {"--instance", "a"}}) {
		_, err := instance.parse(args)
		testing.expect_value(t, err, instance.Parse_Error.None)
	}
}

@(test)
parse_errors :: proc(t: ^testing.T) {
	Case :: struct { args: []string, error: instance.Parse_Error }
	for item in ([]Case{
		{{"--unknown"}, .Unknown_Argument},
		{{"argument"}, .Unknown_Argument},
		{{""}, .Unknown_Argument},
		{{"--"}, .Unknown_Argument},
		{{"--instance=x"}, .Unknown_Argument},
		{{"--instance"}, .Missing_Value},
		{{"--data-dir"}, .Missing_Value},
		{{"--instance", "--no-activate"}, .Missing_Value},
		{{"--data-dir", "--instance", "x"}, .Missing_Value},
		{{"--instance", "x", "--instance", "y"}, .Repeated_Flag},
		{{"--data-dir", "x", "--data-dir", "y"}, .Repeated_Flag},
		{{"--no-activate", "--no-activate"}, .Repeated_Flag},
		{{"--instance", ""}, .Invalid_Name},
		{{"--instance", "123456789012345678901234567890123"}, .Invalid_Name},
		{{"--instance", "漢"}, .Invalid_Name},
		{{"--data-dir", ""}, .Empty_Data_Dir},
	}) {
		options, err := instance.parse(item.args)
		testing.expect_value(t, err, item.error)
		testing.expect_value(t, options, instance.Options{})
	}
}

@(test)
name_alphabet_and_boundaries :: proc(t: ^testing.T) {
	for value in 0..<256 {
		byte := u8(value)
		name := string((cast([^]u8)&byte)[:1])
		_, err := instance.parse([]string{"--instance", name})
		valid := byte >= 'a' && byte <= 'z' || byte >= 'A' && byte <= 'Z' ||
			byte >= '0' && byte <= '9' || byte == '-' || byte == '_'
		testing.expect_value(t, err, valid ? instance.Parse_Error.None : instance.Parse_Error.Invalid_Name)
		testing.expect_value(t, instance.valid_name(name), valid)
	}
	_, err := instance.parse([]string{"--instance", "12345678901234567890123456789012"})
	testing.expect_value(t, err, instance.Parse_Error.None)
	testing.expect(t, !instance.valid_name(""))
	testing.expect(t, !instance.valid_name("123456789012345678901234567890123"))
}

@(test)
identities :: proc(t: ^testing.T) {
	Case :: struct { name, id, log, layout: string }
	for item in ([]Case{
		{"", "AIODev", `C:\local\AIODev\logs\aiodev.log`, `C:\local\AIODev\layout.json`},
		{"test", "AIODev.test", `C:\local\AIODev\logs\aiodev.test.log`, `C:\local\AIODev\layout.test.json`},
		{"A-0_z", "AIODev.A-0_z", `C:\local\AIODev\logs\aiodev.A-0_z.log`, `C:\local\AIODev\layout.A-0_z.json`},
	}) {
		options := instance.Options{name = item.name}
		id, id_error := instance.app_id(options, context.allocator)
		defer delete(id)
		testing.expect_value(t, id_error, runtime.Allocator_Error.None)
		testing.expect_value(t, id, item.id)
		paths, paths_error := instance.paths_resolve(options, `C:\local`, `C:\roaming`)
		defer instance.paths_destroy(&paths)
		testing.expect_value(t, paths_error, runtime.Allocator_Error.None)
		testing.expect_value(t, paths.log, item.log)
		testing.expect_value(t, paths.layout, item.layout)
		// Named instances share the default instance's roaming settings file.
		testing.expect_value(t, paths.settings, `C:\roaming\AIODev\settings.ini`)
		testing.expect_value(t, paths.captures, "")
	}
}

@(test)
data_directory_paths :: proc(t: ^testing.T) {
	options := instance.Options{name = "verify", data_dir = `C:\repo\build\verify\verify`}
	paths, err := instance.paths_resolve(options, `C:\local`, `C:\roaming`)
	defer instance.paths_destroy(&paths)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect_value(t, paths.local, `C:\repo\build\verify\verify`)
	testing.expect_value(t, paths.logs, `C:\repo\build\verify\verify\logs`)
	testing.expect_value(t, paths.log, `C:\repo\build\verify\verify\logs\aiodev.verify.log`)
	testing.expect_value(t, paths.layout, `C:\repo\build\verify\verify\layout.verify.json`)
	testing.expect_value(t, paths.settings, `C:\repo\build\verify\verify\settings.ini`)
	testing.expect_value(t, paths.captures, `C:\repo\build\verify\verify\captures`)
	missing, missing_error := instance.paths_resolve({}, "", "")
	defer instance.paths_destroy(&missing)
	testing.expect_value(t, missing_error, runtime.Allocator_Error.None)
	testing.expect_value(t, missing, instance.Paths{})
}

@(test)
roaming_settings_on_this_machine :: proc(t: ^testing.T) {
	paths, err := instance.paths({name = "test"})
	defer instance.paths_destroy(&paths)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect(t, strings.has_suffix(paths.settings, `\AIODev\settings.ini`))
}

@(private)
fail_allocation :: proc(_: rawptr, _: runtime.Allocator_Mode, _, _: int,
	_: rawptr, _: int, _ := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	return nil, .Out_Of_Memory
}

@(test)
allocation_errors :: proc(t: ^testing.T) {
	allocator := runtime.Allocator{procedure = fail_allocation}
	for name in ([]string{"", "test"}) {
		options := instance.Options{name = name}
		id, id_error := instance.app_id(options, allocator)
		testing.expect_value(t, id_error, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, id, "")
		paths, paths_error := instance.paths_resolve(options, `C:\local`, `C:\roaming`, allocator)
		testing.expect_value(t, paths_error, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, paths, instance.Paths{})
	}
}
