package app_test

import "core:testing"
import app "../../src"
import "aio:platform"
import w "core:sys/windows"

@(private)
gesture_dispatch_pending :: proc(t: ^testing.T, s: ^app.App) {
	events, err := platform.poll_events(&s.platform)
	if !testing.expect_value(t, err, platform.Error.None) {return}
	for event in events {app.handle_event(s, event)}
}

@(test)
gestures_native_capture_loss_cancels_armed_header_before_late_release :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-native") {return}
	s, window := &f.state, f.state.windows[0]
	app.pane_split(s, window, .Right)
	gesture_dispatch_pending(t, s)
	close := gesture_header(window).buttons[3]
	position := w.LPARAM(u32(close.x+4) | (u32(close.y+4) << 16))
	hwnd := w.HWND(platform.window_native_handle(&s.platform, window.id))
	w.SendMessageW(hwnd, w.WM_LBUTTONDOWN, w.MK_LBUTTON, position)
	gesture_dispatch_pending(t, s)
	if !testing.expect(t, .Left in window.header_buttons) {return}
	w.SendMessageW(hwnd, w.WM_CANCELMODE, 0, 0)
	w.SendMessageW(hwnd, w.WM_LBUTTONUP, 0, position)
	gesture_dispatch_pending(t, s)
	testing.expect(t, window.header_buttons == {} && !window.pane_drag.pressed)
	testing.expect_value(t, len(window.panes), 2)
	testing.expect_value(t, len(s.sessions), 3)
	testing.expect(t, w.GetCapture() != hwnd)
}
