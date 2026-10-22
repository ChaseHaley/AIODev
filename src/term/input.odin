package term

import "aio:ghostty"
import "aio:input"
import "aio:platform"
import "core:log"
import "core:strings"
import "core:sync"

Mouse_Action :: enum {
	Press,
	Release,
	Motion,
}

@(private)
key_action :: proc(event: platform.Key_Event) -> ghostty.Key_Action {
	if !event.pressed {
		return .Release
	}
	return event.repeat ? .Repeat : .Press
}

@(private)
ghostty_mods :: proc(modifiers: input.Modifiers) -> ghostty.Mods {
	return transmute(ghostty.Mods)modifiers
}

// Modifiers the keyboard layout used to produce the text: Shift, and Ctrl+Alt for AltGr.
@(private)
consumed_mods :: proc(event: platform.Key_Event) -> ghostty.Mods {
	consumed: ghostty.Mods
	if len(event.text) == 0 || event.text[0] < 0x20 || event.text[0] == 0x7f {
		return consumed
	}
	if .Shift in event.modifiers {
		consumed += {.Shift}
	}
	if .Control in event.modifiers && .Alt in event.modifiers {
		consumed += {.Ctrl, .Alt}
	}
	return consumed
}

@(private)
encode_key :: proc(s: ^Session, event: platform.Key_Event, out: []u8) -> int {
	e := s.key_event
	ghostty.key_encoder_setopt_from_terminal(s.key_encoder, s.terminal)
	ghostty.key_event_set_action(e, key_action(event))
	ghostty.key_event_set_key(e, ghostty.Key(event.key))
	ghostty.key_event_set_mods(e, ghostty_mods(event.modifiers))
	ghostty.key_event_set_consumed_mods(e, consumed_mods(event))
	ghostty.key_event_set_composing(e, false)
	ghostty.key_event_set_utf8(e, raw_data(event.text), len(event.text))
	ghostty.key_event_set_unshifted_codepoint(e, u32(event.unshifted))
	n: uint
	result := ghostty.key_encoder_encode(s.key_encoder, e, raw_data(out), len(out), &n)
	if result != .Success {
		log.errorf("term: key encoding failed: %v", result)
		return 0
	}
	return int(n)
}

@(private)
send_key_vt :: proc(s: ^Session, event: platform.Key_Event) -> bool {
	buffer: [128]u8
	sync.mutex_lock(&s.mutex)
	n := encode_key(s, event, buffer[:])
	sync.mutex_unlock(&s.mutex)
	return n > 0 && send_input(s, buffer[:n], len(event.text) > 0)
}

@(private)
send_input :: proc(s: ^Session, data: []u8, carries_text: bool) -> bool {
	if !queue_push(&s.queue, data) {
		return false
	}
	if carries_text && len(data) > 0 {
		scroll_to_bottom(s)
	}
	return true
}

@(private)
normalize_newlines :: proc(text: string, out: []u8) -> []u8 {
	n := 0
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
			i += 1
		}
		out[n] = c == '\n' ? '\r' : c
		n += 1
	}
	return out[:n]
}

Paste_Result :: enum {
	Sent,
	// The text has a line break and the program has not enabled bracketed paste, so each line would run as
	// typed input. Nothing was sent; paste again with allow_unsafe once the user confirms.
	Unsafe,
	Failed,
}

paste :: proc(s: ^Session, text: string, allow_unsafe := false) -> Paste_Result {
	if len(text) == 0 {
		return .Sent
	}
	data := normalize_newlines(text, make([]u8, len(text), context.temp_allocator))
	sync.mutex_lock(&s.mutex)
	bracketed := mode_enabled(s, ghostty.MODE_BRACKETED_PASTE)
	sync.mutex_unlock(&s.mutex)
	if !bracketed && !allow_unsafe && strings.index_byte(string(data), '\r') >= 0 {
		return .Unsafe
	}
	needed: uint
	result := ghostty.paste_encode(raw_data(data), len(data), bracketed, nil, 0, &needed)
	if result != .Out_Of_Space && result != .Success {
		log.errorf("term: paste encoding failed: %v", result)
		return .Failed
	}
	encoded := make([]u8, needed, context.temp_allocator)
	written: uint
	result = ghostty.paste_encode(
		raw_data(data),
		len(data),
		bracketed,
		raw_data(encoded),
		needed,
		&written,
	)
	if result != .Success {
		log.errorf("term: paste encoding failed: %v", result)
		return .Failed
	}
	return send_input(s, encoded[:written], true) ? .Sent : .Failed
}

send_focus :: proc(s: ^Session, focused: bool) {
	sync.mutex_lock(&s.mutex)
	enabled := mode_enabled(s, ghostty.MODE_FOCUS_EVENT)
	sync.mutex_unlock(&s.mutex)
	if !enabled {
		return
	}
	buffer: [8]u8
	n: uint
	event: ghostty.Focus_Event = focused ? .Gained : .Lost
	if result := ghostty.focus_encode(event, raw_data(buffer[:]), len(buffer), &n);
	   result != .Success {
		log.errorf("term: focus encoding failed: %v", result)
		return
	}
	queue_push(&s.queue, buffer[:n])
}

mouse_tracking :: proc(s: ^Session) -> bool {
	sync.mutex_lock(&s.mutex)
	defer sync.mutex_unlock(&s.mutex)
	tracking: bool
	return ghostty.terminal_get(s.terminal, .Mouse_Tracking, &tracking) == .Success && tracking
}

