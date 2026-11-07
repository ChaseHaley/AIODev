package term

import "aio:ghostty"
import "aio:input"
import "core:log"
import "core:strings"
import "core:sync"

Mouse_Action :: enum {
	Press,
	Release,
	Motion,
}

@(private)
key_action :: proc(event: input.Key_Event) -> ghostty.Key_Action {
	if !event.pressed {
		return .Release
	}
	return event.repeat ? .Repeat : .Press
}

// Leader and Physical are shortcut-binding flags, not device state, so they never reach the encoder.
@(private)
ghostty_mods :: proc(modifiers: input.Modifiers) -> ghostty.Mods {
	mods: ghostty.Mods
	for modifier in modifiers {
		switch modifier {
		case .Shift:
			mods += {.Shift}
		case .Control:
			mods += {.Ctrl}
		case .Alt:
			mods += {.Alt}
		case .Super:
			mods += {.Super}
		case .Caps_Lock:
			mods += {.Caps_Lock}
		case .Num_Lock:
			mods += {.Num_Lock}
		case .Right_Shift:
			mods += {.Shift_Side}
		case .Right_Control:
			mods += {.Ctrl_Side}
		case .Right_Alt:
			mods += {.Alt_Side}
		case .Right_Super:
			mods += {.Super_Side}
		case .Leader, .Physical:
		}
	}
	return mods
}

