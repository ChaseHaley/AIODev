package control

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "aio:commands"
import "aio:input"
import "aio:layout"

Range :: struct { first: int, last: int, specified: bool }
MAX_GRID_DIMENSION :: 1000
Position :: struct { x, y: int }
Ping :: struct {}
Screen :: struct { rows: Range }
Cells :: struct { row: int, columns: Range }
State :: struct {}
Wait_Kind :: enum { Text, Gone, Idle, Frame }
Wait :: struct { kind: Wait_Kind, text: string, idle_ms, timeout_ms: int }
Expect_Kind :: enum { Text, No_Text, Cursor, Cell, State }
Expect :: struct {
	kind: Expect_Kind,
	text: string,
	position: Position,
	attributes: []string,
	key, value: string,
}
Type :: struct { text: string }
Key :: struct { chords: [dynamic]commands.Shortcut }
Run :: struct { line: string, idle_ms, timeout_ms: int }
Mouse_Kind :: enum { Move, Down, Up, Click, Drag, Wheel }
Mouse :: struct {
	kind: Mouse_Kind,
	position, end: Position,
	lines: int,
	button: input.Mouse_Button,
	modifiers: input.Modifiers,
	pixels, screen: bool,
}
Window_Select :: struct { id: u64 }
Window_Move :: struct { position: Position }
Focus :: struct { focused: bool }
Resize :: struct { columns, rows: int }
Dpi :: struct { value: int }
Tray_Action :: enum { Open, Hide, Quit }
Tray :: struct { action: Tray_Action }
Command :: struct { name: string, direction: layout.Direction, ratio: f32, focus: bool }
Help :: struct { command: string }
Request :: union { Ping, Screen, Cells, State, Wait, Expect, Type, Key, Run, Mouse,
	Focus, Resize, Dpi, Tray, Command, Window_Select, Window_Move, Help }
Parse_Error :: struct { argument: string, advice: string }

@(private, require_results)
number :: proc(s: string, low: int = 0, high: int = int(max(i32))) -> (int, bool) {
	if len(s) == 0 { return 0, false }
	for c in s {
		if c < '0' || c > '9' { return 0, false }
	}
	n, ok := strconv.parse_int(s)
	return n, ok && n >= low && n <= high
}

@(private, require_results)
pair :: proc(s: string, separator: u8, signed: bool = false) -> (Position, bool) {
	i := strings.index_byte(s, separator)
	if i < 0 { return {}, false }
	x, a := number(s[:i])
	y, b := number(s[i+1:])
	if signed {
		x, a = signed_number(s[:i])
		y, b = signed_number(s[i+1:])
	}
	return {x, y}, a && b
}

@(private, require_results)
signed_number :: proc(s: string) -> (int, bool) {
	digits := s
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') { digits = digits[1:] }
	_, valid := number(digits, 0, int(max(i32))+1)
	if !valid { return 0, false }
	n, ok := strconv.parse_int(s)
	return n, ok && n >= int(min(i32)) && n <= int(max(i32))
}

@(private, require_results)
parse_range :: proc(s: string, single: bool) -> (Range, bool) {
	i := strings.index_byte(s, ':')
	if i < 0 {
		n, ok := number(s)
		return {n, n, true}, ok && single
	}
	p, ok := pair(s, ':')
	return {p.x, p.y, true}, ok && p.x <= p.y
}

@(private)
assignment :: proc(s: string) -> (string, string, bool) {
	i := strings.index_byte(s, '=')
	if i <= 0 { return "", "", false }
	return s[:i], s[i+1:], true
}

@(private)
valid_attribute :: proc(s: string) -> bool {
	k, v, ok := assignment(s)
	if !ok { return false }
	switch k {
	case "text":
		return true
	case "fg", "bg", "underline-color":
		if v == "default" { return true }
		if len(v) != 7 || v[0] != '#' { return false }
		for c in v[1:] {
			if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
				return false
			}
		}
		return true
	case "underline":
		return v == "none" || v == "single" || v == "double" || v == "curly" ||
		       v == "dotted" || v == "dashed"
	case "bold", "italic", "faint", "blink", "inverse", "invisible", "strike", "overline",
	     "selected", "wide":
		return v == "true" || v == "false"
	}
	return false
}

request_destroy :: proc(r: ^Request) {
	if k, ok := r^.(Key); ok {
		delete(k.chords)
	}
	r^ = {}
}

