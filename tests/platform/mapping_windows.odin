package platform_test

import "aio:input"
import p "aio:platform"
import "core:testing"
import w "core:sys/windows"

@(test)
scan_code_mapping :: proc(t: ^testing.T) {
	Fixture :: struct { scan: u16, extended: bool, key: input.Key }
	fixtures := [?]Fixture{
		{0x1e, false, .A}, {0x10, false, .Q}, {0x2c, false, .Z},
		{0x1c, false, .Enter}, {0x1c, true, .Numpad_Enter},
		{0x1d, false, .Control_Left}, {0x1d, true, .Control_Right},
		{0x38, false, .Alt_Left}, {0x38, true, .Alt_Right},
		{0x2a, false, .Shift_Left}, {0x36, false, .Shift_Right},
		{0x35, false, .Slash}, {0x35, true, .Numpad_Divide},
		{0x47, false, .Numpad_7}, {0x47, true, .Home},
		{0x53, false, .Numpad_Decimal}, {0x53, true, .Delete},
		{0x45, false, .Pause}, {0x45, true, .Num_Lock},
		{0x37, true, .Print_Screen}, {0x5b, true, .Meta_Left},
		{0x5c, true, .Meta_Right}, {0x5d, true, .Context_Menu},
		{0x56, false, .Intl_Backslash}, {0x73, false, .Intl_Ro},
		{0x7d, false, .Intl_Yen}, {0x70, false, .Kana_Mode},
		{0x79, false, .Convert}, {0x7b, false, .Non_Convert},
		{0x64, false, .F13}, {0x76, false, .F24},
		{0x19, true, .Media_Track_Next}, {0x6a, true, .Browser_Back},
		{0x6c, true, .Launch_Mail}, {0x20, true, .Audio_Volume_Mute},
	}
	for f in fixtures {
		testing.expect_value(t, p.key_from_scan_code(f.scan, f.extended), f.key)
	}
	count := 0
	for scan in 0..<512 {
		key := p.key_from_scan_code(u16(scan&255), scan >= 256)
		if key == .Unidentified {
			continue
		}
		reverse, extended, ok := p.scan_code_from_key(key)
		testing.expect(t, ok)
		testing.expect_value(t, int(reverse) | (extended ? 256 : 0), scan)
		count += 1
	}
	testing.expect(t, count >= 140)
	testing.expect_value(t, p.key_from_scan_code(256, false), input.Key.Unidentified)
	testing.expect_value(t, p.key_from_scan_code(65535, true), input.Key.Unidentified)
	for key in ([]input.Key{.Unidentified, .F25, .Fn, .Copy, .Numpad_Memory_Add}) {
		_, _, ok := p.scan_code_from_key(key)
		testing.expect(t, !ok)
	}
}

@(test)
modifier_and_console_state :: proc(t: ^testing.T) {
	Fixture :: struct { vk: int, value: u8, mods: input.Modifiers, console: u32 }
	fixtures := [?]Fixture{
		{w.VK_LSHIFT, 128, {.Shift}, 16}, {w.VK_RSHIFT, 128, {.Shift, .Right_Shift}, 16},
		{w.VK_LCONTROL, 128, {.Control}, 8}, {w.VK_RCONTROL, 128, {.Control, .Right_Control}, 4},
		{w.VK_LMENU, 128, {.Alt}, 2}, {w.VK_RMENU, 128, {.Alt, .Right_Alt}, 1},
		{w.VK_LWIN, 128, {.Super}, 0}, {w.VK_RWIN, 128, {.Super, .Right_Super}, 0},
		{w.VK_CAPITAL, 1, {.Caps_Lock}, 128}, {w.VK_NUMLOCK, 1, {.Num_Lock}, 32},
		{w.VK_SCROLL, 1, {}, 64}, {w.VK_CAPITAL, 128, {}, 0}, {w.VK_A, 129, {}, 0},
	}
	for f in fixtures {
		state: [256]u8
		state[f.vk] = f.value
		testing.expect_value(t, p.modifiers_from_state(state), f.mods)
		testing.expect_value(t, p.control_key_state(state, false), f.console)
		testing.expect_value(t, p.control_key_state(state, true), f.console | 256)
	}
	state: [256]u8
	for f in fixtures[:11] {
		state[f.vk] = f.value
	}
	testing.expect_value(t, p.control_key_state(state, true), u32(511))
	expected := input.Modifiers{
		.Shift, .Right_Shift, .Control, .Right_Control, .Alt, .Right_Alt,
		.Super, .Right_Super, .Caps_Lock, .Num_Lock,
	}
	testing.expect_value(t, p.modifiers_from_state(state), expected)
	state = {}
	testing.expect_value(t, p.modifiers_from_state(state), input.Modifiers{})
	testing.expect_value(t, p.control_key_state(state, false), u32(0))
}

@(test)
clipboard_line_endings :: proc(t: ^testing.T) {
	Fixture :: struct { source, expected: string }
	fixtures := [?]Fixture{{"", ""}, {"a", "a"}, {"\n", "\r\n"}, {"\r\n", "\r\n"},
		{"\r", "\r"}, {"a\nb\r\nc\rd\n\n", "a\r\nb\r\nc\rd\r\n\r\n"}, {"漢😀\n", "漢😀\r\n"}}
	for f in fixtures {
		buffer: [128]u8
		text, ok := p.clipboard_crlf(f.source, buffer[:len(f.expected)])
		testing.expect(t, ok)
		testing.expect_value(t, text, f.expected)
		if len(f.expected) > 0 {
			_, fits := p.clipboard_crlf(f.source, buffer[:len(f.expected)-1])
			testing.expect(t, !fits)
		}
	}
}
