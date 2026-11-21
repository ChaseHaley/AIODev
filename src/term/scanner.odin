package term

import "core:bytes"

@(private)
WIN32_INPUT_MODE :: 9001

@(private)
Scan_State :: enum u8 {
	Ground,
	Escape,
	Csi,
	Private,
	Ignore,
}

// Tracks DEC private mode 9001 (win32-input-mode), which libghostty does not model, across reads.
Mode_Scanner :: struct {
	state:        Scan_State,
	parameter:    u32,
	targets_mode: bool,
}

// Returns the last win32-input-mode state set within data, and whether data set it at all.
scan_win32_input_mode :: proc(s: ^Mode_Scanner, data: []u8) -> (enabled, changed: bool) {
	for i := 0; i < len(data); i += 1 {
		b := data[i]
		switch s.state {
		case .Ground:
			// Output is mostly text: jump to the next escape instead of stepping through it.
			next := bytes.index_byte(data[i:], 0x1b)
			if next < 0 {return}
			i += next
			s.state = .Escape
		case .Escape:
			s.state = b == '[' ? .Csi : .Ground
		case .Csi:
			if b == '?' {
				s.state, s.parameter, s.targets_mode = .Private, 0, false
			} else {
				s.state = .Ground
			}
		case .Private:
			switch b {
			case '0' ..= '9':
				s.parameter = min(s.parameter * 10 + u32(b - '0'), 100_000)
			case ';':
				s.targets_mode ||= s.parameter == WIN32_INPUT_MODE
				s.parameter = 0
			case 'h', 'l':
				if s.targets_mode || s.parameter == WIN32_INPUT_MODE {
					enabled, changed = b == 'h', true
				}
				s.state = .Ground
			case 0x1b:
				s.state = .Escape
			case:
				s.state = b >= 0x40 && b <= 0x7e ? .Ground : .Ignore
			}
		case .Ignore:
			if b >= 0x40 && b <= 0x7e {
				s.state = .Ground
			}
		}
	}
	return
}

// Shell input mode reported via OSC 7502 (`\x1b]7502;mode=<value>\x07` or ST `\x1b\\`).
Shell_Mode :: enum u8 {
	None,
	Insert,
	Normal,
	Visual,
	Visual_Line,
}

@(private)
SHELL_MODE_OSC :: 7502

@(private)
Shell_Mode_Scan_State :: enum u8 {
	Ground,
	Escape,
	Osc_Number,
	Osc_Body,
	Osc_Esc,
	Osc_Ignore,
	Osc_Ignore_Esc,
}

// Scans OSC 7502 shell mode reports across PTY read chunks without modifying libghostty.
Shell_Mode_Scanner :: struct {
	state:      Shell_Mode_Scan_State,
	number:     u32,
	body:       [64]u8,
	body_len:   int,
	overflowed: bool,
}

// Returns the last shell mode reported within data, and whether data reported one at all.
scan_shell_mode :: proc(s: ^Shell_Mode_Scanner, data: []u8) -> (mode: Shell_Mode, changed: bool) {
	for i := 0; i < len(data); i += 1 {
		b := data[i]
		switch s.state {
		case .Ground:
			next := bytes.index_byte(data[i:], 0x1b)
			if next < 0 {return}
			i += next
			s.state = .Escape
		case .Escape:
			if b == ']' {
				s.state, s.number, s.body_len, s.overflowed = .Osc_Number, 0, 0, false
			} else if b != 0x1b {
				s.state = .Ground
			}
		case .Osc_Number:
			switch b {
			case '0' ..= '9':
				s.number = min(s.number * 10 + u32(b - '0'), 100_000)
			case ';':
				s.state = s.number == SHELL_MODE_OSC ? .Osc_Body : .Osc_Ignore
			case 0x07:
				s.state = .Ground
			case 0x1b:
				s.state = .Escape
			case:
				s.state = .Osc_Ignore
			}
		case .Osc_Body:
			if b == 0x07 {
				if parsed, ok := parse_shell_mode_payload(s.body[:s.body_len], s.overflowed); ok {
					mode, changed = parsed, true
				}
				s.state = .Ground
			} else if b == 0x1b {
				s.state = .Osc_Esc
			} else if s.body_len < len(s.body) {
				s.body[s.body_len] = b
				s.body_len += 1
			} else {
				s.overflowed = true
			}
		case .Osc_Esc:
			if b == '\\' {
				if parsed, ok := parse_shell_mode_payload(s.body[:s.body_len], s.overflowed); ok {
					mode, changed = parsed, true
				}
				s.state = .Ground
			} else if b == ']' {
				s.state, s.number, s.body_len, s.overflowed = .Osc_Number, 0, 0, false
			} else {
				s.state = .Ground
			}
		case .Osc_Ignore:
			if b == 0x07 {
				s.state = .Ground
			} else if b == 0x1b {
				s.state = .Osc_Ignore_Esc
			}
		case .Osc_Ignore_Esc:
			if b == '\\' {
				s.state = .Ground
			} else if b == ']' {
				s.state, s.number, s.body_len, s.overflowed = .Osc_Number, 0, 0, false
			} else {
				s.state = .Ground
			}
		}
	}
	return
}

@(private = "file")
parse_shell_mode_payload :: proc(raw: []u8, overflowed: bool) -> (Shell_Mode, bool) {
	if overflowed {return .None, false}
	payload := string(raw)
	prefix :: "mode="
	if len(payload) < len(prefix) || payload[:len(prefix)] != prefix {return .None, false}
	value := payload[len(prefix):]
	switch value {
	case "insert":
		return .Insert, true
	case "normal":
		return .Normal, true
	case "visual":
		return .Visual, true
	case "v-line":
		return .Visual_Line, true
	case "clear", "none", "":
		return .None, true
	}
	return .None, false
}