@(require_results)
parse :: proc(args: []string, allocator := context.allocator) -> (Request, Parse_Error) {
	if len(args) == 0 { return {}, {"<command>", "choose a command; use help"} }
	for arg in args {
		if !utf8.valid_string(arg) { return {}, {arg, "use valid UTF-8 text"} }
	}
	bad := Parse_Error{args[0], "use help for this command's grammar"}
	switch args[0] {
	case "ping", "state":
		if len(args) != 1 { return {}, {args[1], "remove the extra argument"} }
		if args[0] == "ping" { return Ping{}, {} }
		return State{}, {}
	case "help":
		if len(args) > 2 { return {}, {args[2], "use help [command]"} }
		return Help{len(args) == 2 ? args[1] : ""}, {}
	case "window":
		if len(args) != 3 { return {}, bad }
		switch args[1] {
		case "select":
			for c in args[2] { if c < '0' || c > '9' { return {}, bad } }
			id, ok := strconv.parse_uint(args[2])
			if !ok || id == 0 { return {}, {args[2], "use a nonzero window id from state"} }
			return Window_Select{u64(id)}, {}
		case "move":
			position, ok := pair(args[2], ',', true)
			if !ok { return {}, {args[2], "use signed 32-bit screen x,y"} }
			return Window_Move{position}, {}
		}
		return {}, bad
	case "screen":
		if len(args) == 1 { return Screen{}, {} }
		if len(args) != 2 { return {}, bad }
		r, ok := parse_range(args[1], true)
		if !ok { return {}, {args[1], "use a nonnegative row or first:last"} }
		return Screen{r}, {}
	case "cells":
		if len(args) < 2 || len(args) > 3 { return {}, bad }
		n, ok := number(args[1])
		if !ok { return {}, {args[1], "use a nonnegative row"} }
		r: Range
		if len(args) == 3 {
			r, ok = parse_range(args[2], false)
			if !ok { return {}, {args[2], "use first:last columns"} }
		}
		return Cells{n, r}, {}
	case "command":
		if len(args) < 2 || args[1] == "" { return {}, bad }
		r := Command{name = args[1], direction = .Right, ratio = 0.5, focus = true}
		if len(args) > 2 && r.name != "pane.split" { return {}, bad }
		seen: [3]bool
		for i := 2; i < len(args); i += 2 {
			if i+1 >= len(args) { return {}, bad }
			index: int
			switch args[i] {
			case "--direction":
				index = 0
				switch args[i+1] {
				case "left": r.direction = .Left
				case "right": r.direction = .Right
				case "up": r.direction = .Up
				case "down": r.direction = .Down
				case: return {}, bad
				}
			case "--ratio":
				index = 1
				n, ok := strconv.parse_f32(args[i+1])
				if !ok || !(n >= 0.05 && n <= 0.95) { return {}, bad }
				r.ratio = n
			case "--focus":
				index = 2
				if args[i+1] != "true" && args[i+1] != "false" { return {}, bad }
				r.focus = args[i+1] == "true"
			case: return {}, bad
			}
			if seen[index] { return {}, bad }
			seen[index] = true
		}
		return r, {}
	case "type", "focus", "tray", "resize", "dpi":
		if len(args) != 2 { return {}, bad }
		s := args[1]
		switch args[0] {
		case "type":
			return Type{s}, {}
		case "focus":
			if s == "in" || s == "out" { return Focus{s == "in"}, {} }
		case "tray":
			switch s {
			case "open":
				return Tray{.Open}, {}
			case "hide":
				return Tray{.Hide}, {}
			case "quit":
				return Tray{.Quit}, {}
			}
		case "resize":
			p, ok := pair(s, 'x')
			if ok && p.x >= 1 && p.y >= 1 && p.x <= MAX_GRID_DIMENSION && p.y <= MAX_GRID_DIMENSION {
				return Resize{p.x, p.y}, {}
			}
		case "dpi":
			n, ok := number(s, 48, 768)
			if ok { return Dpi{n}, {} }
		}
		return {}, {s, "use help for valid values and ranges"}
	case "key":
		if len(args) < 2 { return {}, bad }
		k := Key{chords = make([dynamic]commands.Shortcut, allocator)}
		for s in args[1:] {
			chord, ok := commands.parse_shortcut(s)
			if !ok || .Physical in chord.modifiers || .Leader in chord.modifiers {
				delete(k.chords)
				return {}, {s, "use a chord such as Ctrl+Shift+P"}
			}
			if _, err := append(&k.chords, chord); err != nil {
				delete(k.chords)
				return {}, {s, "not enough memory for chords"}
			}
		}
		return k, {}
	case "run", "wait":
		if len(args) < 2 { return {}, bad }
		w := Wait{idle_ms = 300, timeout_ms = 5000}
		start := 2
		if args[0] == "run" {
			w.text, w.timeout_ms = args[1], 10000
		} else {
			switch args[1] {
			case "text", "gone":
				if len(args) < 3 { return {}, bad }
				w.kind = args[1] == "text" ? .Text : .Gone
				w.text, start = args[2], 3
			case "frame":
				w.kind = .Frame
			case "idle":
				w.kind = .Idle
				if len(args) > 2 && !strings.has_prefix(args[2], "--") {
					n, ok := number(args[2])
					if !ok { return {}, {args[2], "use nonnegative milliseconds"} }
					w.idle_ms, start = n, 3
				}
			case:
				return {}, {args[1], "choose text, gone, idle, or frame"}
			}
		}
		seen_timeout, seen_idle := false, false
		for i := start; i < len(args); i += 2 {
			if i+1 == len(args) { return {}, {args[i], "supply milliseconds after this option"} }
			n, ok := number(args[i+1])
			if !ok { return {}, {args[i+1], "use nonnegative milliseconds"} }
			switch args[i] {
			case "--timeout":
				if seen_timeout { return {}, {args[i], "use this option once"} }
				w.timeout_ms, seen_timeout = n, true
			case "--idle":
				if args[0] != "run" || seen_idle { return {}, {args[i], "use --idle once on run"} }
				w.idle_ms, seen_idle = n, true
			case:
				return {}, {args[i], "use --timeout, or --idle on run"}
			}
		}
		if args[0] == "run" { return Run{w.text, w.idle_ms, w.timeout_ms}, {} }
		return w, {}
	case "expect":
		if len(args) < 3 { return {}, bad }
		e: Expect
		switch args[1] {
		case "text", "no-text":
			if len(args) != 3 { return {}, bad }
			e.kind, e.text = args[1] == "text" ? .Text : .No_Text, args[2]
		case "cursor", "cell":
			p, ok := pair(args[2], ',')
			if !ok { return {}, {args[2], "use nonnegative col,row"} }
			e.kind, e.position = args[1] == "cell" ? .Cell : .Cursor, p
			if e.kind == .Cursor && len(args) != 3 || e.kind == .Cell && len(args) < 4 {
				return {}, bad
			}
			e.attributes = args[3:]
			for a in e.attributes {
				if !valid_attribute(a) { return {}, {a, "use a cell attribute=value; see help expect"} }
			}
		case "state":
			if len(args) != 3 { return {}, bad }
			k, v, ok := assignment(args[2])
			if !ok { return {}, {args[2], "use key=value"} }
			e.kind, e.key, e.value = .State, k, v
		case:
			return {}, {args[1], "choose text, no-text, cursor, cell, or state"}
		}
		return e, {}
	case "mouse":
		return parse_mouse(args)
	}
	return {}, {args[0], "unknown command; use help"}
}

