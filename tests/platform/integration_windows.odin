package platform_test

import p "aio:platform"
import "core:testing"
import "core:thread"
import "core:time"
import w "core:sys/windows"

foreign import user32 "system:user32.lib"
@(default_calling_convention="system")
foreign user32 {
	SetKeyboardState :: proc(state: ^w.BYTE) -> w.BOOL ---
}

@(test)
tabbed_title_bar_keeps_native_hit_testing_and_client_size :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.TitleBar"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	id, err := p.window_create(&platform,
		{hidden = true, title = "Tabs", width = 900, height = 600, tabbed_title_bar = true})
	if !testing.expect_value(t, err, p.Error.None) { return }
	p.window_title_bar(&platform, id, 40, 300)
	width, height, size_error := p.window_client_size(&platform, id)
	testing.expect_value(t, size_error, p.Error.None)
	testing.expect_value(t, width, i32(900))
	testing.expect_value(t, height, i32(600))
	hwnd := w.HWND(p.window_native_handle(&platform, id))
	for hit in ([?]struct { x, y: i32, expected: w.LRESULT }{
		{100, 20, w.HTCLIENT}, {400, 20, w.HTCAPTION}, {400, 1, w.HTTOP},
		{785, 20, w.HTMINBUTTON}, {831, 20, w.HTMAXBUTTON}, {877, 20, w.HTCLOSE},
		{400, 200, w.HTCLIENT},
	}) {
		point := w.POINT{hit.x, hit.y}
		testing.expect(t, bool(w.ClientToScreen(hwnd, &point)))
		packed := w.LPARAM(u32(u16(point.x)) | (u32(u16(point.y))<<16))
		testing.expect_value(t, w.SendMessageW(hwnd, w.WM_NCHITTEST, 0, packed), hit.expected)
	}
	testing.expect_value(t, p.window_set_client_size(&platform, id, 800, 500), p.Error.None)
	width, height, size_error = p.window_client_size(&platform, id)
	testing.expect_value(t, size_error, p.Error.None)
	testing.expect_value(t, width, i32(800))
	testing.expect_value(t, height, i32(500))
	p.window_caption_action(&platform, id, 2)
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	closed := false
	for e in events { if request, ok := e.(p.Close_Request_Event); ok { closed ||= request.window == id } }
	testing.expect(t, closed)
}

@(test)
invalid_and_partial_lifecycle :: proc(t: ^testing.T) {
	platform: p.Platform
	testing.expect_value(t, p.destroy(&platform), p.Error.None)
	testing.expect_value(t, p.init(&platform, ""), p.Init_Result.Failed)
	testing.expect_value(t, p.init(&platform, "bad\\id"), p.Init_Result.Failed)
	_, err := p.window_create(&platform, {hidden = true, width = 80, height = 40})
	testing.expect_value(t, err, p.Error.Not_Initialized)
	testing.expect_value(t, p.wake(&platform), p.Error.Not_Initialized)
	testing.expect_value(t, p.wait_events(&platform, 0), p.Error.Not_Initialized)
	_, err = p.poll_events(&platform)
	testing.expect_value(t, err, p.Error.Not_Initialized)
	testing.expect_value(t, p.window_destroy(&platform, 1), p.Error.Invalid_Window)
	testing.expect_value(t, p.window_set_title(&platform, 1, "x"), p.Error.Invalid_Window)
	testing.expect_value(t, p.window_set_frame_color(&platform, 1, {}), p.Error.Invalid_Window)
	testing.expect_value(t, p.window_set_cursor(&platform, 1, .Arrow), p.Error.Invalid_Window)
	testing.expect_value(t, p.window_flash(&platform, 1), p.Error.Invalid_Window)
	testing.expect(t, p.window_native_handle(&platform, 1) == nil)
	testing.expect(t, !p.clipboard_set_text(&platform, "x"))
	_, ok := p.clipboard_get_text(&platform, context.allocator)
	testing.expect(t, !ok)
	testing.expect(t, !p.open_path(""))
}

