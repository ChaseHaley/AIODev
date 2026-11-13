package app_test

import "aio:input"
import "core:testing"
import app "../../src"
import "aio:platform"
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

// A description the page cuts short shows whole in the window's tooltip, and one it shows whole
// shows none: the row wraps at the starting width, and keeps one ellipsized line once the window
// leaves it less than 80 DIP.
@(test)
settings_cut_description_shows_whole_in_the_tooltip :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "settings-wrap-tooltip", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	app.settings_reveal_page(&w.editor, {key = "control.enabled", query = "command line control", search = .Scope})
	description := w.editor.rows[w.editor.items[wrapped_row_item(&w.editor)].row].description
	testing.expect_value(t, description_hover(s, w), "")
	// Narrow the window until the row leaves its description less than 80 DIP.
	for width in ([?]f32{600, 480, 400, 340, 300, 260}) {
		app.handle_event(s, platform.Resize_Event{window = w.id, width = i32(width * w.scale),
			height = w.height})
		l := app.settings_layout(w)
		parts := ui.editor_row_parts(&w.editor, l, wrapped_row_item(&w.editor))
		room := parts.text_right - (parts.row.x + (ui.CONTROL_INSET + ui.SPACE_6) * w.scale)
		if room < 80 * w.scale && room > 20 * w.scale {break}
	}
	testing.expect_value(t, description_hover(s, w), description)
}

// Moves the pointer over the first description line of control.enabled and returns the tooltip
// the window would show there.
@(private = "file")
description_hover :: proc(s: ^app.App, w: ^app.Window) -> string {
	l := app.settings_layout(w)
	r := ui.editor_row_parts(&w.editor, l, wrapped_row_item(&w.editor)).row
	small := ui.text_styled(&w.ui_text, .Detail)
	gap := 2 * w.scale
	top := r.y + (l.row_height - w.ui_text.line_height - gap - small.line_height) / 2
	x := r.x + (ui.CONTROL_INSET + ui.SPACE_6) * w.scale + 6 * w.scale
	y := top + w.ui_text.line_height + gap + small.line_height / 2
	e := input.Mouse_Move_Event{window = w.id, x = i32(x), y = i32(y)}
	app.handle_event(s, e)
	app.tooltip_hover(s, w, .Settings_Page, e)
	return app.tooltip_current(w)
}
