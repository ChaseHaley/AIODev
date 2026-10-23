package control

import "aio:commands"
import "aio:input"
import "aio:layout"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Range :: struct {
	first:     int,
	last:      int,
	specified: bool,
}
MAX_GRID_DIMENSION :: 1000
Position :: struct {
	x, y: int,
}
Ping :: struct {}
Screen :: struct {
	rows: Range,
}
Cells :: struct {
	row:     int,
	columns: Range,
}
State :: struct {}
Wait_Kind :: enum {
	Text,
	Gone,
	Idle,
	Frame,
}
Wait :: struct {
	kind:                Wait_Kind,
	text:                string,
	idle_ms, timeout_ms: int,
}
Expect_Kind :: enum {
	Text,
	No_Text,
	Cursor,
	Cell,
	State,
}
Expect :: struct {
	kind:       Expect_Kind,
	text:       string,
	position:   Position,
	attributes: []string,
	key, value: string,
}
Type :: struct {
	text: string,
}
Key :: struct {
	chords: [dynamic]commands.Shortcut,
}
Run :: struct {
	line:                string,
	idle_ms, timeout_ms: int,
}
Mouse_Kind :: enum {
	Move,
	Down,
	Up,
	Click,
	Drag,
	Wheel,
}
Mouse :: struct {
	kind:           Mouse_Kind,
	position, end:  Position,
	lines:          int,
	button:         input.Mouse_Button,
	modifiers:      input.Modifiers,
	pixels, screen: bool,
}
Window_Select :: struct {
	id: u64,
}
Window_Move :: struct {
	position: Position,
}
Focus :: struct {
	focused: bool,
}
Resize :: struct {
	columns, rows: int,
}
Dpi :: struct {
	value: int,
}
Tray_Action :: enum {
	Open,
	Hide,
	Quit,
}
Tray :: struct {
	action: Tray_Action,
}
Command :: struct {
	name:      string,
	direction: layout.Direction,
	ratio:     f32,
	focus:     bool,
}
Help :: struct {
	command: string,
}
// Region_Kind says what the rectangle's units are. Window and Pixels are client pixels; Cells are
// columns and rows of the focused pane.
Region_Kind :: enum {
	Window,
	Pixels,
	Cells,
}
Region :: struct {
	kind:                Region_Kind,
	x, y, width, height: int,
}
Capture :: struct {
	region: Region,
	output: string,
}
Pixels :: struct {
	region:                Region,
	rows, columns:         bool,
	sample:                Position,
	sampled:               bool,
}
Diff :: struct {
	baseline: string,
}
Draw_Kind :: enum {
	All,
	Rect,
	Glyph,
}
Draws :: struct {
	region: Region,
	kind:   Draw_Kind,
}
Perf :: struct {
	reset: bool,
}
Vt :: struct {
	recording: bool,
}
Request :: union {
	Ping,
	Screen,
	Cells,
	State,
	Wait,
	Expect,
	Type,
	Key,
	Run,
	Mouse,
	Focus,
	Resize,
	Dpi,
	Tray,
	Command,
	Window_Select,
	Window_Move,
	Help,
	Capture,
	Pixels,
	Diff,
	Draws,
	Perf,
	Vt,
}
Parse_Error :: struct {
	argument: string,
	advice:   string,
}

@(private, require_results)
number :: proc(s: string, low: int = 0, high: int = int(max(i32))) -> (int, bool) {
	if len(s) == 0 {return 0, false}
	for c in s {
		if c < '0' || c > '9' {return 0, false}
	}
	n, ok := strconv.parse_int(s)
	return n, ok && n >= low && n <= high
}

@(private, require_results)
pair :: proc(s: string, separator: u8, signed: bool = false) -> (Position, bool) {
	i := strings.index_byte(s, separator)
	if i < 0 {return {}, false}
	x, a := number(s[:i])
	y, b := number(s[i + 1:])
	if signed {
		x, a = signed_number(s[:i])
		y, b = signed_number(s[i + 1:])
	}
	return {x, y}, a && b
}

