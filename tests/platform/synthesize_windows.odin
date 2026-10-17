package platform_test

import "aio:input"
import p "aio:platform"
import "core:testing"
import w "core:sys/windows"

@(test)
synthesized_keys :: proc(t: ^testing.T) {
	previous := GetKeyboardLayout(0)
	if !testing.expect(t, previous != nil) { return }
	count := GetKeyboardLayoutList(0, nil)
	if !testing.expect(t, count > 0) { return }
	layouts, allocation_error := make([]HKL, int(count))
	if !testing.expect(t, allocation_error == nil) { return }
	defer delete(layouts)
	if !testing.expect(t, GetKeyboardLayoutList(count, raw_data(layouts)) > 0) { return }
	us := LoadKeyboardLayoutW(w.L("00000409"), KLF_NOTELLSHELL)
	if !testing.expect(t, us != nil) { return }
	loaded := true
	for layout in layouts { if layout == us { loaded = false } }
	defer if loaded { testing.expect(t, bool(UnloadKeyboardLayout(us))) }
	if !testing.expect(t, ActivateKeyboardLayout(us, 0) != nil) { return }
	defer testing.expect(t, ActivateKeyboardLayout(previous, 0) != nil)
	Fixture :: struct {
		key: input.Key,
		modifiers: input.Modifiers,
		text: string,
		unshifted: rune,
		extended: bool,
	}
	fixtures := [?]Fixture{
		{.A, {}, "a", 'a', false}, {.A, {.Shift}, "A", 'a', false},
		{.C, {.Control}, "\x03", 'c', false},
		{.Digit_1, {}, "1", '1', false}, {.Digit_1, {.Shift}, "!", '1', false},
		{.Enter, {}, "\r", '\r', false}, {.Escape, {}, "\x1b", '\x1b', false},
		{.Arrow_Left, {}, "", 0, true}, {.Arrow_Right, {}, "", 0, true},
		{.Arrow_Up, {}, "", 0, true}, {.Arrow_Down, {}, "", 0, true},
		{.Home, {}, "", 0, true}, {.End, {}, "", 0, true},
		{.Page_Up, {}, "", 0, true}, {.Page_Down, {}, "", 0, true},
		{.Insert, {}, "", 0, true}, {.Delete, {}, "", 0, true},
		{.F1, {}, "", 0, false}, {.F12, {}, "", 0, false},
		{.Numpad_Enter, {}, "\r", '\r', true},
		{.Numpad_Add, {}, "+", '+', false}, {.Numpad_Divide, {}, "/", '/', true},
		{.Numpad_1, {}, "", 0, false}, {.Numpad_1, {.Num_Lock}, "1", '1', false},
	}
	for f in fixtures {
		buffer: [32]u8
		e, err := p.synthesize_key(7, f.key, f.modifiers, true, buffer[:])
		if !testing.expect_value(t, err, p.Error.None) { continue }
		testing.expect_value(t, e.window, p.Window_Id(7))
		testing.expect_value(t, e.key, f.key)
		testing.expect_value(t, e.modifiers, f.modifiers)
		testing.expect_value(t, e.text, f.text)
		testing.expect_value(t, e.unshifted, f.unshifted)
		testing.expect(t, e.pressed && !e.repeat)
		testing.expect_value(t, e.native.repeat_count, u16(1))
		testing.expect(t, e.native.vk != 0 && e.native.scan_code != 0)
		testing.expect_value(t, e.native.control_key_state & 256 != 0, f.extended)
		if len(f.text) > 0 { testing.expect_value(t, e.native.char, u16(f.text[0])) }
		up, up_error := p.synthesize_key(7, f.key, f.modifiers, false, nil)
		testing.expect_value(t, up_error, p.Error.None)
		testing.expect(t, !up.pressed && !up.repeat && up.text == "" && up.unshifted == 0)
	}
	_, err := p.synthesize_key(0, .Unidentified, {}, true, nil)
	testing.expect_value(t, err, p.Error.Invalid_Argument)
	_, err = p.synthesize_key(0, .F25, {}, true, nil)
	testing.expect_value(t, err, p.Error.Invalid_Argument)
	_, err = p.synthesize_key(0, .A, {}, true, nil)
	testing.expect_value(t, err, p.Error.Invalid_Argument)
	buffer: [32]u8
	control, control_error := p.synthesize_key(0, .C, {.Control}, true, buffer[:1])
	testing.expect_value(t, control_error, p.Error.None)
	testing.expect_value(t, control.native.vk, u16(w.VK_C))
	testing.expect_value(t, control.native.scan_code, u16(0x2e))
	testing.expect_value(t, control.native.control_key_state, u32(8))
	mods := input.Modifiers{.Control, .Right_Control, .Shift, .Right_Shift, .Alt, .Right_Alt,
		.Super, .Right_Super, .Caps_Lock, .Num_Lock}
	right, right_error := p.synthesize_key(0, .Arrow_Left, mods, true, buffer[:])
	testing.expect_value(t, right_error, p.Error.None)
	testing.expect_value(t, right.native.control_key_state, u32(1 | 4 | 16 | 32 | 128 | 256))
	testing.expect_value(t, right.modifiers, mods)
	Modifier :: struct { key: input.Key, vk: u16 }
	for modifier in ([]Modifier{
		{.Shift_Left, w.VK_SHIFT}, {.Shift_Right, w.VK_SHIFT},
		{.Control_Left, w.VK_CONTROL}, {.Control_Right, w.VK_CONTROL},
		{.Alt_Left, w.VK_MENU}, {.Alt_Right, w.VK_MENU},
		{.Meta_Left, w.VK_LWIN}, {.Meta_Right, w.VK_RWIN},
	}) {
		for pressed in ([]bool{true, false}) {
			event, error := p.synthesize_key(0, modifier.key, {}, pressed, buffer[:])
			testing.expect_value(t, error, p.Error.None)
			testing.expect_value(t, event.native.vk, modifier.vk)
			testing.expect_value(t, event.text, "")
			testing.expect_value(t, event.native.char, u16(0))
		}
	}
}

