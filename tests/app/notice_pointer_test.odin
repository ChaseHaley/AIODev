package app_test

import app "../../src"
import "aio:platform"
import "aio:ui"
import "core:testing"
import "core:time"

@(private)
notice_close_point :: proc(w: ^app.Window) -> [2]f32 {
	strong := ui.text_styled(&w.ui_text, .Strong)
	height := max(strong.line_height, 24*w.scale) + 28*w.scale + w.ui_text.line_height
	return {f32(w.width) - 40*w.scale, f32(w.height) - 16*w.scale - height + 24*w.scale}
}

@(test)
notice_pointer_owns_clicks_and_requires_the_same_live_notice_on_release :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "notice-pointer", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	ui.notices_set_animations(&s.notices, false)
	for len(s.notices.items) > 0 {ui.notices_dismiss(&s.notices, s.notices.items[0].id)}
	ui.notices_put(&s.notices, 0, .Info, "First", time.Hour)
	ui.notices_put(&s.notices, 0, .Success, "Second", 0)
	close := notice_close_point(w)
	testing.expect_value(t, app.pointer_target(s, w, close.x, close.y), app.Pointer_Target.Notice)
	pointer_expect_move(t, s, w, close.x, close.y, .Hand)
	testing.expect_value(t, w.notice_hover, s.notices.items[1].id)
	gesture_button(s, w, .Left, true, close.x, close.y)
	testing.expect(t, !w.selecting)
	gesture_button(s, w, .Left, false, 200, 200)
	testing.expect_value(t, len(s.notices.items), 2)
	gesture_button(s, w, .Right, true, close.x, close.y)
	gesture_button(s, w, .Right, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 2)
	testing.expect(t, !app.tab_menu_shown(w))
	gesture_button(s, w, .Left, true, close.x-40*w.scale, close.y)
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 2)
	gesture_button(s, w, .Left, true, close.x, close.y)
	app.handle_event(s, platform.Focus_Event{window = w.id, focused = false})
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 2)
	gesture_button(s, w, .Left, true, close.x, close.y)
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 1)
	testing.expect_value(t, s.notices.items[0].text, "First")

	gesture_button(s, w, .Left, true, close.x, close.y)
	ui.notices_expire(&s.notices, time.tick_add(time.tick_now(), 2*time.Hour))
	ui.notices_put(&s.notices, 0, .Warning, "Replacement", 0)
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 1)
	testing.expect_value(t, s.notices.items[0].text, "Replacement")

	app.palette_open(s, w)
	testing.expect_value(t, app.pointer_target(s, w, close.x, close.y), app.Pointer_Target.Notice)
	gesture_button(s, w, .Left, true, close.x, close.y)
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 0)
	testing.expect(t, app.palette_active(s, w))
	testing.expect(t, !w.selecting && w.notice_buttons == {})
}