@(private, require_results)
signed_number :: proc(s: string) -> (int, bool) {
	digits := s
	if len(digits) > 0 && (digits[0] == '-' || digits[0] == '+') {digits = digits[1:]}
	_, valid := number(digits, 0, int(max(i32)) + 1)
	if !valid {return 0, false}
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
	if i <= 0 {return "", "", false}
	return s[:i], s[i + 1:], true
}

// Reads a comma-separated list of nonnegative integers into out. The count must be between
// minimum and len(out); a trailing comma or an empty part is invalid.
@(private, require_results)
integer_list :: proc(s: string, out: []int, minimum: int) -> (count: int, ok: bool) {
	rest := s
	for {
		if count == len(out) {return 0, false}
		separator := strings.index_byte(rest, ',')
		part := rest
		if separator >= 0 {part = rest[:separator]}
		value, valid := number(part)
		if !valid {return 0, false}
		out[count] = value
		count += 1
		if separator < 0 {break}
		rest = rest[separator + 1:]
	}
	return count, count >= minimum
}

@(private, require_results)
pixel_region :: proc(s: string) -> (Region, bool) {
	values: [4]int
	count, ok := integer_list(s, values[:], len(values))
	if !ok || count != len(values) || values[2] < 1 || values[3] < 1 {return {}, false}
	return {.Pixels, values[0], values[1], values[2], values[3]}, true
}

@(private, require_results)
cell_region :: proc(s: string) -> (Region, bool) {
	values: [4]int
	count, ok := integer_list(s, values[:], 2)
	if !ok || (count != 2 && count != 4) {return {}, false}
	width, height := 1, 1
	if count == 4 {
		width, height = values[2], values[3]
		if width < 1 || height < 1 {return {}, false}
	}
	return {.Cells, values[0], values[1], width, height}, true
}

@(require_results)
parse_capture :: proc(args: []string) -> (Request, Parse_Error) {
	bad := Parse_Error{args[0], "use capture [--cell c,r[,w,h] | --region x,y,w,h] [--out <file>]"}
	c := Capture {
		region = {kind = .Window},
	}
	seen_cell, seen_region, seen_out := false, false, false
	for i := 1; i < len(args); i += 2 {
		if i + 1 >= len(args) {return {}, {args[i], "supply a value after this option"}}
		value := args[i + 1]
		switch args[i] {
		case "--cell":
			if seen_cell || seen_region {return {}, {args[i], "use one region option"}}
			r, ok := cell_region(value)
			if !ok {return {}, {value, "use c,r[,w,h] with nonnegative cells and positive size"}}
			c.region, seen_cell = r, true
		case "--region":
			if seen_cell || seen_region {return {}, {args[i], "use one region option"}}
			r, ok := pixel_region(value)
			if !ok {return {}, {value, "use x,y,w,h with nonnegative origin and positive size"}}
			c.region, seen_region = r, true
		case "--out":
			if seen_out {return {}, {args[i], "use --out once"}}
			if value == "" || strings.contains(value, "\x00") {return {}, {value, "use a nonempty path"}}
			c.output, seen_out = value, true
		case:
			return {}, {args[i], bad.advice}
		}
	}
	return c, {}
}

