package platform

import "aio:input"
import "core:log"
import w "core:sys/windows"
import "core:unicode/utf16"
import "core:unicode/utf8"

Native_Key :: struct {
	vk, scan_code: u16,
	char: u16,
	control_key_state: u32,
	repeat_count: u16,
}

@(require_results)
synthesize_key :: proc(
	window: Window_Id, key: input.Key, modifiers: input.Modifiers, pressed: bool, buffer: []u8,
) -> (Key_Event, Error) {
	scan, extended, mapped := scan_code_from_key(key)
	if !mapped { return {}, .Invalid_Argument }
	vk := w.MapVirtualKeyW(u32(scan) | (extended ? 0xe000 : 0), w.MAPVK_VSC_TO_VK_EX)
	if vk == 0 {
		log.errorf("MapVirtualKeyW failed for %v: %v", key, w.GetLastError())
		return {}, .Os
	}
	#partial switch key {
	case .Shift_Left, .Shift_Right: vk = w.VK_SHIFT
	case .Control_Left, .Control_Right: vk = w.VK_CONTROL
	case .Alt_Left, .Alt_Right: vk = w.VK_MENU
	}
	// MapVirtualKey does not apply Num Lock to keypad navigation scan codes.
	if .Num_Lock in modifiers && .Shift not_in modifiers {
		#partial switch key {
		case .Numpad_0: vk = w.VK_NUMPAD0
		case .Numpad_1: vk = w.VK_NUMPAD1
		case .Numpad_2: vk = w.VK_NUMPAD2
		case .Numpad_3: vk = w.VK_NUMPAD3
		case .Numpad_4: vk = w.VK_NUMPAD4
		case .Numpad_5: vk = w.VK_NUMPAD5
		case .Numpad_6: vk = w.VK_NUMPAD6
		case .Numpad_7: vk = w.VK_NUMPAD7
		case .Numpad_8: vk = w.VK_NUMPAD8
		case .Numpad_9: vk = w.VK_NUMPAD9
		case .Numpad_Decimal: vk = w.VK_DECIMAL
		}
	}
	state: [256]u8
	Modifier_Key :: struct { modifier, right: input.Modifier, generic, left_vk, right_vk: int }
	keys := [?]Modifier_Key{
		{.Shift, .Right_Shift, w.VK_SHIFT, w.VK_LSHIFT, w.VK_RSHIFT},
		{.Control, .Right_Control, w.VK_CONTROL, w.VK_LCONTROL, w.VK_RCONTROL},
		{.Alt, .Right_Alt, w.VK_MENU, w.VK_LMENU, w.VK_RMENU},
		{.Super, .Right_Super, 0, w.VK_LWIN, w.VK_RWIN},
	}
	for k in keys {
		if k.modifier in modifiers {
			state[k.right in modifiers ? k.right_vk : k.left_vk] = 128
			if k.generic != 0 { state[k.generic] = 128 }
		}
	}
	if .Caps_Lock in modifiers { state[w.VK_CAPITAL] = 1 }
	if .Num_Lock in modifiers { state[w.VK_NUMLOCK] = 1 }
	e := Key_Event{window = window, key = key, modifiers = modifiers, pressed = pressed,
		native = {vk = u16(vk), scan_code = scan, repeat_count = 1,
			control_key_state = control_key_state(state, extended)}}
	if !pressed { return e, .None }
	layout := GetKeyboardLayout(0)
	if layout == nil {
		log.errorf("GetKeyboardLayout failed: %v", w.GetLastError())
		return {}, .Os
	}
	empty: [256]u8
	units: [8]u16
	n := ToUnicodeEx(vk, u32(scan), cast(^w.BYTE)&empty[0], &units[0], i32(len(units)),
		TO_UNICODE_NO_STATE_CHANGE, layout)
	if n > 0 {
		e.unshifted = rune(units[0])
		if n >= 2 && utf16.is_surrogate(e.unshifted) {
			e.unshifted = utf16.decode_surrogate_pair(rune(units[0]), rune(units[1]))
		}
	}
	n = ToUnicodeEx(vk, u32(scan), cast(^w.BYTE)&state[0], &units[0], i32(len(units)),
		TO_UNICODE_NO_STATE_CHANGE, layout)
	if n <= 0 { return e, .None }
	e.native.char = units[0]
	at := 0
	for i := 0; i < int(n); i += 1 {
		r := rune(units[i])
		if utf16.is_surrogate(r) {
			if i+1 < int(n) && units[i] >= 0xd800 && units[i] <= 0xdbff &&
			   units[i+1] >= 0xdc00 && units[i+1] <= 0xdfff {
				r = utf16.decode_surrogate_pair(r, rune(units[i+1]))
				i += 1
			} else {
				r = '\ufffd'
			}
		}
		bytes, size := utf8.encode_rune(r)
		if size > len(buffer)-at { return {}, .Invalid_Argument }
		at += copy(buffer[at:], bytes[:size])
	}
	e.text = string(buffer[:at])
	return e, .None
}

