package settings_test

import "base:runtime"
import "core:testing"
import "core:strings"
import "core:os"
import "aio:settings"

@(test)
round_trip :: proc(t: ^testing.T) {
	text, text_error := settings.default_text()
	testing.expect_value(t, text_error, nil)
	defer delete(text)
	s, d, parse_error := settings.parse(text)
	testing.expect_value(t, parse_error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	baseline, baseline_error := settings.defaults()
	defer settings.destroy(&baseline)
	testing.expect_value(t, baseline_error, nil)
	expect_settings(t, s, baseline)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, s.font.family, "Cascadia Mono")
	testing.expect_value(t, s.font.size, 12)
	testing.expect_value(t, s.interface.hover_lift, 1.5)
	testing.expect_value(t, s.interface.hover_gloss, 1.0)
	testing.expect_value(t, s.shell.directory, "~")
	testing.expect_value(t, s.window.columns, 120)
	testing.expect_value(t, s.colors.palette[15], settings.Color{0xf4, 0xf4, 0xf7})
	testing.expect_value(t, s.colors.selection_foreground, nil)
	for entry in settings.SCHEMA {
		testing.expect(t, strings.contains(text, entry.description))
		testing.expect(t, strings.contains(text, entry.key))
	}
	testing.expect(t, strings.contains(text, "\n\n# Shell"))
}

@(test)
parsing :: proc(t: ^testing.T) {
	fixture :: `  # comment

font.family = "  Mono  "
shell.command = cmd /c echo #hello
shell.directory = ~
cursor.style = underline
cursor.blink = true
colors.cursor = #aB12Ef
colors.selection_foreground = #123456
window.rows = 1`
	s, d, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, s.font.family, "  Mono  ")
	testing.expect_value(t, s.shell.command, "cmd /c echo #hello")
	testing.expect_value(t, s.shell.directory, "~")
	testing.expect_value(t, s.cursor.style, settings.Cursor_Style.Underline)
	testing.expect_value(t, s.cursor.blink, true)
	testing.expect_value(t, s.colors.cursor, settings.Color{0xab, 0x12, 0xef})
	testing.expect_value(t, s.colors.selection_foreground,
		Maybe(settings.Color)(settings.Color{0x12, 0x34, 0x56}))
	testing.expect_value(t, s.window.rows, 1)
	crlf, crlf_allocated := strings.replace_all(fixture, "\n", "\r\n")
	defer if crlf_allocated {
		delete(crlf)
	}
	testing.expect_value(t, crlf_allocated, true)
	bom, bom_error := strings.concatenate({"\xef\xbb\xbf", crlf})
	defer delete(bom)
	testing.expect_value(t, bom_error, nil)
	windows_settings, windows_diagnostics, windows_error := settings.parse(bom)
	defer settings.destroy(&windows_settings)
	defer settings.diagnostics_destroy(&windows_diagnostics)
	testing.expect_value(t, windows_error, nil)
	testing.expect_value(t, len(windows_diagnostics), 0)
	expect_settings(t, windows_settings, s)
}