@(require_results)
parse_pixels :: proc(args: []string) -> (Request, Parse_Error) {
	bad := Parse_Error{args[0], "use pixels [--cell | --region] [--rows | --columns] [--sample x,y]"}
	p := Pixels {
		region = {kind = .Window},
	}
	seen_cell, seen_region, seen_sample := false, false, false
	for i := 1; i < len(args); {
		switch args[i] {
		case "--rows":
			if p.rows || p.columns {return {}, {args[i], "use --rows or --columns once"}}
			p.rows = true
			i += 1
		case "--columns":
			if p.rows || p.columns {return {}, {args[i], "use --rows or --columns once"}}
			p.columns = true
			i += 1
		case "--cell", "--region", "--sample":
			if i + 1 >= len(args) {return {}, {args[i], "supply a value after this option"}}
			value := args[i + 1]
			switch args[i] {
			case "--cell":
				if seen_cell || seen_region {return {}, {args[i], "use one region option"}}
				r, ok := cell_region(value)
				if !ok {return {}, {value, "use c,r[,w,h] with nonnegative cells and positive size"}}
				p.region, seen_cell = r, true
			case "--region":
				if seen_cell || seen_region {return {}, {args[i], "use one region option"}}
				r, ok := pixel_region(value)
				if !ok {return {}, {value, "use x,y,w,h with nonnegative origin and positive size"}}
				p.region, seen_region = r, true
			case "--sample":
				if seen_sample {return {}, {args[i], "use --sample once"}}
				position, ok := pair(value, ',')
				if !ok {return {}, {value, "use nonnegative x,y pixels"}}
				p.sample, p.sampled, seen_sample = position, true, true
			}
			i += 2
		case:
			return {}, {args[i], bad.advice}
		}
	}
	if p.sampled && (p.rows || p.columns) {
		return {}, {args[0], "use --sample without --rows or --columns"}
	}
	return p, {}
}

@(require_results)
parse_draws :: proc(args: []string) -> (Request, Parse_Error) {
	bad := Parse_Error{args[0], "use draws [--region x,y,w,h] [--kind rect|glyph]"}
	d := Draws {
		region = {kind = .Window},
	}
	seen_region, seen_kind := false, false
	for i := 1; i < len(args); i += 2 {
		if i + 1 >= len(args) {return {}, {args[i], "supply a value after this option"}}
		value := args[i + 1]
		switch args[i] {
		case "--region":
			if seen_region {return {}, {args[i], "use --region once"}}
			r, ok := pixel_region(value)
			if !ok {return {}, {value, "use x,y,w,h with nonnegative origin and positive size"}}
			d.region, seen_region = r, true
		case "--kind":
			if seen_kind {return {}, {args[i], "use --kind once"}}
			switch value {
			case "rect":
				d.kind = .Rect
			case "glyph":
				d.kind = .Glyph
			case:
				return {}, {value, "choose rect or glyph"}
			}
			seen_kind = true
		case:
			return {}, {args[i], bad.advice}
		}
	}
	return d, {}
}

@(require_results)
parse_perf :: proc(args: []string) -> (Request, Parse_Error) {
	if len(args) == 1 {return Perf{}, {}}
	if len(args) == 2 && args[1] == "--reset" {return Perf{true}, {}}
	return {}, {args[0], "use perf [--reset]"}
}

@(require_results)
parse_vt :: proc(args: []string) -> (Request, Parse_Error) {
	if len(args) != 3 || args[1] != "record" {return {}, {args[0], "use vt record on|off"}}
	switch args[2] {
	case "on":
		return Vt{true}, {}
	case "off":
		return Vt{false}, {}
	}
	return {}, {args[2], "choose on or off"}
}

request_destroy :: proc(r: ^Request) {
	if k, ok := r^.(Key); ok {
		delete(k.chords)
	}
	r^ = {}
}

