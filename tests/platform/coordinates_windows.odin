package platform_test

import "core:testing"
import w "core:sys/windows"
import p "aio:platform"

@(test)
window_coordinate_round_trip_and_outer_position :: proc(t: ^testing.T) {
	platform: p.Platform
	_, _, err := p.window_to_screen(&platform, 1, 0, 0)
	testing.expect_value(t, err, p.Error.Invalid_Window)
	_, _, err = p.window_from_screen(&platform, 1, 0, 0)
	testing.expect_value(t, err, p.Error.Invalid_Window)
	testing.expect_value(t, p.window_set_position(&platform, 1, 0, 0), p.Error.Invalid_Window)
	_, _, _, err = p.window_at_point(&platform, 0, 0)
	testing.expect_value(t, err, p.Error.Not_Initialized)
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Coordinates"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	for tabbed in ([2]bool{false, true}) {
		id, create_error := p.window_create(&platform,
			{hidden = true, width = 240, height = 160, tabbed_title_bar = tabbed})
		if !testing.expect_value(t, create_error, p.Error.None) { return }
		hwnd := w.HWND(p.window_native_handle(&platform, id))
		for position in ([?][2]i32{{-320, -200}, {-120, 100}, {160, -80}, {100, 100}}) {
			foreground, focus := w.GetForegroundWindow(), w.GetFocus()
			testing.expect_value(t, p.window_set_position(&platform, id, position.x, position.y), p.Error.None)
			testing.expect_value(t, w.GetForegroundWindow(), foreground)
			testing.expect_value(t, w.GetFocus(), focus)
			rect: w.RECT
			if !testing.expect(t, bool(w.GetWindowRect(hwnd, &rect))) { return }
			testing.expect_value(t, rect.left, position.x)
			testing.expect_value(t, rect.top, position.y)
			width, height, size_error := p.window_client_size(&platform, id)
			testing.expect_value(t, size_error, p.Error.None)
			testing.expect_value(t, width, i32(240))
			testing.expect_value(t, height, i32(160))
			for point in ([?][2]i32{{0, 0}, {-50, -40}, {120, 90}, {400, 300}}) {
				x, y, screen_error := p.window_to_screen(&platform, id, point.x, point.y)
				testing.expect_value(t, screen_error, p.Error.None)
				expected := w.POINT{point.x, point.y}
				testing.expect(t, bool(w.ClientToScreen(hwnd, &expected)))
				testing.expect_value(t, x, expected.x)
				testing.expect_value(t, y, expected.y)
				client_x, client_y, client_error := p.window_from_screen(&platform, id, x, y)
				testing.expect_value(t, client_error, p.Error.None)
				testing.expect_value(t, client_x, point.x)
				testing.expect_value(t, client_y, point.y)
			}
		}
		testing.expect_value(t, p.window_destroy(&platform, id), p.Error.None)
		_, _, err = p.window_to_screen(&platform, id, 0, 0)
		testing.expect_value(t, err, p.Error.Invalid_Window)
		_, _, err = p.window_from_screen(&platform, id, 0, 0)
		testing.expect_value(t, err, p.Error.Invalid_Window)
		testing.expect_value(t, p.window_set_position(&platform, id, 0, 0), p.Error.Invalid_Window)
	}
}

@(test)
window_hit_testing_respects_owned_topmost_and_foreign_windows :: proc(t: ^testing.T) {
	platform, foreign_platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.HitOwned"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	if !testing.expect_value(t, p.init(&foreign_platform, "AIODev.Test.HitForeign"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&foreign_platform), p.Error.None)
	first, err := p.window_create(&platform, {hidden = true, width = 240, height = 160})
	if !testing.expect_value(t, err, p.Error.None) { return }
	second, second_error := p.window_create(&platform, {hidden = true, width = 240, height = 160})
	if !testing.expect_value(t, second_error, p.Error.None) { return }
	other, other_error := p.window_create(&foreign_platform, {hidden = true, width = 240, height = 160})
	if !testing.expect_value(t, other_error, p.Error.None) { return }
	for owner in ([?]struct { platform: ^p.Platform, id, expected: p.Window_Id }{
		{&platform, first, first}, {&platform, second, second}, {&foreign_platform, other, 0},
	}) {
		testing.expect_value(t, p.window_set_position(owner.platform, owner.id, 80, 80), p.Error.None)
		hwnd := w.HWND(p.window_native_handle(owner.platform, owner.id))
		flags := u32(w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE | w.SWP_SHOWWINDOW)
		if !testing.expect(t, bool(w.SetWindowPos(hwnd, w.HWND_TOPMOST, 0, 0, 0, 0, flags))) { return }
		for point in ([?][2]i32{{30, 30}, {80, -10}}) {
			x, y, screen_error := p.window_to_screen(owner.platform, owner.id, point.x, point.y)
			testing.expect_value(t, screen_error, p.Error.None)
			hit, client_x, client_y, hit_error := p.window_at_point(&platform, x, y)
			testing.expect_value(t, hit_error, p.Error.None)
			testing.expect_value(t, hit, owner.expected)
			if hit != 0 {
				testing.expect_value(t, client_x, point.x)
				testing.expect_value(t, client_y, point.y)
			}
		}
	}
	hit, _, _, hit_error := p.window_at_point(&platform, -30000, -30000)
	testing.expect_value(t, hit_error, p.Error.None)
	testing.expect_value(t, hit, p.Window_Id(0))
}

@(test)
capture_loss_only_cancels_held_native_buttons_once :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.CaptureLoss"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	first, err := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, err, p.Error.None) { return }
	second, second_error := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, second_error, p.Error.None) { return }
	hwnd := w.HWND(p.window_native_handle(&platform, first))
	other := w.HWND(p.window_native_handle(&platform, second))
	for kind in 0..<4 {
		w.SendMessageW(hwnd, w.WM_LBUTTONDOWN, 0, 0)
		if kind == 0 {
			w.SendMessageW(hwnd, w.WM_LBUTTONUP, 0, 0)
		} else if kind == 1 {
			w.SetCapture(other)
			testing.expect_value(t, w.GetCapture(), other)
			testing.expect(t, bool(w.ReleaseCapture()))
		} else {
			if kind == 3 { w.SendMessageW(hwnd, w.WM_RBUTTONDOWN, 0, 0) }
			w.SendMessageW(hwnd, w.WM_CANCELMODE, 0, 0)
			testing.expect(t, w.GetCapture() != hwnd)
		}
		w.SendMessageW(hwnd, w.WM_CANCELMODE, 0, 0)
		w.SendMessageW(hwnd, w.WM_CAPTURECHANGED, 0, 0)
		events, poll_error := p.poll_events(&platform)
		testing.expect_value(t, poll_error, p.Error.None)
		count := 0
		for event in events {
			if lost, ok := event.(p.Capture_Lost_Event); ok {
				testing.expect_value(t, lost.window, first)
				count += 1
			}
		}
		testing.expect_value(t, count, kind == 0 ? 0 : 1)
	}
}
