package term

import "core:fmt"
import "core:sync"
import "core:unicode/utf16"
import "aio:platform"

// ConPTY's win32-input-mode: ESC [ Vk ; Sc ; Uc ; Kd ; Cs ; Rc _ carries a complete console key event.
@(private)
append_win32_key :: proc(out: []u8, vk, scan_code, unit: u16, down: bool, state: u32, repeat: u16) -> int {
	text := fmt.bprintf(out, "\x1b[%d;%d;%d;%d;%d;%d_", vk, scan_code, unit, down ? 1 : 0, state, max(repeat, 1))
	return len(text)
}

@(private)
text_units :: proc(text: string, out: []u16) -> []u16 {
	return out[:utf16.encode_string(out, text)]
}

send_key :: proc(s: ^Session, event: platform.Key_Event) -> bool {
	if !sync.atomic_load(&s.win32_input) {
		return send_key_vt(s, event)
	}
	native := event.native
	units_buffer: [16]u16
	units := text_units(event.text, units_buffer[:])
	first := native.char
	if len(units) > 0 {
		first = units[0]
	}
	buffer: [512]u8
	n := append_win32_key(
		buffer[:], native.vk, native.scan_code, first, event.pressed, native.control_key_state, native.repeat_count,
	)
	if event.pressed && len(units) > 1 {
		for unit in units[1:] {
			n += append_win32_key(buffer[n:], 0, 0, unit, true, 0, 1)
			n += append_win32_key(buffer[n:], 0, 0, unit, false, 0, 1)
		}
	}
	if !event.pressed {
		return queue_push(&s.queue, buffer[:n])
	}
	return send_input(s, buffer[:n])
}

send_text :: proc(s: ^Session, text: string) -> bool {
	if !sync.atomic_load(&s.win32_input) {
		return send_input(s, transmute([]u8)text)
	}
	units := make([]u16, len(text), context.temp_allocator)
	data := make([dynamic]u8, 0, len(text) * 48, context.temp_allocator)
	sequence: [64]u8
	for unit in text_units(text, units) {
		n := append_win32_key(sequence[:], 0, 0, unit, true, 0, 1)
		n += append_win32_key(sequence[n:], 0, 0, unit, false, 0, 1)
		append(&data, ..sequence[:n])
	}
	return send_input(s, data[:])
}
