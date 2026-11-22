package app_test

import app "../../src"
import "aio:settings"
import "core:encoding/json"
import "core:os"
import "core:testing"
import "cosmos:theme"


@(private)
json_text :: proc(value: json.Value) -> string {
	text, _ := value.(json.String)
	return string(text)
}

@(private)
json_number :: proc(value: json.Value) -> f64 {
	number, _ := value.(json.Float)
	return f64(number)
}

@(private)
json_flag :: proc(value: json.Value) -> bool {
	flag, _ := value.(json.Boolean)
	return bool(flag)
}
// The theme record as the app last wrote it, parsed from the file panes read.
@(private)
theme_record_read :: proc(t: ^testing.T, s: ^app.App) -> json.Object {
	path := settings.neovim_record_path(s.paths.local, context.temp_allocator)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_error, nil)
	value, parse_error := json.parse(data, spec = .JSON, allocator = context.temp_allocator)
	testing.expect_value(t, parse_error, json.Error.None)
	object, _ := value.(json.Object)
	return object
}

@(test)
theme_record_is_written_at_startup_and_follows_theme_changes :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "theme-record", second_window = false) {return}
	s := &f.state
	record := theme_record_read(t, s)
	testing.expect_value(t, json_text(record["theme"]), theme.DEFAULT_ID)
	testing.expect_value(t, json_number(record["generation"]), f64(1))
	testing.expect_value(t, json_flag(record["light"]), false)

	// A save that leaves the theme alone writes nothing.
	testing.expect(t, app.settings_save_value(s, "pane.gap", "6", "Could not save."))
	record = theme_record_read(t, s)
	testing.expect_value(t, json_number(record["generation"]), f64(1))

	testing.expect(t, app.settings_save_value(s, "theme.custom.paper.background", "#fafafa", "Could not save."))
	testing.expect(t, app.settings_save_value(s, "theme.name", "paper", "Could not save."))
	record = theme_record_read(t, s)
	testing.expect_value(t, json_text(record["theme"]), "paper")
	testing.expect_value(t, json_number(record["generation"]), f64(2))
	testing.expect_value(t, json_flag(record["light"]), true)
	_, has_neovim := record["neovim"]
	testing.expect(t, !has_neovim)

	// One color of the active custom theme changes the record too.
	testing.expect(t, app.settings_save_value(s, "theme.custom.paper.background", "#fbfbfb", "Could not save."))
	record = theme_record_read(t, s)
	testing.expect_value(t, json_number(record["generation"]), f64(3))
	colors, _ := record["colors"].(json.Object)
	testing.expect_value(t, json_text(colors["background"]), "#fbfbfb")
}
