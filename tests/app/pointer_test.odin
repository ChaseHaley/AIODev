package app_test

import "core:testing"
import app "../../src"
import "aio:platform"
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
pointer_palette_chip_and_menu_use_arrow_query_uses_text :: proc(t: ^testing.T) {
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
			l.chip.y + l.chip.height / 2, .Arrow)
		gesture_button(s, w, .Left, true, l.chip.x + 4, l.chip.y + 4)
		gesture_button(s, w, .Left, false, l.chip.x + 4, l.chip.y + 4)
		if !testing.expect(t, s.palette.mode_menu) {continue}
		l = ui.palette_layout(&s.palette, f32(w.width), f32(w.height), w.scale)
		pointer_expect_move(t, s, w, l.menu.x + l.menu.width / 2,
			l.menu.y + l.menu.height / 2, .Arrow)
		pointer_expect_move(t, s, w, l.footer.x + l.footer.width - 4,
			l.footer.y + l.footer.height / 2, .Arrow)
	}
}
