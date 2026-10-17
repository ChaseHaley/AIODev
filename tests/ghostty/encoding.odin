package ghostty_test

import "core:testing"
import "aio:ghostty"

@(test)
key_encoding :: proc(t: ^testing.T) {
	encoder: ghostty.Key_Encoder
	if !testing.expect_value(t, ghostty.key_encoder_new(nil, &encoder), SUCCESS) {
		return
	}
	defer ghostty.key_encoder_free(encoder)
	event: ghostty.Key_Event
	if !testing.expect_value(t, ghostty.key_event_new(nil, &event), SUCCESS) {
		return
	}
	defer ghostty.key_event_free(event)
	ghostty.key_event_set_action(event, .Press)
	cases := []struct {
		key: ghostty.Key,
		mods: ghostty.Mods,
		text, expected: string,
	}{
		{.Enter, {}, "", "\r"},
		{.Backspace, {}, "", "\x7f"},
		{.Arrow_Up, {}, "", "\x1b[A"},
		{.Arrow_Down, {.Shift}, "", "\x1b[1;2B"},
		{.Arrow_Right, {.Ctrl}, "", "\x1b[1;5C"},
		{.Arrow_Left, {.Shift, .Ctrl}, "", "\x1b[1;6D"},
		{.C, {.Ctrl}, "c", "\x03"},
		{.A, {}, "a", "a"},
		{.Unidentified, {}, "\u754c", "\u754c"},
		{.Shift_Left, {.Shift}, "", ""},
	}
	for item in cases {
		ghostty.key_event_set_key(event, item.key)
		ghostty.key_event_set_mods(event, item.mods)
		ghostty.key_event_set_utf8(event, raw_data(item.text), uint(len(item.text)))
		ghostty.key_event_set_unshifted_codepoint(event, 0)
		buffer: [64]u8
		n: uint
		result := ghostty.key_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
		testing.expect_value(t, result, SUCCESS)
		testing.expect_value(t, string(buffer[:n]), item.expected)
	}
	ghostty.key_event_set_key(event, .Arrow_Up)
	ghostty.key_event_set_mods(event, {})
	ghostty.key_event_set_utf8(event, nil, 0)
	required: uint
	testing.expect_value(t, ghostty.key_encoder_encode(encoder, event, nil, 0, &required), SPACE)
	testing.expect_value(t, required, 3)
	backarrow := true
	ghostty.key_encoder_setopt(encoder, .Backarrow_Key_Mode, &backarrow)
	ghostty.key_event_set_key(event, .Backspace)
	buffer: [64]u8
	n: uint
	result := ghostty.key_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x08")
	ghostty.key_event_set_action(event, .Release)
	result = ghostty.key_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, n, 0)
}

@(test)
key_modes_from_terminal :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 10, 3), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	encoder: ghostty.Key_Encoder
	if !testing.expect_value(t, ghostty.key_encoder_new(nil, &encoder), SUCCESS) {
		return
	}
	defer ghostty.key_encoder_free(encoder)
	event: ghostty.Key_Event
	if !testing.expect_value(t, ghostty.key_event_new(nil, &event), SUCCESS) {
		return
	}
	defer ghostty.key_event_free(event)
	ghostty.key_event_set_action(event, .Press)
	ghostty.key_event_set_key(event, .Arrow_Up)
	write(terminal, "\x1b[?1h")
	ghostty.key_encoder_setopt_from_terminal(encoder, terminal)
	buffer: [32]u8
	n: uint
	result := ghostty.key_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1bOA")
	write(terminal, "\x1b[?1l")
	ghostty.key_encoder_setopt_from_terminal(encoder, terminal)
	result = ghostty.key_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1b[A")
}