@(test)
diagnostics :: proc(t: ^testing.T) {
	fixture :: `unknown = 1
missing separator
font.size = 0
cursor.blink = TRUE
cursor.style = Block
colors.cursor = blu
window.rows = 55
window.rows = nope
font.family = "broken
font.line_height = NaN
font.family = ""
font.size = twelve
font.family = `
	s, d, err := settings.parse(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	expected := []settings.Diagnostic{
		{1, "unknown", `unknown key "unknown"; expected a key from the settings schema`, .Unknown_Key},
		{2, "missing separator", `expected "key = value"`, .Malformed_Line},
		{3, "font.size", "0 is out of range 1..200", .Out_Of_Range},
		{4, "cursor.blink", `invalid boolean "TRUE", expected true or false`, .Invalid_Value},
		{5, "cursor.style", `"Block" is not one of block, bar, underline`, .Invalid_Value},
		{6, "colors.cursor", `invalid color "blu", expected #rrggbb`, .Invalid_Value},
		{8, "window.rows", `duplicate key "window.rows"; last value wins`, .Duplicate_Key},
		{8, "window.rows", `invalid integer "nope", expected a decimal integer`, .Invalid_Value},
		{9, "font.family", "expected a closing double quote", .Invalid_Value},
		{10, "font.line_height", "NaN is out of range 0.5..4", .Out_Of_Range},
		{11, "font.family", `duplicate key "font.family"; last value wins`, .Duplicate_Key},
		{11, "font.family", "string length is out of range 1..256 UTF-8 bytes", .Out_Of_Range},
		{12, "font.size", `duplicate key "font.size"; last value wins`, .Duplicate_Key},
		{12, "font.size", `invalid number "twelve", expected a number`, .Invalid_Value},
		{13, "font.family", `duplicate key "font.family"; last value wins`, .Duplicate_Key},
		{13, "font.family", "string length is out of range 1..256 UTF-8 bytes", .Out_Of_Range},
	}
	testing.expect_value(t, len(d), len(expected))
	for actual, i in d {
		if i >= len(expected) { break }
		testing.expect_value(t, actual, expected[i])
	}
	testing.expect_value(t, s.window.rows, 32)
	testing.expect_value(t, s.font.size, 12)
	testing.expect_value(t, s.font.family, "Cascadia Mono")
}

@(test)
duplicates_and_limits :: proc(t: ^testing.T) {
	s, d, parse_error := settings.parse(`window.rows = 1
window.rows = 32767
window.padding = 0
scrollback.lines = 0
font.size = 200
font.line_height = 4
colors.selection_foreground = #ffffff
colors.selection_foreground =
`)
	testing.expect_value(t, parse_error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, len(d), 2)
	testing.expect_value(t, s.window.rows, 32767)
	testing.expect_value(t, s.window.padding, 0)
	testing.expect_value(t, s.scrollback.lines, 0)
	testing.expect_value(t, s.font.size, 200)
	testing.expect_value(t, s.font.line_height, 4)
	testing.expect_value(t, s.colors.selection_foreground, nil)
}

@(test)
paths :: proc(t: ^testing.T) {
	path, err := settings.default_path()
	defer delete(path)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.has_suffix(path, "\\AIODev\\settings.ini"))
	home, home_error := os.user_home_dir(context.allocator)
	defer delete(home)
	
	for input in ([]string{"~", "~/child", "~\\child", "~other", "relative"}) {
		output, expand_error := settings.expand_home(input)
		defer delete(output)
		if input == "~" || strings.has_prefix(input, "~/") || strings.has_prefix(input, "~\\") {
			testing.expect_value(t, expand_error, home_error)
			if home_error != nil { continue }
		} else { testing.expect_value(t, expand_error, nil) }
		if input == "~" {
			testing.expect_value(t, output, home)
		}
		if strings.has_prefix(input, "~/") || strings.has_prefix(input, "~\\") {
			testing.expect(t, strings.has_prefix(output, home))
		} else if input != "~" { testing.expect_value(t, output, input) }
	}
}

@(test)
file_lifecycle :: proc(t: ^testing.T) {
	directory, directory_error := os.mkdir_temp("tests/settings", "io-", context.allocator)
	testing.expect_value(t, directory_error, nil)
	if directory_error != nil { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path, path_error := strings.concatenate({directory, "/nested/settings.ini"})
	testing.expect_value(t, path_error, nil)
	if path_error != nil { return }
	defer delete(path)
	s, d, created, migrated, migration_error, err := settings.load(path, extra_comments = {"keys.edit.copy = Ctrl+C"})
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect(t, created)
	testing.expect_value(t, migrated, false)
	testing.expect_value(t, migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(d), 0)
	if err != nil { return }
	text, text_error := settings.default_text(extra_comments = {"keys.edit.copy = Ctrl+C"})
	defer delete(text)
	testing.expect_value(t, text_error, nil)
	bytes, read_error := os.read_entire_file(path, context.allocator)
	defer delete(bytes)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(bytes), text)
	loaded, loaded_diagnostics, loaded_created, loaded_migrated, loaded_migration_error, loaded_error := settings.load(path, extra_comments = {"keys.edit.copy = Ctrl+C"})
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&loaded_diagnostics)
	testing.expect_value(t, loaded_error, nil)
	testing.expect_value(t, loaded_created, false)
	testing.expect_value(t, loaded_migrated, false)
	testing.expect_value(t, loaded_migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(loaded_diagnostics), 0)
	expect_settings(t, loaded, s)
	modified_text :: `font.family = Custom
font.size = invalid
`
	testing.expect_value(t, os.write_entire_file(path, modified_text), nil)
	modified, modified_diagnostics, modified_created, modified_migrated, modified_migration_error, modified_error := settings.load(path, extra_comments = {"keys.edit.copy = Ctrl+C"})
	defer settings.destroy(&modified)
	defer settings.diagnostics_destroy(&modified_diagnostics)
	testing.expect_value(t, modified_error, nil)
	testing.expect_value(t, modified_created, false)
	testing.expect_value(t, modified_migrated, false)
	testing.expect_value(t, modified_migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(modified_diagnostics), 1)
	testing.expect_value(t, modified.font.family, "Custom")
	testing.expect_value(t, modified.font.size, 12)
	bad, bad_diagnostics, bad_created, bad_migrated, bad_migration_error, bad_error := settings.load(directory)
	defer settings.destroy(&bad)
	defer settings.diagnostics_destroy(&bad_diagnostics)
	testing.expect(t, bad_error != nil)
	testing.expect_value(t, bad_created, false)
	testing.expect_value(t, bad_migrated, false)
	testing.expect_value(t, bad_migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(bad_diagnostics), 0)
	blocked, blocked_path_error := strings.concatenate({path, "/child/settings.ini"})
	defer delete(blocked)
	testing.expect_value(t, blocked_path_error, nil)
	failed, failed_diagnostics, failed_created, failed_migrated, failed_migration_error, failed_error := settings.load(blocked)
	defer settings.destroy(&failed)
	defer settings.diagnostics_destroy(&failed_diagnostics)
	testing.expect(t, failed_error != nil)
	testing.expect_value(t, failed_created, false)
	testing.expect_value(t, failed_migrated, false)
	testing.expect_value(t, failed_migration_error, settings.Save_Error.None)
	testing.expect_value(t, len(failed_diagnostics), 0)
}

