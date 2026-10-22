package term

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
	for b in data {
		switch s.state {
		case .Ground:
			if b == 0x1b {
				s.state = .Escape
			}
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