@(private)
SCAN_KEYS :: [512]input.Key{
	0x01 = .Escape, 0x02 = .Digit_1, 0x03 = .Digit_2, 0x04 = .Digit_3,
	0x05 = .Digit_4, 0x06 = .Digit_5, 0x07 = .Digit_6, 0x08 = .Digit_7,
	0x09 = .Digit_8, 0x0a = .Digit_9, 0x0b = .Digit_0, 0x0c = .Minus,
	0x0d = .Equal, 0x0e = .Backspace, 0x0f = .Tab,
	0x10 = .Q, 0x11 = .W, 0x12 = .E, 0x13 = .R, 0x14 = .T, 0x15 = .Y,
	0x16 = .U, 0x17 = .I, 0x18 = .O, 0x19 = .P, 0x1a = .Bracket_Left,
	0x1b = .Bracket_Right, 0x1c = .Enter, 0x1d = .Control_Left,
	0x1e = .A, 0x1f = .S, 0x20 = .D, 0x21 = .F, 0x22 = .G, 0x23 = .H,
	0x24 = .J, 0x25 = .K, 0x26 = .L, 0x27 = .Semicolon, 0x28 = .Quote,
	0x29 = .Backquote, 0x2a = .Shift_Left, 0x2b = .Backslash,
	0x2c = .Z, 0x2d = .X, 0x2e = .C, 0x2f = .V, 0x30 = .B, 0x31 = .N,
	0x32 = .M, 0x33 = .Comma, 0x34 = .Period, 0x35 = .Slash,
	0x36 = .Shift_Right, 0x37 = .Numpad_Multiply, 0x38 = .Alt_Left,
	0x39 = .Space, 0x3a = .Caps_Lock,
	0x3b = .F1, 0x3c = .F2, 0x3d = .F3, 0x3e = .F4, 0x3f = .F5,
	0x40 = .F6, 0x41 = .F7, 0x42 = .F8, 0x43 = .F9, 0x44 = .F10,
	0x45 = .Pause, 0x46 = .Scroll_Lock, 0x47 = .Numpad_7,
	0x48 = .Numpad_8, 0x49 = .Numpad_9, 0x4a = .Numpad_Subtract,
	0x4b = .Numpad_4, 0x4c = .Numpad_5, 0x4d = .Numpad_6,
	0x4e = .Numpad_Add, 0x4f = .Numpad_1, 0x50 = .Numpad_2,
	0x51 = .Numpad_3, 0x52 = .Numpad_0, 0x53 = .Numpad_Decimal,
	0x56 = .Intl_Backslash, 0x57 = .F11, 0x58 = .F12, 0x59 = .Numpad_Equal,
	0x64 = .F13, 0x65 = .F14, 0x66 = .F15, 0x67 = .F16, 0x68 = .F17,
	0x69 = .F18, 0x6a = .F19, 0x6b = .F20, 0x6c = .F21, 0x6d = .F22,
	0x6e = .F23, 0x70 = .Kana_Mode, 0x73 = .Intl_Ro, 0x76 = .F24,
	0x79 = .Convert, 0x7b = .Non_Convert, 0x7d = .Intl_Yen, 0x7e = .Numpad_Comma,
	0x110 = .Media_Track_Previous, 0x119 = .Media_Track_Next,
	0x11c = .Numpad_Enter, 0x11d = .Control_Right,
	0x120 = .Audio_Volume_Mute, 0x121 = .Launch_App_2,
	0x122 = .Media_Play_Pause, 0x124 = .Media_Stop,
	0x12e = .Audio_Volume_Down, 0x130 = .Audio_Volume_Up,
	0x132 = .Browser_Home, 0x135 = .Numpad_Divide, 0x137 = .Print_Screen,
	0x138 = .Alt_Right, 0x145 = .Num_Lock, 0x147 = .Home, 0x148 = .Arrow_Up,
	0x149 = .Page_Up, 0x14b = .Arrow_Left, 0x14d = .Arrow_Right,
	0x14f = .End, 0x150 = .Arrow_Down, 0x151 = .Page_Down,
	0x152 = .Insert, 0x153 = .Delete, 0x15b = .Meta_Left,
	0x15c = .Meta_Right, 0x15d = .Context_Menu, 0x15e = .Power,
	0x15f = .Sleep, 0x163 = .Wake_Up, 0x165 = .Browser_Search,
	0x166 = .Browser_Favorites, 0x167 = .Browser_Refresh, 0x168 = .Browser_Stop,
	0x169 = .Browser_Forward, 0x16a = .Browser_Back, 0x16b = .Launch_App_1,
	0x16c = .Launch_Mail, 0x16d = .Media_Select,
}

