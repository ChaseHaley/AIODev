package app_test

import app "../../src"
import "aio:commands"
import "aio:platform"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"

@(private)
palette_binding_press_key :: proc(s: ^app.App, e: platform.Key_Event) {
	key := e
	key.window, key.pressed = s.windows[0].id, true
	app.handle_event(s, key)
}

@(private)
palette_binding_editor :: proc(s: ^app.App) -> ^ui.Editor {
	binding, open := &s.palette.edit.(ui.Shortcut_Edit)
	return open ? &binding.editor : nil
}

@(test)
palette_keybindings_capture_clipboard_chords_reject_conflicts_and_apply_without_settings :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "keybindings") {return}
	s := &f.state
	w := s.windows[0]
	app.palette_open_mode(s, w, .Commands)
	ui.palette_text(&s.palette, &s.registry, "Split Right")
	if !testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "pane.split_right") {return}
	before, read_error := os.read_entire_file(f.path, context.temp_allocator)
	if !testing.expect_value(t, read_error, nil) {return}
	palette_binding_press_key(s, {key = .Enter, modifiers = {.Control}})
	palette_binding_press_key(s, {key = .Enter})
	palette_binding_press_key(s, {key = .C, modifiers = {.Control}})
	b := palette_binding_editor(s)
	if !testing.expect(t, b != nil) {return}
	testing.expect_value(t, ui.field_string(&b.value), "Ctrl+C")
	palette_binding_press_key(s, {key = .C, modifiers = {.Control, .Shift}})
	palette_binding_press_key(s, {key = .Enter})
	b = palette_binding_editor(s)
	testing.expect(t, b != nil && ui.editor_capturing(b), "a conflicting binding remains editable")
	testing.expect(t, ui.palette_chosen_take(&s.palette) == nil, "handling the outcome took its value")
	after, after_error := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, after_error, nil)
	testing.expect_value(t, string(after), string(before))
	palette_binding_press_key(s, {key = .F9, modifiers = {.Control, .Alt}})
	palette_binding_press_key(s, {key = .Enter})
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.None)
	testing.expect(t, app.palette_active(s, w))
	testing.expect(t, !w.editor.open, "editing never opens Settings")
	bound := commands.find_by_shortcut(&s.registry, {.F9, {.Control, .Alt}})
	if testing.expect(t, bound != nil) {testing.expect_value(t, bound.name, "pane.split_right")}
	saved, saved_error := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, saved_error, nil)
	testing.expect(t, strings.contains(string(saved), "keys.pane.split_right = Ctrl+Alt+F9"))
	app.reload_settings(s, false)
	bound = commands.find_by_shortcut(&s.registry, {.F9, {.Control, .Alt}})
	if testing.expect(t, bound != nil) {testing.expect_value(t, bound.name, "pane.split_right")}
	palette_binding_press_key(s, {key = .Enter, modifiers = {.Control}})
	palette_binding_press_key(s, {key = .Enter})
	palette_binding_press_key(s, {key = .F10, modifiers = {.Control, .Alt}})
	palette_binding_press_key(s, {key = .Escape})
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.None)
	after, after_error = os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, after_error, nil)
	testing.expect_value(t, string(after), string(saved))
}
