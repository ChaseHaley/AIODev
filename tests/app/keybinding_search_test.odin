package app_test

import app "../../src"
import "aio:commands"
import "aio:input"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
press :: proc(s: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}, unshifted: rune = 0) {
	app.handle_event(s, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true,
		unshifted = unshifted})
}

// Record mode takes app shortcuts and clipboard chords as the query on both surfaces, and a free chord
// typed in Settings reaches the palette's shortcut editor and the settings file.
@(test)
keybinding_search_records_app_chords_and_assigns_free_ones :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "KeySearch", second_window = false) {return}
	s := &f.state
	w := s.windows[0]

	app.palette_open_mode(s, w, .All)
	press(s, w, .K, {.Alt}, 'k')
	testing.expect(t, ui.palette_recording(&s.palette))
	press(s, w, .C, {.Control, .Shift}, 'c')
	if testing.expect_value(t, len(s.palette.results), 1) {
		testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "edit.copy")
	}
	press(s, w, .Escape)
	testing.expect(t, app.palette_active(s, w))
	testing.expect_value(t, ui.palette_query(&s.palette), "Ctrl+Shift+C")
	press(s, w, .Escape)
	testing.expect(t, !app.palette_active(s, w))

	app.editor_open(s, w)
	p := &w.editor
	press(s, w, .K, {.Alt}, 'k')
	testing.expect(t, ui.editor_recording(p))
	press(s, w, .C, {.Control, .Shift}, 'c')
	rows := 0
	for item in p.items {
		if item.row < 0 {continue}
		rows += 1
		testing.expect_value(t, p.rows[item.row].key, "keys.edit.copy")
	}
	testing.expect_value(t, rows, 1)
	press(s, w, .Escape)
	testing.expect_value(t, ui.field_string(&p.filter), "Ctrl+Shift+C")

	ui.field_set(&p.filter, "")
	app.handle_event(s, input.Text_Event{w.id, "ctrl shift g"})
	testing.expect_value(t, len(p.items), 0)
	press(s, w, .Enter)
	if !testing.expect(t, app.palette_active(s, w)) {return}
	testing.expect(t, s.palette.assign != nil)
	app.handle_event(s, input.Text_Event{w.id, "Split Right"})
	if !testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "pane.split_right") {
		return
	}
	press(s, w, .Enter)
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.Shortcut)
	press(s, w, .Enter)
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.None)
	bound := commands.find_by_shortcut(&s.registry, {.G, {.Control, .Shift}})
	if testing.expect(t, bound != nil) {testing.expect_value(t, bound.name, "pane.split_right")}
	saved, err := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect(t, strings.contains(string(saved), "keys.pane.split_right = Ctrl+Shift+O, Ctrl+Shift+G"))
}