key_from_scan_code :: proc(scan: u16, extended: bool) -> input.Key {
	if scan > 255 { return .Unidentified }
	table := SCAN_KEYS
	return table[int(scan) | (extended ? 256 : 0)]
}

@(require_results)
scan_code_from_key :: proc(key: input.Key) -> (scan: u16, extended, ok: bool) {
	if key == .Unidentified { return }
	for k, i in SCAN_KEYS {
		if k == key { return u16(i & 255), i >= 256, true }
	}
	return
}

modifiers_from_state :: proc(state: [256]u8) -> (mods: input.Modifiers) {
	if state[w.VK_LSHIFT]&128 != 0 || state[w.VK_RSHIFT]&128 != 0 {
		mods += {.Shift}
	}
	if state[w.VK_LCONTROL]&128 != 0 || state[w.VK_RCONTROL]&128 != 0 {
		mods += {.Control}
	}
	if state[w.VK_LMENU]&128 != 0 || state[w.VK_RMENU]&128 != 0 {
		mods += {.Alt}
	}
	if state[w.VK_LWIN]&128 != 0 || state[w.VK_RWIN]&128 != 0 {
		mods += {.Super}
	}
	if state[w.VK_RSHIFT]&128 != 0 {
		mods += {.Right_Shift}
	}
	if state[w.VK_RCONTROL]&128 != 0 {
		mods += {.Right_Control}
	}
	if state[w.VK_RMENU]&128 != 0 {
		mods += {.Right_Alt}
	}
	if state[w.VK_RWIN]&128 != 0 {
		mods += {.Right_Super}
	}
	if state[w.VK_CAPITAL]&1 != 0 {
		mods += {.Caps_Lock}
	}
	if state[w.VK_NUMLOCK]&1 != 0 {
		mods += {.Num_Lock}
	}
	return
}

control_key_state :: proc(state: [256]u8, extended: bool) -> (bits: u32) {
	if state[w.VK_RMENU]&128 != 0 {
		bits |= 1
	}
	if state[w.VK_LMENU]&128 != 0 {
		bits |= 2
	}
	if state[w.VK_RCONTROL]&128 != 0 {
		bits |= 4
	}
	if state[w.VK_LCONTROL]&128 != 0 {
		bits |= 8
	}
	if state[w.VK_LSHIFT]&128 != 0 || state[w.VK_RSHIFT]&128 != 0 {
		bits |= 16
	}
	if state[w.VK_NUMLOCK]&1 != 0 {
		bits |= 32
	}
	if state[w.VK_SCROLL]&1 != 0 {
		bits |= 64
	}
	if state[w.VK_CAPITAL]&1 != 0 {
		bits |= 128
	}
	if extended {
		bits |= 256
	}
	return
}