@(test)
window_lifecycle_and_events :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Windows"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	_, invalid := p.window_create(&platform, {hidden = true, width = 0, height = 10})
	testing.expect_value(t, invalid, p.Error.Invalid_Argument)
	_, invalid = p.window_create(&platform, {hidden = true, title = "bad\x00title", width = 10, height = 10})
	testing.expect_value(t, invalid, p.Error.Invalid_Argument)
	first, err := p.window_create(&platform, {hidden = true, title = "First", width = 320, height = 200})
	if !testing.expect_value(t, err, p.Error.None) { return }
	second, second_error := p.window_create(
		&platform, {hidden = true, title = "Second", width = 240, height = 120},
	)
	if !testing.expect_value(t, second_error, p.Error.None) { return }
	testing.expect(t, first != second)
	testing.expect(t, p.window_dpi(&platform, first) >= 96)
	width, height, size_error := p.window_client_size(&platform, first)
	testing.expect_value(t, size_error, p.Error.None)
	testing.expect_value(t, width, i32(320))
	testing.expect_value(t, height, i32(200))
	testing.expect_value(t, p.window_set_title(&platform, first, "Changed 漢😀"), p.Error.None)
	testing.expect_value(t, p.window_set_frame_color(&platform, first, {0x0f, 0x11, 0x15}), p.Error.None)
	for shape in p.Cursor_Shape {
		testing.expect_value(t, p.window_set_cursor(&platform, first, shape), p.Error.None)
	}
	hwnd := w.HWND(p.window_native_handle(&platform, first))
	rect := w.RECT{right = 400, bottom = 260}
	testing.expect(t, bool(w.AdjustWindowRectExForDpi(
		&rect, w.WS_OVERLAPPEDWINDOW, false, 0, p.window_dpi(&platform, first),
	)))
	flags := u32(w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE)
	testing.expect(t, bool(w.SetWindowPos(
		hwnd, nil, 0, 0, rect.right-rect.left, rect.bottom-rect.top, flags,
	)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_CLOSE, 0, 0)))
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	saw_resize, saw_close, saw_second := false, false, false
	for event in events {
		#partial switch e in event {
		case p.Resize_Event:
			if e.window == first && e.width == 400 && e.height == 260 {
				saw_resize = true
			}
			if e.window == second {
				saw_second = true
			}
		case p.Close_Request_Event:
			if e.window == first {
				saw_close = true
			}
		case:
		}
	}
	testing.expect(t, saw_resize && saw_close && saw_second)
	testing.expect_value(t, p.window_destroy(&platform, first), p.Error.None)
	testing.expect_value(t, p.window_destroy(&platform, first), p.Error.Invalid_Window)
	testing.expect(t, p.window_native_handle(&platform, second) != nil)
	testing.expect_value(t, p.window_destroy(&platform, second), p.Error.None)
}

@(test)
text_and_key_pump :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Keys"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	id, err := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, err, p.Error.None) { return }
	hwnd := w.HWND(p.window_native_handle(&platform, id))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_CHAR, '漢', 1)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_CHAR, 0xd83d, 1)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_CHAR, 0xde00, 1)))
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	text_count := 0
	for event in events {
		if e, ok := event.(p.Text_Event); ok {
			testing.expect_value(t, e.window, id)
			testing.expect_value(t, e.text, text_count == 0 ? "漢" : "😀")
			text_count += 1
		}
	}
	testing.expect_value(t, text_count, 2)
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_KEYDOWN, w.VK_F2, 1 | (0x3c << 16))))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_KEYUP, w.VK_F2, 1 | (0x3c << 16) | (1 << 30) | (1 << 31))))
	events, poll_error = p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	key_count := 0
	for event in events {
		if e, ok := event.(p.Key_Event); ok {
			testing.expect_value(t, e.key, p.key_from_scan_code(0x3c, false))
			testing.expect_value(t, e.pressed, key_count == 0)
			testing.expect(t, !e.repeat && e.text == "")
			testing.expect_value(t, e.native.vk, u16(w.VK_F2))
			testing.expect_value(t, e.native.scan_code, u16(0x3c))
			testing.expect_value(t, e.native.repeat_count, u16(1))
			key_count += 1
		}
	}
	testing.expect_value(t, key_count, 2)
	saved, empty: [256]w.BYTE
	if !testing.expect(t, bool(w.GetKeyboardState(&saved[0]))) { return }
	if !testing.expect(t, bool(SetKeyboardState(&empty[0]))) { return }
	defer testing.expect(t, bool(SetKeyboardState(&saved[0])))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_KEYDOWN, w.VK_A, 2 | (0x1e << 16) | (1 << 30))))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_KEYUP, w.VK_A, 1 | (0x1e << 16) | (1 << 30) | (1 << 31))))
	events, poll_error = p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	paired := false
	for event in events {
		if e, ok := event.(p.Key_Event); ok && e.pressed {
			testing.expect(t, e.text != "" && e.unshifted != 0 && e.native.char != 0)
			testing.expect(t, e.repeat)
			testing.expect_value(t, e.native.repeat_count, u16(2))
			paired = true
		}
		if _, ok := event.(p.Text_Event); ok {
			testing.expect(t, false, "translated character was not paired")
		}
	}
	testing.expect(t, paired)
}

