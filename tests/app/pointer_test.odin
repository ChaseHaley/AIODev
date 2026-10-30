package app_test

import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:render"
import "aio:ui"

@(private)
pointer_expect_move :: proc(
	t: ^testing.T,
	s: ^app.App,
	w: ^app.Window,
	x, y: f32,
	shape: platform.Cursor_Shape,
) {
	before := s.verify.pointer_updates
	app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = i32(x), y = i32(y)})
	testing.expect_value(t, w.pointer_shape, shape)
	testing.expect(t, s.verify.pointer_updates - before <= 1, "one move must not flash another cursor")
}

@(test)
pointer_settings_page_and_fields_change_shape_once_per_move :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-settings") {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	l := app.settings_layout(w)
	for offset in 0 ..< 4 {
		pointer_expect_move(t, s, w, l.list.x - 8 * w.scale,
			l.list.y + l.row_height + f32(offset), .Arrow)
	}
	pointer_expect_move(t, s, w, l.filter.x + l.filter.width / 2,
		l.filter.y + l.filter.height / 2, .Text)
	h, found := gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	pointer_expect_move(t, s, w, h.title.x + h.title.width / 2,
		h.title.y + h.title.height / 2, .Arrow)
}

@(test)
pointer_palette_chip_and_menu_use_hand_query_uses_text :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-palette") {return}
	s, w := &f.state, f.state.windows[0]
	app.palette_open(s, w)
	for mode in ui.Palette_Mode {
		ui.palette_set_mode(&s.palette, &s.registry, mode)
		l := ui.palette_layout(&s.palette, f32(w.width), f32(w.height), w.scale)
		pointer_expect_move(t, s, w, l.input.x + l.input.width - 20 * w.scale,
			l.input.y + l.input.height / 2, .Text)
		if mode == .All {continue}
		pointer_expect_move(t, s, w, l.chip.x + l.chip.width / 2,
			l.chip.y + l.chip.height / 2, .Hand)
		gesture_button(s, w, .Left, true, l.chip.x + 4, l.chip.y + 4)
		gesture_button(s, w, .Left, false, l.chip.x + 4, l.chip.y + 4)
		if !testing.expect(t, s.palette.mode_menu) {continue}
		l = ui.palette_layout(&s.palette, f32(w.width), f32(w.height), w.scale)
		pointer_expect_move(t, s, w, l.menu.x + l.menu.width / 2,
			l.menu.y + l.menu.height / 2, .Hand)
		pointer_expect_move(t, s, w, l.footer.x + l.footer.width - 4,
			l.footer.y + l.footer.height / 2, .Arrow)
	}
}

@(private = "file")
pointer_center :: proc(r: render.Rect) -> (f32, f32) {return r.x + r.width / 2, r.y + r.height / 2}

@(test)
pointer_tabs_use_hand_except_on_the_selected_tab_body :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{false, true}) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "pointer-tabs", "profile.default.command = cmd.exe\n") {return}
		s, w := &f.state, f.state.windows[0]
		w.tabs_horizontal = horizontal
		w.width, w.height, w.scale = 1000, 700, 1
		w.rail_auto, w.rail_override = true, .Auto
		app.window_relayout(s, w)
		app.tab_new(s, w)
		app.tab_select(s, w, 0)
		app.update_motion(s)
		body, other, close: render.Rect
		if horizontal {
			body, other = app.window_tab_rect(s, w, 0), app.window_tab_rect(s, w, 1)
			close = app.window_tab_close_rect(s, w, 0)
		} else {
			l, ok := app.rail_current_layout(w)
			if !testing.expect(t, ok) {continue}
			body, other = app.rail_row_rect_for_tab(w, 0), app.rail_row_rect_for_tab(w, 1)
			close = ui.rail_close_rect(l, 0, w.scale)
		}
		x, y := pointer_center(close)
		pointer_expect_move(t, s, w, body.x + 6, body.y + body.height / 2, .Arrow)
		pointer_expect_move(t, s, w, x, y, .Hand)
		x, y = pointer_center(other)
		pointer_expect_move(t, s, w, other.x + 6, y, .Hand)
		x, y = pointer_center(app.tab_orientation_button_rect(w))
		pointer_expect_move(t, s, w, x, y, .Hand)
		pane := w.panes[0].rect
		pointer_expect_move(t, s, w, pane.x + pane.width / 2, pane.y + pane.height / 2, .Text)
	}
}

@(test)
pointer_settings_controls_use_hand :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-controls") {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	l := app.settings_layout(w)
	if !testing.expect(t, ui.editor_select_key(&w.editor, "pane.show_headers")) {return}
	x, y := pointer_center(ui.editor_row_parts(&w.editor, l, w.editor.selected).toggle)
	pointer_expect_move(t, s, w, x, y, .Hand)
	if !testing.expect(t, ui.editor_select_key(&w.editor, "font.family")) {return}
	parts := ui.editor_row_parts(&w.editor, l, w.editor.selected)
	x, y = pointer_center(parts.field)
	pointer_expect_move(t, s, w, x, y, .Text)
	x, y = pointer_center(parts.reset)
	pointer_expect_move(t, s, w, x, y, .Hand)
	h, found := gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	x, y = pointer_center(h.buttons[0])
	pointer_expect_move(t, s, w, x, y, .Hand)
}