@(require_results)
parse :: proc(args: []string, allocator := context.allocator) -> (Request, Parse_Error) {
	if len(args) == 0 {return {}, {"<command>", "choose a command; use help"}}
	for arg in args {
		if !utf8.valid_string(arg) {return {}, {arg, "use valid UTF-8 text"}}
	}
	bad := Parse_Error{args[0], "use help for this command's grammar"}
	switch args[0] {
	case "ping", "state":
		if len(args) != 1 {return {}, {args[1], "remove the extra argument"}}
		if args[0] == "ping" {return Ping{}, {}}
		return State{}, {}
	case "help":
		if len(args) > 2 {return {}, {args[2], "use help [command]"}}
		return Help{len(args) == 2 ? args[1] : ""}, {}
	case "window":
		if len(args) != 3 {return {}, bad}
		switch args[1] {
		case "select":
			for c in args[2] {if c < '0' || c > '9' {return {}, bad}}
			id, ok := strconv.parse_uint(args[2])
			if !ok || id == 0 {return {}, {args[2], "use a nonzero window id from state"}}
			return Window_Select{u64(id)}, {}
		case "move":
			position, ok := pair(args[2], ',', true)
			if !ok {return {}, {args[2], "use signed 32-bit screen x,y"}}
			return Window_Move{position}, {}
		}
		return {}, bad
	case "screen":
		if len(args) == 1 {return Screen{}, {}}
		if len(args) != 2 {return {}, bad}
		r, ok := parse_range(args[1], true)
		if !ok {return {}, {args[1], "use a nonnegative row or first:last"}}
		return Screen{r}, {}
	case "cells":
		if len(args) < 2 || len(args) > 3 {return {}, bad}
		n, ok := number(args[1])
		if !ok {return {}, {args[1], "use a nonnegative row"}}
		r: Range
		if len(args) == 3 {
			r, ok = parse_range(args[2], false)
			if !ok {return {}, {args[2], "use first:last columns"}}
		}
		return Cells{n, r}, {}
	case "command":
		if len(args) < 2 || args[1] == "" {return {}, bad}
		r := Command {
			name      = args[1],
			direction = .Right,
			ratio     = 0.5,
			focus     = true,
		}
		if len(args) > 2 && r.name != "pane.split" {return {}, bad}
		seen: [3]bool
		for i := 2; i < len(args); i += 2 {
			if i + 1 >= len(args) {return {}, bad}
			index: int
			switch args[i] {
			case "--direction":
				index = 0
				switch args[i + 1] {
				case "left":
					r.direction = .Left
				case "right":
					r.direction = .Right
				case "up":
					r.direction = .Up
				case "down":
					r.direction = .Down
				case:
					return {}, bad
				}
			case "--ratio":
				index = 1
				n, ok := strconv.parse_f32(args[i + 1])
				if !ok || !(n >= 0.05 && n <= 0.95) {return {}, bad}
				r.ratio = n
			case "--focus":
				index = 2
				if args[i + 1] != "true" && args[i + 1] != "false" {return {}, bad}
				r.focus = args[i + 1] == "true"
			case:
				return {}, bad
			}
			if seen[index] {return {}, bad}
			seen[index] = true
		}
		return r, {}
	case "type", "focus", "tray", "resize", "dpi":
		if len(args) != 2 {return {}, bad}
		s := args[1]
		switch args[0] {
		case "type":
			return Type{s}, {}
		case "focus":
			if s == "in" || s == "out" {return Focus{s == "in"}, {}}
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
			if ok &&
			   p.x >= 1 &&
			   p.y >= 1 &&
			   p.x <= MAX_GRID_DIMENSION &&
			   p.y <= MAX_GRID_DIMENSION {
				return Resize{p.x, p.y}, {}
			}
		case "dpi":
			n, ok := number(s, 48, 768)
			if ok {return Dpi{n}, {}}
		}
		return {}, {s, "use help for valid values and ranges"}
	case "key":
		if len(args) < 2 {return {}, bad}
		k := Key {
			chords = make([dynamic]commands.Shortcut, allocator),
		}
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
		if len(args) < 2 {return {}, bad}
		w := Wait {
			idle_ms    = 300,
			timeout_ms = 5000,
		}
		start := 2
		if args[0] == "run" {
			w.text, w.timeout_ms = args[1], 10000
		} else {
			switch args[1] {
			case "text", "gone":
				if len(args) < 3 {return {}, bad}
				w.kind = args[1] == "text" ? .Text : .Gone
				w.text, start = args[2], 3
			case "frame":
				w.kind = .Frame
			case "idle":
				w.kind = .Idle
				if len(args) > 2 && !strings.has_prefix(args[2], "--") {
					n, ok := number(args[2])
					if !ok {return {}, {args[2], "use nonnegative milliseconds"}}
					w.idle_ms, start = n, 3
				}
			case:
				return {}, {args[1], "choose text, gone, idle, or frame"}
			}
		}
		seen_timeout, seen_idle := false, false
		for i := start; i < len(args); i += 2 {
			if i + 1 == len(args) {return {}, {args[i], "supply milliseconds after this option"}}
			n, ok := number(args[i + 1])
			if !ok {return {}, {args[i + 1], "use nonnegative milliseconds"}}
			switch args[i] {
			case "--timeout":
				if seen_timeout {return {}, {args[i], "use this option once"}}
				w.timeout_ms, seen_timeout = n, true
			case "--idle":
				if args[0] != "run" || seen_idle {return {}, {args[i], "use --idle once on run"}}
				w.idle_ms, seen_idle = n, true
			case:
				return {}, {args[i], "use --timeout, or --idle on run"}
			}
		}
		if args[0] == "run" {return Run{w.text, w.idle_ms, w.timeout_ms}, {}}
		return w, {}
	case "expect":
		if len(args) < 3 {return {}, bad}
		e: Expect
		switch args[1] {
		case "text", "no-text":
			if len(args) != 3 {return {}, bad}
			e.kind, e.text = args[1] == "text" ? .Text : .No_Text, args[2]
		case "cursor", "cell":
			p, ok := pair(args[2], ',')
			if !ok {return {}, {args[2], "use nonnegative col,row"}}
			e.kind, e.position = args[1] == "cell" ? .Cell : .Cursor, p
			if e.kind == .Cursor && len(args) != 3 || e.kind == .Cell && len(args) < 4 {
				return {}, bad
			}
			e.attributes = args[3:]
			for a in e.attributes {
				if !valid_attribute(
					a,
				) {return {}, {a, "use a cell attribute=value; see help expect"}}
			}
		case "state":
			if len(args) != 3 {return {}, bad}
			k, v, ok := assignment(args[2])
			if !ok {return {}, {args[2], "use key=value"}}
			e.kind, e.key, e.value = .State, k, v
		case:
			return {}, {args[1], "choose text, no-text, cursor, cell, or state"}
		}
		return e, {}
	case "mouse":
		return parse_mouse(args)
	case "capture":
		return parse_capture(args)
	case "pixels":
		return parse_pixels(args)
	case "diff":
		if len(args) != 2 {return {}, bad}
		if args[1] == "" {return {}, {args[1], "use a baseline capture path"}}
		return Diff{args[1]}, {}
	case "draws":
		return parse_draws(args)
	case "perf":
		return parse_perf(args)
	case "vt":
		return parse_vt(args)
	}
	return {}, {args[0], "unknown command; use help"}
}