@(test)
mouse_sgr :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 80, 24), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	encoder: ghostty.Mouse_Encoder
	if !testing.expect_value(t, ghostty.mouse_encoder_new(nil, &encoder), SUCCESS) {
		return
	}
	defer ghostty.mouse_encoder_free(encoder)
	event: ghostty.Mouse_Event
	if !testing.expect_value(t, ghostty.mouse_event_new(nil, &event), SUCCESS) {
		return
	}
	defer ghostty.mouse_event_free(event)
	geometry := ghostty.sized(ghostty.Mouse_Encoder_Size)
	geometry.screen_width = 800
	geometry.screen_height = 480
	geometry.cell_width = 10
	geometry.cell_height = 20
	ghostty.mouse_encoder_setopt(encoder, .Size, &geometry)
	write(terminal, "\x1b[?1000h\x1b[?1006h")
	ghostty.mouse_encoder_setopt_from_terminal(encoder, terminal)
	ghostty.mouse_event_set_position(event, {x = 25, y = 65})
	ghostty.mouse_event_set_button(event, .Left)
	cases := []struct {
		action: ghostty.Mouse_Action,
		mods: ghostty.Mods,
		expected: string,
	}{
		{.Press, {}, "\x1b[<0;3;4M"},
		{.Release, {}, "\x1b[<0;3;4m"},
		{.Press, {.Ctrl}, "\x1b[<16;3;4M"},
		{.Motion, {}, ""},
	}
	for item in cases {
		ghostty.mouse_event_set_action(event, item.action)
		ghostty.mouse_event_set_mods(event, item.mods)
		buffer: [64]u8
		n: uint
		result := ghostty.mouse_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
		testing.expect_value(t, result, SUCCESS)
		testing.expect_value(t, string(buffer[:n]), item.expected)
	}
	ghostty.mouse_event_set_action(event, .Press)
	n: uint
	testing.expect_value(t, ghostty.mouse_encoder_encode(encoder, event, nil, 0, &n), SPACE)
	testing.expect_value(t, n, 9)
	write(terminal, "\x1b[?1000l")
	ghostty.mouse_encoder_setopt_from_terminal(encoder, terminal)
	buffer: [64]u8
	result := ghostty.mouse_encoder_encode(encoder, event, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, n, 0)
}

@(test)
focus_paste_and_modes :: proc(t: ^testing.T) {
	buffer: [64]u8
	n: uint
	testing.expect_value(t, ghostty.focus_encode(.Gained, raw_data(buffer[:]), len(buffer), &n), SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1b[I")
	testing.expect_value(t, ghostty.focus_encode(.Lost, raw_data(buffer[:]), len(buffer), &n), SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1b[O")
	testing.expect_value(t, ghostty.focus_encode(.Gained, nil, 0, &n), SPACE)
	testing.expect_value(t, n, 3)
	testing.expect(t, ghostty.paste_is_safe(raw_data(string("hello")), 5))
	testing.expect(t, !ghostty.paste_is_safe(raw_data(string("a\nb")), 3))
	testing.expect(t, !ghostty.paste_is_safe(raw_data(string("\x1b[201~")), 6))
	input := [5]u8{'a', '\n', '\x1b', '\x00', 'b'}
	result := ghostty.paste_encode(&input[0], len(input), true, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1b[200~a\n  b\x1b[201~")
	plain := [3]u8{'a', '\n', 'b'}
	result = ghostty.paste_encode(&plain[0], len(plain), false, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "a\rb")
	testing.expect_value(t, ghostty.paste_encode(&plain[0], len(plain), true, nil, 0, &n), SPACE)
	testing.expect_value(t, n, 15)
	testing.expect_value(t, ghostty.mode_new(2004, false), ghostty.MODE_BRACKETED_PASTE)
	testing.expect_value(t, ghostty.mode_value(ghostty.MODE_INSERT), 4)
	testing.expect(t, ghostty.mode_ansi(ghostty.MODE_INSERT))
	testing.expect(t, !ghostty.mode_ansi(ghostty.MODE_BRACKETED_PASTE))
	result = ghostty.mode_report_encode(
		ghostty.MODE_BRACKETED_PASTE, .Set, raw_data(buffer[:]), len(buffer), &n,
	)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1b[?2004;1$y")
	result = ghostty.mode_report_encode(ghostty.MODE_INSERT, .Reset, raw_data(buffer[:]), len(buffer), &n)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, string(buffer[:n]), "\x1b[4;2$y")
}