@(test)
clipboard_round_trip :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Clipboard"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	for text in ([]string{"plain", "漢😀\nline\r\n", ""}) {
		if !testing.expect(t, p.clipboard_set_text(&platform, text)) { return }
		result, ok := p.clipboard_get_text(&platform, context.allocator)
		if !testing.expect(t, ok) { return }
		defer delete(result)
		buffer: [128]u8
		expected, fits := p.clipboard_crlf(text, buffer[:])
		testing.expect(t, fits)
		testing.expect_value(t, result, expected)
	}
	testing.expect(t, !p.clipboard_set_text(&platform, "embedded\x00nul"))
}

@(test)
alt_f4_only_requests_close :: proc(t: ^testing.T) {
	platform: p.Platform
	result := p.init(&platform, "AIODev.Test.AltF4")
	if !testing.expect_value(t, result, p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	id, err := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, err, p.Error.None) { return }
	_, initial_error := p.poll_events(&platform)
	testing.expect_value(t, initial_error, p.Error.None)
	hwnd := w.HWND(p.window_native_handle(&platform, id))
	down := w.LPARAM(1 | (0x3e << 16) | (1 << 29))
	up := down | (1 << 30) | (1 << 31)
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_SYSKEYDOWN, w.VK_F4, down)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_SYSKEYUP, w.VK_F4, up)))
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	close_count, key_count := 0, 0
	for event in events {
		#partial switch e in event {
		case p.Close_Request_Event:
			testing.expect_value(t, e.window, id)
			close_count += 1
		case p.Key_Event:
			key_count += 1
		}
	}
	testing.expect_value(t, close_count, 1)
	testing.expect_value(t, key_count, 0)
}

Wake_Data :: struct { platform: ^p.Platform, error: p.Error }
wake_thread :: proc(worker: ^thread.Thread) {
	data := cast(^Wake_Data)worker.data
	time.sleep(30*time.Millisecond)
	data.error = p.wake(data.platform)
}

@(test)
wake_from_thread :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Wake"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	_, initial_error := p.poll_events(&platform)
	testing.expect_value(t, initial_error, p.Error.None)
	data := Wake_Data{platform = &platform}
	worker := thread.create(wake_thread)
	if !testing.expect(t, worker != nil) { return }
	worker.data = &data
	thread.start(worker)
	defer thread.destroy(worker)
	start := time.tick_now()
	woke := false
	for time.tick_since(start) < 2*time.Second {
		testing.expect_value(t, p.wait_events(&platform, 100), p.Error.None)
		events, err := p.poll_events(&platform)
		testing.expect_value(t, err, p.Error.None)
		for event in events {
			if _, ok := event.(p.Wake_Event); ok {
				woke = true
			}
		}
		if woke {
			break
		}
	}
	thread.join(worker)
	testing.expect_value(t, data.error, p.Error.None)
	testing.expect(t, woke)
	for _ in 0..<20 {
		testing.expect_value(t, p.wake(&platform), p.Error.None)
	}
	events, err := p.poll_events(&platform)
	testing.expect_value(t, err, p.Error.None)
	count := 0
	for event in events {
		if _, ok := event.(p.Wake_Event); ok {
			count += 1
		}
	}
	testing.expect_value(t, count, 1)
}

@(test)
secondary_activation :: proc(t: ^testing.T) {
	primary, secondary: p.Platform
	if !testing.expect_value(t, p.init(&primary, "AIODev.Test.Instance"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&primary), p.Error.None)
	testing.expect_value(t, p.init(&secondary, "AIODev.Test.Instance"), p.Init_Result.Secondary)
	testing.expect_value(t, p.destroy(&secondary), p.Error.None)
	events, err := p.poll_events(&primary)
	testing.expect_value(t, err, p.Error.None)
	found := false
	for event in events {
		if _, ok := event.(p.Activate_Request_Event); ok {
			found = true
		}
	}
	testing.expect(t, found)
}