@(test)
invalid_values :: proc(t: ^testing.T) {
	cases := []string{
		"font.family =", "shell.command = \"\"", "shell.directory = \"",
		"font.family = \xff", "font.family = a\x00b",
		"font.size = 201", "font.size = -1", "font.size = 12tail",
		"font.line_height = 0.49", "font.line_height = 4.01", "font.line_height = +Inf",
		"window.columns = 32768", "window.columns = 0", "window.rows = -1",
		"window.padding = -1", "window.padding = 1025", "scrollback.lines = 10000001",
		"window.rows = 999999999999999999999999999999999", "window.rows = 2 # comment",
		"cursor.style = unknown", "cursor.blink = 1", "terminal.copy_on_select = False",
		"colors.foreground = #gg1234", "colors.background = 0f1115",
		"colors.selection_foreground = #12345678", "cursor.blink = true # comment",
	}
	baseline, baseline_error := settings.defaults()
	defer settings.destroy(&baseline)
	testing.expect_value(t, baseline_error, nil)
	for text in cases {
		s, d, err := settings.parse(text)
		defer settings.destroy(&s)
		defer settings.diagnostics_destroy(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(d), 1)
		expect_settings(t, s, baseline)
	}
}

@(test)
ownership :: proc(t: ^testing.T) {
	input, input_error := strings.clone(`font.family = Owned
unknown = value`)
	testing.expect_value(t, input_error, nil)
	s, d, err := settings.parse(input)
	delete(input)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, s.font.family, "Owned")
	testing.expect_value(t, len(d), 1)
	testing.expect_value(t, d[0].key, "unknown")
	testing.expect_value(t, d[0].message, `unknown key "unknown"; expected a key from the settings schema`)
	partial := settings.Settings{}
	settings.destroy(&partial)
	settings.destroy(&partial)
}

Failure_Allocator :: struct {
	backing: runtime.Allocator,
	remaining: int,
}

@(require_results)
failure_allocate :: proc(
	user: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]u8, runtime.Allocator_Error) {
	state := cast(^Failure_Allocator)user
	allocating := mode == .Alloc || mode == .Alloc_Non_Zeroed ||
	              mode == .Resize || mode == .Resize_Non_Zeroed
	if size > 0 && allocating {
		if state.remaining == 0 { return nil, .Out_Of_Memory }
		state.remaining -= 1
	}
	return state.backing.procedure(
		state.backing.data, mode, size, alignment, old_memory, old_size, location,
	)
}

@(test)
allocation_failures :: proc(t: ^testing.T) {
	for limit in 0..<64 {
		state := Failure_Allocator{context.allocator, limit}
		allocator := runtime.Allocator{failure_allocate, &state}
		s, d, err := settings.parse(`font.family = Replacement
unknown = x
window.rows = 0
window.rows = 4
shell.command = Replacement
keys.edit.copy = Ctrl+C
keys.edit.copy = Ctrl+Insert`, allocator)
		settings.destroy(&s)
		settings.diagnostics_destroy(&d)
		testing.expect(t, err == nil || err == .Out_Of_Memory)
		state.remaining = limit
		generated, generated_error := settings.default_text(allocator, {"keys.edit.copy = Ctrl+C"})
		delete(generated, allocator)
		testing.expect(t, generated_error == nil || generated_error == .Out_Of_Memory)
	}
	text, text_error := settings.default_text(runtime.nil_allocator())
	testing.expect_value(t, text, "")
	testing.expect_value(t, text_error, runtime.Allocator_Error.Out_Of_Memory)
	path, path_error := settings.expand_home("relative", runtime.nil_allocator())
	testing.expect_value(t, path, "")
	testing.expect_value(t, path_error, os.Error(runtime.Allocator_Error.Out_Of_Memory))
}