@(private, require_results)
parse_mouse :: proc(args: []string) -> (Request, Parse_Error) {
	bad := Parse_Error{args[0], "use mouse move|down|up|click|drag|wheel col,row; see help mouse"}
	if len(args) < 3 {return {}, bad}
	m := Mouse {
		button = .Left,
	}
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
	if !ok {return {}, {args[2], "use col,row, pixel x,y with --px, or signed x,y with --screen"}}
	m.position = p
	i := 3
	if m.kind == .Drag || m.kind == .Wheel {
		if len(args) < 4 {return {}, bad}
		if m.kind == .Drag {
			m.end, ok = pair(args[3], ',', true)
		} else {
			m.lines, ok = strconv.parse_int(args[3])
			ok &&= m.lines >= int(min(i32)) && m.lines <= int(max(i32))
		}
		if !ok {return {}, {args[3], "use a position for drag, signed lines for wheel"}}
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
		if i + 1 >= len(args) {return {}, {option, "supply an option value; see help mouse"}}
		s := args[i + 1]
		switch option {
		case "--button":
			if seen_button {return {}, {option, "use --button once"}}
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
			if seen_mods {return {}, {option, "use --mods once"}}
			seen_mods = true
			// The shortcut parser owns modifier spelling and duplicate detection.
			buffer: [256]u8
			if len(s) + 2 > len(buffer) {return {}, {s, "use modifiers such as Ctrl+Shift"}}
			n := copy(buffer[:], s)
			copy(buffer[n:], "+A")
			chord, valid := commands.parse_shortcut(string(buffer[:n + 2]))
			if !valid {return {}, {s, "use modifiers such as Ctrl+Shift"}}
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