@(test)
mouse_and_modal_messages :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Mouse"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	id, err := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, err, p.Error.None) { return }
	hwnd := w.HWND(p.window_native_handle(&platform, id))
	position := w.LPARAM(12 | (24 << 16))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_LBUTTONDOWN, 0, position)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_MOUSEMOVE, 0, position)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_LBUTTONUP, 0, position)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_LBUTTONDBLCLK, 0, position)))
	testing.expect(t, bool(w.PostMessageW(hwnd, w.WM_LBUTTONUP, 0, position)))
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	buttons, moves := 0, 0
	last_time: i64
	for event in events {
		#partial switch e in event {
		case p.Mouse_Button_Event:
			testing.expect_value(t, e.window, id)
			testing.expect_value(t, e.x, i32(12))
			testing.expect_value(t, e.y, i32(24))
			testing.expect(t, e.time_ns >= last_time)
			last_time = e.time_ns
			testing.expect_value(t, e.pressed, buttons%2 == 0)
			buttons += 1
		case p.Mouse_Move_Event:
			testing.expect(t, e.time_ns >= last_time)
			last_time = e.time_ns
			moves += 1
		}
	}
	testing.expect_value(t, buttons, 4)
	testing.expect_value(t, moves, 1)
	testing.expect(t, w.GetCapture() != hwnd)
	count := 0
	p.set_modal_loop_callback(&platform, proc(user: rawptr) { (cast(^int)user)^ += 1 }, &count)
	w.SendMessageW(hwnd, w.WM_ENTERSIZEMOVE, 0, 0)
	w.SendMessageW(hwnd, w.WM_TIMER, 1, 0)
	w.SendMessageW(hwnd, w.WM_SIZE, 0, position)
	w.SendMessageW(hwnd, w.WM_EXITSIZEMOVE, 0, 0)
	w.SendMessageW(hwnd, w.WM_TIMER, 1, 0)
	testing.expect_value(t, count, 2)
	p.set_modal_loop_callback(&platform, nil, nil)
}

@(test)
tray_menu_validation :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.Tray"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	testing.expect_value(t, p.tray_notify(&platform, "title", "text"), p.Error.Not_Initialized)
	invalid := []p.Tray_Menu_Item{{id = 0, title = "invalid"}}
	duplicate := []p.Tray_Menu_Item{{id = 1}, {id = 1}}
	valid := []p.Tray_Menu_Item{
		{id = 1, title = "Open"}, {separator = true}, {id = 2, title = "Quit", disabled = true},
	}
	testing.expect_value(t, p.tray_set_menu(&platform, invalid), p.Error.Invalid_Argument)
	testing.expect_value(t, p.tray_set_menu(&platform, duplicate), p.Error.Invalid_Argument)
	testing.expect_value(t, p.tray_set_menu(&platform, valid), p.Error.None)
	testing.expect_value(t, p.tray_set_menu(&platform, nil), p.Error.None)
	testing.expect_value(t, p.tray_destroy(&platform), p.Error.None)
}

@(test)
synthetic_mouse_moves :: proc(t: ^testing.T) {
	platform: p.Platform
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.MouseMove"), p.Init_Result.Primary) { return }
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	first, err := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, err, p.Error.None) { return }
	second, second_error := p.window_create(&platform, {hidden = true, width = 160, height = 100})
	if !testing.expect_value(t, second_error, p.Error.None) { return }
	position := w.LPARAM(10 | (20 << 16))
	Case :: struct { window: p.Window_Id, position: w.LPARAM, buttons: w.WPARAM, expected: int, leave: bool }
	cases := [?]Case{
		{first, position, 0, 1, false},
		{first, position, 0, 0, false},
		{first, position, w.MK_SHIFT, 0, false},
		{first, position, w.MK_LBUTTON, 1, false},
		{first, position, w.MK_LBUTTON, 0, false},
		{first, position+1, w.MK_LBUTTON, 1, false},
		{first, position+1, 0, 1, false},
		{second, position+1, 0, 1, false},
		{first, position+1, 0, 0, false},
		{first, position+1, 0, 1, true},
		{first, position+1, 0, 0, false},
	}
	for item in cases {
		hwnd := w.HWND(p.window_native_handle(&platform, item.window))
		if item.leave {
			testing.expect_value(t, w.SendMessageW(hwnd, w.WM_MOUSELEAVE, 0, 0), w.LRESULT(0))
		}
		testing.expect_value(t, w.SendMessageW(hwnd, w.WM_MOUSEMOVE, item.buttons, item.position), w.LRESULT(0))
	}
	events, poll_error := p.poll_events(&platform)
	testing.expect_value(t, poll_error, p.Error.None)
	index := 0
	for event in events {
		if move, ok := event.(p.Mouse_Move_Event); ok {
			for index < len(cases) && cases[index].expected == 0 { index += 1 }
			if !testing.expect(t, index < len(cases)) { continue }
			item := cases[index]
			testing.expect_value(t, move.window, item.window)
			testing.expect_value(t, move.x, i32(item.position & 0xffff))
			testing.expect_value(t, move.y, i32(20))
			testing.expect_value(t, .Left in move.buttons, item.buttons & w.MK_LBUTTON != 0)
			index += 1
		}
	}
	for index < len(cases) && cases[index].expected == 0 { index += 1 }
	testing.expect_value(t, index, len(cases))
}