// Modifiers the keyboard layout used to produce the text: Shift, and Ctrl+Alt for AltGr.
@(private)
consumed_mods :: proc(event: input.Key_Event) -> ghostty.Mods {
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
encode_key :: proc(s: ^Session, event: input.Key_Event, out: []u8) -> int {
	e := s.key_event
	ghostty.key_encoder_setopt_from_terminal(s.key_encoder, s.terminal)
	ghostty.key_event_set_action(e, key_action(event))
	ghostty.key_event_set_key(e, ghostty_keys[event.key])
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
send_key_vt :: proc(s: ^Session, event: input.Key_Event) -> bool {
	buffer: [128]u8
	sync.mutex_lock(&s.mutex)
	n := encode_key(s, event, buffer[:])
	sync.mutex_unlock(&s.mutex)
	return n > 0 && send_input(s, buffer[:n], len(event.text) > 0)
}

@(private)
send_input :: proc(s: ^Session, data: []u8, carries_text: bool) -> bool {
	if queue_push(&s.queue, data) != .Queued {
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
	extent := grid_extent(g)
	size := ghostty.sized(ghostty.Mouse_Encoder_Size)
	size.screen_width, size.screen_height = g.surface_width, g.surface_height
	size.cell_width, size.cell_height = g.cell_width, g.cell_height
	size.padding_left, size.padding_top = g.padding_left, g.padding_top
	size.padding_right, size.padding_bottom = extent.padding_right, extent.padding_bottom
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
	} else if action == .Motion {
		for held in pressed {
			target = ghostty_button(held)
			break
		}
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

// Maps by name, so the compiler rejects an input key the encoder does not name.
@(private)
@(rodata)
ghostty_keys := [input.Key]ghostty.Key {
	.Unidentified           = .Unidentified,
	.Backquote              = .Backquote,
	.Backslash              = .Backslash,
	.Bracket_Left           = .Bracket_Left,
	.Bracket_Right          = .Bracket_Right,
	.Comma                  = .Comma,
	.Digit_0                = .Digit_0,
	.Digit_1                = .Digit_1,
	.Digit_2                = .Digit_2,
	.Digit_3                = .Digit_3,
	.Digit_4                = .Digit_4,
	.Digit_5                = .Digit_5,
	.Digit_6                = .Digit_6,
	.Digit_7                = .Digit_7,
	.Digit_8                = .Digit_8,
	.Digit_9                = .Digit_9,
	.Equal                  = .Equal,
	.Intl_Backslash         = .Intl_Backslash,
	.Intl_Ro                = .Intl_Ro,
	.Intl_Yen               = .Intl_Yen,
	.A                      = .A,
	.B                      = .B,
	.C                      = .C,
	.D                      = .D,
	.E                      = .E,
	.F                      = .F,
	.G                      = .G,
	.H                      = .H,
	.I                      = .I,
	.J                      = .J,
	.K                      = .K,
	.L                      = .L,
	.M                      = .M,
	.N                      = .N,
	.O                      = .O,
	.P                      = .P,
	.Q                      = .Q,
	.R                      = .R,
	.S                      = .S,
	.T                      = .T,
	.U                      = .U,
	.V                      = .V,
	.W                      = .W,
	.X                      = .X,
	.Y                      = .Y,
	.Z                      = .Z,
	.Minus                  = .Minus,
	.Period                 = .Period,
	.Quote                  = .Quote,
	.Semicolon              = .Semicolon,
	.Slash                  = .Slash,
	.Alt_Left               = .Alt_Left,
	.Alt_Right              = .Alt_Right,
	.Backspace              = .Backspace,
	.Caps_Lock              = .Caps_Lock,
	.Context_Menu           = .Context_Menu,
	.Control_Left           = .Control_Left,
	.Control_Right          = .Control_Right,
	.Enter                  = .Enter,
	.Meta_Left              = .Meta_Left,
	.Meta_Right             = .Meta_Right,
	.Shift_Left             = .Shift_Left,
	.Shift_Right            = .Shift_Right,
	.Space                  = .Space,
	.Tab                    = .Tab,
	.Convert                = .Convert,
	.Kana_Mode              = .Kana_Mode,
	.Non_Convert            = .Non_Convert,
	.Delete                 = .Delete,
	.End                    = .End,
	.Help                   = .Help,
	.Home                   = .Home,
	.Insert                 = .Insert,
	.Page_Down              = .Page_Down,
	.Page_Up                = .Page_Up,
	.Arrow_Down             = .Arrow_Down,
	.Arrow_Left             = .Arrow_Left,
	.Arrow_Right            = .Arrow_Right,
	.Arrow_Up               = .Arrow_Up,
	.Num_Lock               = .Num_Lock,
	.Numpad_0               = .Numpad_0,
	.Numpad_1               = .Numpad_1,
	.Numpad_2               = .Numpad_2,
	.Numpad_3               = .Numpad_3,
	.Numpad_4               = .Numpad_4,
	.Numpad_5               = .Numpad_5,
	.Numpad_6               = .Numpad_6,
	.Numpad_7               = .Numpad_7,
	.Numpad_8               = .Numpad_8,
	.Numpad_9               = .Numpad_9,
	.Numpad_Add             = .Numpad_Add,
	.Numpad_Backspace       = .Numpad_Backspace,
	.Numpad_Clear           = .Numpad_Clear,
	.Numpad_Clear_Entry     = .Numpad_Clear_Entry,
	.Numpad_Comma           = .Numpad_Comma,
	.Numpad_Decimal         = .Numpad_Decimal,
	.Numpad_Divide          = .Numpad_Divide,
	.Numpad_Enter           = .Numpad_Enter,
	.Numpad_Equal           = .Numpad_Equal,
	.Numpad_Memory_Add      = .Numpad_Memory_Add,
	.Numpad_Memory_Clear    = .Numpad_Memory_Clear,
	.Numpad_Memory_Recall   = .Numpad_Memory_Recall,
	.Numpad_Memory_Store    = .Numpad_Memory_Store,
	.Numpad_Memory_Subtract = .Numpad_Memory_Subtract,
	.Numpad_Multiply        = .Numpad_Multiply,
	.Numpad_Paren_Left      = .Numpad_Paren_Left,
	.Numpad_Paren_Right     = .Numpad_Paren_Right,
	.Numpad_Subtract        = .Numpad_Subtract,
	.Numpad_Separator       = .Numpad_Separator,
	.Numpad_Up              = .Numpad_Up,
	.Numpad_Down            = .Numpad_Down,
	.Numpad_Right           = .Numpad_Right,
	.Numpad_Left            = .Numpad_Left,
	.Numpad_Begin           = .Numpad_Begin,
	.Numpad_Home            = .Numpad_Home,
	.Numpad_End             = .Numpad_End,
	.Numpad_Insert          = .Numpad_Insert,
	.Numpad_Delete          = .Numpad_Delete,
	.Numpad_Page_Up         = .Numpad_Page_Up,
	.Numpad_Page_Down       = .Numpad_Page_Down,
	.Escape                 = .Escape,
	.F1                     = .F1,
	.F2                     = .F2,
	.F3                     = .F3,
	.F4                     = .F4,
	.F5                     = .F5,
	.F6                     = .F6,
	.F7                     = .F7,
	.F8                     = .F8,
	.F9                     = .F9,
	.F10                    = .F10,
	.F11                    = .F11,
	.F12                    = .F12,
	.F13                    = .F13,
	.F14                    = .F14,
	.F15                    = .F15,
	.F16                    = .F16,
	.F17                    = .F17,
	.F18                    = .F18,
	.F19                    = .F19,
	.F20                    = .F20,
	.F21                    = .F21,
	.F22                    = .F22,
	.F23                    = .F23,
	.F24                    = .F24,
	.F25                    = .F25,
	.Fn                     = .Fn,
	.Fn_Lock                = .Fn_Lock,
	.Print_Screen           = .Print_Screen,
	.Scroll_Lock            = .Scroll_Lock,
	.Pause                  = .Pause,
	.Browser_Back           = .Browser_Back,
	.Browser_Favorites      = .Browser_Favorites,
	.Browser_Forward        = .Browser_Forward,
	.Browser_Home           = .Browser_Home,
	.Browser_Refresh        = .Browser_Refresh,
	.Browser_Search         = .Browser_Search,
	.Browser_Stop           = .Browser_Stop,
	.Eject                  = .Eject,
	.Launch_App_1           = .Launch_App_1,
	.Launch_App_2           = .Launch_App_2,
	.Launch_Mail            = .Launch_Mail,
	.Media_Play_Pause       = .Media_Play_Pause,
	.Media_Select           = .Media_Select,
	.Media_Stop             = .Media_Stop,
	.Media_Track_Next       = .Media_Track_Next,
	.Media_Track_Previous   = .Media_Track_Previous,
	.Power                  = .Power,
	.Sleep                  = .Sleep,
	.Audio_Volume_Down      = .Audio_Volume_Down,
	.Audio_Volume_Mute      = .Audio_Volume_Mute,
	.Audio_Volume_Up        = .Audio_Volume_Up,
	.Wake_Up                = .Wake_Up,
	.Copy                   = .Copy,
	.Cut                    = .Cut,
	.Paste                  = .Paste,
}
