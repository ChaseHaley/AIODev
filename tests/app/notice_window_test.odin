package app_test

import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:ui"
import "core:testing"
import "core:time"

@(private)
notice_expect_window :: proc(t: ^testing.T, s: ^app.App, owner: ^app.Window) {
	testing.expect_value(t, s.notice_window, owner.id)
	for w in s.windows {
		if !app.window_drawable(w) {continue}
		if !testing.expect(t, app.window_build_frame(s, w)) {return}
		point := notice_close_point(w)
		close_drawn := false
		for rect in w.list.rects {
			if rect.rect.x == point.x - 12*w.scale && rect.rect.y == point.y - 12*w.scale &&
			   rect.rect.width == 24*w.scale && rect.rect.height == 24*w.scale {
				close_drawn = true
			}
		}
		testing.expect_value(t, close_drawn, w == owner)
		testing.expect_value(t, app.pointer_target(s, w, point.x, point.y) == .Notice, w == owner)
	}
}

@(test)
notices_follow_window_focus_and_keep_their_identity_and_expiry :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "notice-window") {return}
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	now := time.tick_now()
	for len(s.notices.items) > 0 {ui.notices_dismiss(&s.notices, s.notices.items[0].id, false)}
	ui.notices_put(&s.notices, 0, .Info, "Only one window", time.Hour, false, now)
	id, expiry := s.notices.items[0].id, ui.notice_expiry(s.notices.items[0])
	// Inactive startup has no focus history; pick the first available window.
	notice_expect_window(t, s, first)
	for active in ([?]^app.Window{second, first, second}) {
		for w in s.windows {w.dirty = false}
		app.handle_event(s, platform.Focus_Event{active.id, true})
		// The gaining event can arrive before the previous window's loss event.
		notice_expect_window(t, s, active)
		testing.expect(t, first.dirty && second.dirty)
		other := active == first ? second : first
		app.handle_event(s, platform.Focus_Event{other.id, false})
		notice_expect_window(t, s, active)
		app.handle_event(s, platform.Focus_Event{active.id, false})
		notice_expect_window(t, s, active)
		testing.expect_value(t, s.notices.items[0].id, id)
		testing.expect_value(t, ui.notice_expiry(s.notices.items[0]), expiry)
	}
	close := notice_close_point(second)
	gesture_button(s, second, .Left, true, close.x, close.y)
	app.handle_event(s, platform.Focus_Event{first.id, true})
	gesture_button(s, second, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 1)
	notice_expect_window(t, s, first)
	close = notice_close_point(first)
	gesture_button(s, first, .Left, true, close.x, close.y)
	gesture_button(s, first, .Left, false, close.x, close.y)
	testing.expect_value(t, len(s.notices.items), 0)
}

@(test)
notices_fall_back_after_window_close_hide_minimize_and_preparation :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "notice-window-lifecycle") {return}
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.handle_event(s, platform.Focus_Event{first.id, true})
	app.handle_event(s, platform.Focus_Event{first.id, false})
	app.handle_event(s, platform.Focus_Event{second.id, true})
	app.handle_event(s, platform.Focus_Event{second.id, false})
	second.phase = .Preparing
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, first.id)
	second.phase, second.link = .Hidden, app.Window_Link{}
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, first.id)
	second.phase = .Shown
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, second.id)
	second.link = nil
	width := second.width
	second.width = 0
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, first.id)
	second.width = width
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, second.id)
	app.window_close(s, second)
	testing.expect_value(t, s.notice_window, first.id)
	first.phase = .Preparing
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, input.Window_Id(0))
	first.phase = .Shown
	app.window_notices_sync(s)
	testing.expect_value(t, s.notice_window, first.id)
}