@(test)
set_client_size :: proc(t: ^testing.T) {
	platform: p.Platform
	testing.expect_value(t, p.window_set_client_size(&platform, 1, 320, 200), p.Error.Invalid_Window)
	testing.expect_value(t, p.window_show_inactive(&platform, 1), p.Error.Invalid_Window)
	if !testing.expect_value(t, p.init(&platform, "AIODev.Test.ClientSize"), p.Init_Result.Primary) {
		return
	}
	defer testing.expect_value(t, p.destroy(&platform), p.Error.None)
	id, err := p.window_create(&platform, {hidden = true, width = 320, height = 200})
	if !testing.expect_value(t, err, p.Error.None) { return }
	hwnd := w.HWND(p.window_native_handle(&platform, id))
	position: w.RECT
	if !testing.expect(t, bool(w.GetWindowRect(hwnd, &position))) { return }
	foreground := w.GetForegroundWindow()
	for size in ([][2]i32{{640, 480}, {321, 201}, {800, 600}}) {
		testing.expect_value(t, p.window_set_client_size(&platform, id, size.x, size.y), p.Error.None)
		width, height, size_error := p.window_client_size(&platform, id)
		testing.expect_value(t, size_error, p.Error.None)
		testing.expect_value(t, width, size.x)
		testing.expect_value(t, height, size.y)
		resized: w.RECT
		testing.expect(t, bool(w.GetWindowRect(hwnd, &resized)))
		testing.expect_value(t, resized.left, position.left)
		testing.expect_value(t, resized.top, position.top)
		testing.expect(t, !bool(w.IsWindowVisible(hwnd)))
		testing.expect_value(t, w.GetForegroundWindow(), foreground)
	}
	for size in ([][2]i32{{0, 10}, {10, -1}, {32768, 10}}) {
		testing.expect_value(t, p.window_set_client_size(&platform, id, size.x, size.y),
			p.Error.Invalid_Argument)
	}
}
