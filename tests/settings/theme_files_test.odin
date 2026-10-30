package settings_test

import "aio:settings"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

THEME_FIXTURE :: `{"version":1,"id":"shared","base":"studio-dark","colors":{"tab_bar":"#123456","border":"#12345680","selection_foreground":""}}`

@(test)
theme_files_validate_and_inherit :: proc(t: ^testing.T) {
	theme, issue := settings.theme_file_parse(THEME_FIXTURE)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, theme.id, "shared")
	resolved := settings.custom_theme_resolve(nil, &theme)
	testing.expect_value(t, resolved.colors[.Tab_Bar], settings.Theme_Color{0x12, 0x34, 0x56, 255})
	testing.expect_value(t, resolved.colors[.Border], settings.Theme_Color{0x12, 0x34, 0x56, 128})
	base := settings.theme_default()
	testing.expect_value(t, resolved.colors[.Text], base.colors[.Text])
	for invalid in ([?]string {
		`{}`, `[]`, THEME_FIXTURE + `{}`, `{ "version": 1, "version": 1 }`,
		fixture_replace(THEME_FIXTURE, `"version":1`, `"":1,"version":1`),
		fixture_replace(THEME_FIXTURE, `"selection_foreground":""`, `"selection_foreground":"",`),
		fixture_replace(THEME_FIXTURE, `"version":1`, `"version":2`),
		fixture_replace(THEME_FIXTURE, `"shared"`, `"../escape"`),
		fixture_replace(THEME_FIXTURE, `"studio-dark"`, `"Bad Base"`),
		fixture_replace(THEME_FIXTURE, `"tab_bar"`, `"typo"`),
		fixture_replace(THEME_FIXTURE, `"#123456"`, `"#12345680"`),
		fixture_replace(THEME_FIXTURE, `"#123456"`, `123`),
		`{"version":1,"id":"shared","colors":{},"extra":1}`,
		`{"colors":[[[[[[]]]]]]}`,
	}) {
		_, problem := settings.theme_file_parse(invalid)
		testing.expect(t, problem != "", invalid)
	}
}

@(test)
theme_export_roundtrips_every_color_and_preserves_files :: proc(t: ^testing.T) {
	directory, temp_error := os.mkdir_temp("tests/settings", "theme-", context.allocator)
	testing.expect_value(t, temp_error, nil)
	if temp_error != nil {return}
	defer delete(directory)
	defer os.remove_all(directory)
	s, d, error := settings.parse("theme.name = tide-light\n", themes_directory = THEMES)
	testing.expect_value(t, error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	first, first_error := settings.theme_export(&s, directory)
	testing.expect_value(t, first_error, nil)
	second, second_error := settings.theme_export(&s, directory)
	testing.expect_value(t, second_error, nil)
	testing.expect(t, first != second)
	data, read_error := os.read_entire_file(first, context.allocator)
	testing.expect_value(t, read_error, nil)
	defer delete(data)
	theme, issue := settings.theme_file_parse(string(data))
	testing.expect_value(t, issue, "")
	testing.expect_value(t, int(card(theme.overrides)), len(settings.THEME_TOKENS))
	testing.expect_value(t, settings.custom_theme_resolve(nil, &theme), s.active_theme)
	loaded, diagnostics, load_error := settings.parse(
		fmt.tprintf("theme.name = %s\n", theme.id), themes_directory = directory,
	)
	testing.expect_value(t, load_error, nil)
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, loaded.active_theme, s.active_theme)
}

@(test)
theme_discovery_isolates_bad_files_and_edits_shared_theme_as_copy :: proc(t: ^testing.T) {
	directory, temp_error := os.mkdir_temp("tests/settings", "theme-discovery-", context.allocator)
	testing.expect_value(t, temp_error, nil)
	if temp_error != nil {return}
	defer delete(directory)
	defer os.remove_all(directory)
	path := fmt.tprintf("%s/shared.theme.json", directory)
	testing.expect_value(t, os.write_entire_file(path, string(THEME_FIXTURE)), nil)
	testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/bad.theme.json", directory), []u8{'{'}), nil)
	source := "theme.name = shared\n"
	s, d, error := settings.parse(source, themes_directory = directory)
	testing.expect_value(t, error, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, len(d), 1)
	testing.expect_value(t, s.active_theme.colors[.Tab_Bar], settings.Theme_Color{0x12, 0x34, 0x56, 255})
	updated, created, issue, edit_error := settings.theme_color_edit(
		source, "accent", "#abcdef", themes_directory = directory,
	)
	defer delete(updated)
	defer delete(created)
	testing.expect_value(t, edit_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, created, "shared-custom")
	copy, cd, ce := settings.parse(updated, themes_directory = directory)
	defer settings.destroy(&copy)
	defer settings.diagnostics_destroy(&cd)
	testing.expect_value(t, ce, nil)
	testing.expect_value(t, copy.active_theme.colors[.Tab_Bar], s.active_theme.colors[.Tab_Bar])
	testing.expect_value(t, copy.active_theme.colors[.Accent], settings.Theme_Color{0xab, 0xcd, 0xef, 255})
	data, re := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect_value(t, re, nil)
	testing.expect_value(t, string(data), THEME_FIXTURE)
	local, ld, le := settings.parse(
		"theme.name = shared\ntheme.custom.shared.base = studio-dark\n", themes_directory = directory,
	)
	defer settings.destroy(&local)
	defer settings.diagnostics_destroy(&ld)
	testing.expect_value(t, le, nil)
	testing.expect_value(t, local.active_theme, settings.theme_default())
}

@(test)
theme_schema_tracks_the_token_catalogue :: proc(t: ^testing.T) {
	text, ok := settings.theme_schema_text()
	testing.expect(t, ok)
	defer delete(text)
	value, error := json.parse(text, spec = .JSON)
	testing.expect_value(t, error, json.Error.None)
	defer json.destroy_value(value)
	root := value.(json.Object)
	properties := root["properties"].(json.Object)
	colors := properties["colors"].(json.Object)
	tokens := colors["properties"].(json.Object)
	testing.expect_value(t, len(tokens), len(settings.THEME_TOKENS))
	for info in settings.THEME_TOKENS {testing.expect(t, info.key in tokens)}
	checked_in, read_error := os.read_entire_file("themes/theme.schema.json", context.allocator)
	testing.expect_value(t, read_error, nil)
	defer delete(checked_in)
	testing.expect_value(t, string(checked_in), text)
}

fixture_replace :: proc(source, old, replacement: string) -> string {
	result, _ := strings.replace_all(source, old, replacement, context.temp_allocator)
	return result
}