expect_settings :: proc(t: ^testing.T, actual, expected: settings.Settings) {
	testing.expect_value(t, actual.font, expected.font)
	testing.expect_value(t, actual.shell, expected.shell)
	testing.expect_value(t, actual.window, expected.window)
	testing.expect_value(t, actual.scrollback, expected.scrollback)
	testing.expect_value(t, actual.terminal, expected.terminal)
	testing.expect_value(t, actual.cursor, expected.cursor)
	testing.expect_value(t, actual.colors, expected.colors)
	testing.expect_value(t, len(actual.keys), len(expected.keys))
	for binding, i in actual.keys {
		if i < len(expected.keys) { testing.expect_value(t, binding, expected.keys[i]) }
	}
}
@(test)
key_bindings :: proc(t: ^testing.T) {
	fixture, clone_error := strings.clone("keys.edit.copy = Ctrl+Shift+C, Ctrl+Insert\r\n" +
		"keys.unknown.command = not a chord\r\nkeys.edit.copy =\r\nkeys. = Ctrl+A\r\n")
	if !testing.expect_value(t, clone_error, nil) { return }
	s, diagnostics, err := settings.parse(fixture)
	delete(fixture)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(s.keys), 3)
	testing.expect_value(t, s.keys[0], settings.Key_Binding{"edit.copy", "", 3})
	testing.expect_value(t, s.keys[1], settings.Key_Binding{"unknown.command", "not a chord", 2})
	testing.expect_value(t, s.keys[2], settings.Key_Binding{"", "Ctrl+A", 4})
	testing.expect_value(t, len(diagnostics), 1)
	testing.expect_value(t, diagnostics[0].kind, settings.Diagnostic_Kind.Duplicate_Key)
	testing.expect_value(t, diagnostics[0].line, 3)
	testing.expect_value(t, diagnostics[0].key, "keys.edit.copy")
	testing.expect_value(t, settings.diagnostic_append(&diagnostics, 2,
		"keys.unknown.command", "unknown command name"), nil)
	testing.expect_value(t, diagnostics[1].message, "unknown command name")
	text, text_error := settings.default_text(extra_comments = {"keys.edit.copy = Ctrl+Shift+C, Ctrl+Insert"})
	defer delete(text)
	testing.expect_value(t, text_error, nil)
	testing.expect(t, strings.has_suffix(text, "# keys.edit.copy = Ctrl+Shift+C, Ctrl+Insert\n"))
	parsed, parsed_diagnostics, parsed_error := settings.parse(text)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&parsed_diagnostics)
	testing.expect_value(t, parsed_error, nil)
	testing.expect_value(t, len(parsed.keys), 0)
	testing.expect_value(t, len(parsed_diagnostics), 0)
}

@(test)
vertical_scope_defaults_to_all_and_reports_an_invalid_choice_by_line :: proc(t: ^testing.T) {
	defaults, default_error := settings.defaults()
	if !testing.expect_value(t, default_error, nil) {return}
	defer settings.destroy(&defaults)
	testing.expect_value(t, defaults.tabs.vertical_scope, settings.Tabs_Scope.All)

	s, diagnostics, parse_error := settings.parse("tabs.vertical_scope = workspace\n")
	if !testing.expect_value(t, parse_error, nil) {return}
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, s.tabs.vertical_scope, settings.Tabs_Scope.Workspace)
	testing.expect_value(t, len(diagnostics), 0)

	invalid, invalid_diagnostics, invalid_error := settings.parse(
		"theme.mode = dark\ntabs.vertical_scope = panes\n",
	)
	if !testing.expect_value(t, invalid_error, nil) {return}
	defer settings.destroy(&invalid)
	defer settings.diagnostics_destroy(&invalid_diagnostics)
	testing.expect_value(t, invalid.tabs.vertical_scope, settings.Tabs_Scope.All)
	if !testing.expect_value(t, len(invalid_diagnostics), 1) {return}
	testing.expect_value(t, invalid_diagnostics[0].line, 2)
	testing.expect_value(t, invalid_diagnostics[0].key, "tabs.vertical_scope")
	testing.expect_value(t, invalid_diagnostics[0].kind, settings.Diagnostic_Kind.Invalid_Value)
}