@(private, require_results)
parse_mouse :: proc(args: []string) -> (Request, Parse_Error) {
	bad := Parse_Error{args[0], "use mouse move|down|up|click|drag|wheel col,row; see help mouse"}
	if len(args) < 3 { return {}, bad }
	m := Mouse{button = .Left}
	switch args[1] {
	case "move":
		m.kind = .Move
	case "down":
		m.kind = .Down
	case "up":
		m.kind = .Up
	case "click":
		m.kind = .Click
	case "drag":
		m.kind = .Drag
	case "wheel":
		m.kind = .Wheel
	case:
		return {}, {args[1], bad.advice}
	}
	p, ok := pair(args[2], ',', true)
	if !ok { return {}, {args[2], "use col,row, pixel x,y with --px, or signed x,y with --screen"} }
	m.position = p
	i := 3
	if m.kind == .Drag || m.kind == .Wheel {
		if len(args) < 4 { return {}, bad }
		if m.kind == .Drag {
			m.end, ok = pair(args[3], ',', true)
		} else {
			m.lines, ok = strconv.parse_int(args[3])
			ok &&= m.lines >= int(min(i32)) && m.lines <= int(max(i32))
		}
		if !ok { return {}, {args[3], "use a position for drag, signed lines for wheel"} }
		i = 4
	}
	seen_button, seen_mods := false, false
	for i < len(args) {
		option := args[i]
		if (option == "--px" || option == "--screen") && !m.pixels && !m.screen {
			m.pixels, m.screen = option == "--px", option == "--screen"
			i += 1
			continue
		}
		if i+1 >= len(args) { return {}, {option, "supply an option value; see help mouse"} }
		s := args[i+1]
		switch option {
		case "--button":
			if seen_button { return {}, {option, "use --button once"} }
			seen_button = true
			switch s {
			case "left":
				m.button = .Left
			case "right":
				m.button = .Right
			case "middle":
				m.button = .Middle
			case:
				return {}, {s, "choose left, right, or middle"}
			}
		case "--mods":
			if seen_mods { return {}, {option, "use --mods once"} }
			seen_mods = true
			// The shortcut parser owns modifier spelling and duplicate detection.
			buffer: [256]u8
			if len(s)+2 > len(buffer) { return {}, {s, "use modifiers such as Ctrl+Shift"} }
			n := copy(buffer[:], s)
			copy(buffer[n:], "+A")
			chord, valid := commands.parse_shortcut(string(buffer[:n+2]))
			if !valid { return {}, {s, "use modifiers such as Ctrl+Shift"} }
			m.modifiers = chord.modifiers
		case:
			return {}, {option, "choose --button, --mods, --px, or --screen"}
		}
		i += 2
	}
	if !m.screen && (m.position.x < 0 || m.position.y < 0 || m.end.x < 0 || m.end.y < 0) {
		return {}, {args[2], "negative positions require --screen"}
	}
	return m, {}
}
