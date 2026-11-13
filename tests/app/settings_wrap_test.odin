package app_test

import "aio:input"
import "core:testing"
import app "../../src"
import "aio:ui"

// The window fits its Settings page with its own interface text, so a long description wraps there
// and wraps again when the type size changes; the pointer over its last line is over its row.
@(test)
settings_window_wraps_descriptions_with_its_text :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "settings-wrap", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	app.settings_reveal_page(&w.editor, {key = "control.enabled", query = "command line control", search = .Scope})
	before := wrapped_row_height(t, w)
	if before <= 0 {return}
	ui.text_set_size(&w.ui_text, w.ui_text.size_px * 1.5)
	testing.expect(t, wrapped_row_height(t, w) > before, "a larger type size wraps to taller lines")
	l := app.settings_layout(w)
	index := wrapped_row_item(&w.editor)
	parts := ui.editor_row_parts(&w.editor, l, index)
	x := i32(parts.row.x + 60)
	last_line := i32(parts.row.y + parts.row.height - 4)
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = x, y = last_line})
	testing.expect_value(t, w.editor.hover_item, index)
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = x, y = last_line + 8})
	testing.expect(t, w.editor.hover_item != index, "below the wrapped row is past it")
}

@(private = "file")
wrapped_row_item :: proc(p: ^ui.Editor) -> int {
	for item, index in p.items {
		if item.row >= 0 && item.part == 0 && p.rows[item.row].key == "control.enabled" {return index}
	}
	return -1
}

// The height of the control.enabled row, which must be taller than one line at the window's width.
@(private = "file")
wrapped_row_height :: proc(t: ^testing.T, w: ^app.Window) -> f32 {
	l := app.settings_layout(w)
	index := wrapped_row_item(&w.editor)
	if !testing.expect(t, index >= 0) {return 0}
	height := ui.editor_row_parts(&w.editor, l, index).row.height
	testing.expect(t, height > l.row_height, "the description wraps below the row's first line")
	return height
}
