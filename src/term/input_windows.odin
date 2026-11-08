package term

import "aio:ghostty"
import "aio:input"
import "core:fmt"
import "core:log"
import "core:sync"
import "core:unicode/utf16"

// ConPTY's win32-input-mode: ESC [ Vk ; Sc ; Uc ; Kd ; Cs ; Rc _ carries a complete console key event.
@(private)
append_win32_key :: proc(
	out: []u8,
	vk, scan_code, unit: u16,
	down: bool,
	state: u32,
	repeat: u16,
) -> int {
	text := fmt.bprintf(
		out,
		"\x1b[%d;%d;%d;%d;%d;%d_",
		vk,
		scan_code,
		unit,
		down ? 1 : 0,
		state,
		max(repeat, 1),
	)
	return len(text)
}

@(private)
text_units :: proc(text: string, out: []u16) -> []u16 {
	return out[:utf16.encode_string(out, text)]
}

// The most bytes append_win32_text writes for one UTF-16 unit: a press and a release record, each at
// most ESC [ 0;0;65535;1;0;1 _ (18 bytes), rounded up with room to spare.
@(private)
WIN32_TEXT_UNIT_BYTES :: 48

@(private)
append_win32_text :: proc(out: []u8, units: []u16) -> int {
	n := 0
	for unit in units {
		n += append_win32_key(out[n:], 0, 0, unit, true, 0, 1)
		n += append_win32_key(out[n:], 0, 0, unit, false, 0, 1)
	}
	return n
}

send_key :: proc(s: ^Session, event: input.Key_Event) -> bool {
	if !sync.atomic_load(&s.win32_input) {
		return send_key_vt(s, event)
	}
	sync.mutex_lock(&s.mutex)
	flags: ghostty.Kitty_Key_Flags
	result := ghostty.terminal_get(s.terminal, .Kitty_Keyboard_Flags, &flags)
	encoded: [128]u8
	n := 0
	if result == .Success && flags != {} {n = encode_key(s, event, encoded[:])}
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: reading keyboard protocol flags failed: %v", result)
		return false
	}
	// Carry negotiated VT bytes as Unicode events so ConPTY does not translate them back to legacy keys.
	if flags != {} {
		units: [128]u16
		buffer: [128 * WIN32_TEXT_UNIT_BYTES]u8
		written := append_win32_text(buffer[:], text_units(string(encoded[:n]), units[:]))
		return written > 0 && send_input(s, buffer[:written], len(event.text) > 0)
	}
	native := event.native
	units_buffer: [16]u16
	units := text_units(event.text, units_buffer[:])
	first := native.char
	if len(units) > 0 {
		first = units[0]
	}
	buffer: [512]u8
	n = append_win32_key(
		buffer[:],
		native.vk,
		native.scan_code,
		first,
		event.pressed,
		native.control_key_state,
		native.repeat_count,
	)
	if event.pressed && len(units) > 1 {
		n += append_win32_text(buffer[n:], units[1:])
	}
	return send_input(s, buffer[:n], len(event.text) > 0)
}

send_text :: proc(s: ^Session, text: string) -> bool {
	if !sync.atomic_load(&s.win32_input) {
		return send_input(s, transmute([]u8)text, true)
	}
	units := make([]u16, len(text), context.temp_allocator)
	data := make([]u8, len(text) * WIN32_TEXT_UNIT_BYTES, context.temp_allocator)
	n := append_win32_text(data, text_units(text, units))
	return send_input(s, data[:n], true)
}