@(private)
ghostty_button :: proc(button: input.Mouse_Button) -> ghostty.Mouse_Button {
	switch button {
	case .Left:
		return .Left
	case .Right:
		return .Right
	case .Middle:
		return .Middle
	case .Back:
		return .Eight
	case .Forward:
		return .Nine
	}
	return .Unknown
}

@(private)
encoder_size :: proc(g: Geometry) -> ghostty.Mouse_Encoder_Size {
	grid_width := u32(g.columns) * g.cell_width
	grid_height := u32(g.rows) * g.cell_height
	size := ghostty.sized(ghostty.Mouse_Encoder_Size)
	size.screen_width, size.screen_height = g.surface_width, g.surface_height
	size.cell_width, size.cell_height = g.cell_width, g.cell_height
	size.padding_left, size.padding_top = g.padding_left, g.padding_top
	size.padding_right = g.surface_width - min(g.surface_width, g.padding_left + grid_width)
	size.padding_bottom = g.surface_height - min(g.surface_height, g.padding_top + grid_height)
	return size
}

// Encodes one mouse report; the caller holds the mutex and has configured the encoder.
@(private)
encode_mouse :: proc(
	s: ^Session,
	action: ghostty.Mouse_Action,
	button: Maybe(ghostty.Mouse_Button),
	modifiers: input.Modifiers,
	x, y: f32,
	out: []u8,
) -> int {
	e := s.mouse_event
	ghostty.mouse_event_set_action(e, action)
	if b, ok := button.?; ok {
		ghostty.mouse_event_set_button(e, b)
	} else {
		ghostty.mouse_event_clear_button(e)
	}
	ghostty.mouse_event_set_mods(e, ghostty_mods(modifiers))
	ghostty.mouse_event_set_position(e, {x, y})
	n: uint
	result := ghostty.mouse_encoder_encode(s.mouse_encoder, e, raw_data(out), len(out), &n)
	if result != .Success {
		log.errorf("term: mouse encoding failed: %v", result)
		return 0
	}
	return int(n)
}

@(private)
configure_mouse_encoder :: proc(s: ^Session, any_pressed: bool) {
	size := encoder_size(s.geometry)
	pressed := any_pressed
	ghostty.mouse_encoder_setopt_from_terminal(s.mouse_encoder, s.terminal)
	ghostty.mouse_encoder_setopt(s.mouse_encoder, .Size, &size)
	ghostty.mouse_encoder_setopt(s.mouse_encoder, .Any_Button_Pressed, &pressed)
}

// Reports a mouse event to the running program; x and y are surface pixels.
send_mouse :: proc(
	s: ^Session,
	action: Mouse_Action,
	button: Maybe(input.Mouse_Button),
	pressed: input.Mouse_Buttons,
	modifiers: input.Modifiers,
	x, y: f32,
) {
	ghostty_action: ghostty.Mouse_Action
	switch action {
	case .Press:
		ghostty_action = .Press
	case .Release:
		ghostty_action = .Release
	case .Motion:
		ghostty_action = .Motion
	}
	target: Maybe(ghostty.Mouse_Button)
	if b, ok := button.?; ok {
		target = ghostty_button(b)
	}
	buffer: [64]u8
	sync.mutex_lock(&s.mutex)
	configure_mouse_encoder(s, card(pressed) > 0)
	n := encode_mouse(s, ghostty_action, target, modifiers, x, y, buffer[:])
	sync.mutex_unlock(&s.mutex)
	if n > 0 {
		queue_push(&s.queue, buffer[:n])
	}
}

// Applies wheel motion: reported to programs that track the mouse (unless Shift is held),
// turned into arrow keys on the alternate screen when alternate scroll is on, otherwise scrolls history.
scroll :: proc(s: ^Session, rows: int, modifiers: input.Modifiers, x, y: f32) {
	if rows == 0 {
		return
	}
	buffer: [512]u8
	n := 0
	sync.mutex_lock(&s.mutex)
	tracking: bool
	screen: ghostty.Terminal_Screen
	tracked := ghostty.terminal_get(s.terminal, .Mouse_Tracking, &tracking) == .Success && tracking
	tracked &&= .Shift not_in modifiers
	alternate :=
		ghostty.terminal_get(s.terminal, .Active_Screen, &screen) == .Success &&
		screen == .Alternate
	alternate &&= mode_enabled(s, ghostty.MODE_ALT_SCROLL)
	steps := min(abs(rows), 8)
	switch {
	case tracked:
		configure_mouse_encoder(s, false)
		button: ghostty.Mouse_Button = rows > 0 ? .Four : .Five
		for _ in 0 ..< steps {
			n += encode_mouse(s, .Press, button, modifiers, x, y, buffer[n:])
		}
	case alternate:
		key: input.Key = rows > 0 ? .Arrow_Up : .Arrow_Down
		for _ in 0 ..< steps {
			n += encode_key(s, {key = key, pressed = true}, buffer[n:])
		}
	case:
		ghostty.terminal_scroll_viewport(s.terminal, {tag = .Delta, value = {delta = -rows}})
	}
	sync.mutex_unlock(&s.mutex)
	if n > 0 {
		queue_push(&s.queue, buffer[:n])
	}
	mark_changed(s)
}
