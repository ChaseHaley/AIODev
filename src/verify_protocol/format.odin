package verify_protocol

import "aio:term"
import "core:fmt"
import "core:strings"

// Evidence formatting failures. A failure whose reply already explains itself is written with
// explain; verify reports any other as a generic failure line.
Error :: enum {
	None,
	Out_Of_Memory,
	Invalid_Argument,
	System,
}

State_Entry :: struct {
	key, value: string,
}

// A failed reply whose text starts with ERROR_PREFIX explains itself; verify forwards it verbatim.
// Expect and wait verdicts start with PASS_PREFIX or FAIL_PREFIX. A client prints either kind as
// the request's result; any other failed reply is a client failure.
ERROR_PREFIX :: "error: "
PASS_PREFIX :: "PASS "
FAIL_PREFIX :: "FAIL "

// Writes the client-facing explanation of a failed evidence request and returns err.
@(require_results)
explain :: proc(out: ^strings.Builder, text: string, err := Error.Invalid_Argument) -> Error {
	strings.write_string(out, ERROR_PREFIX)
	strings.write_string(out, text)
	return err
}

@(require_results)
reply_explained :: proc(text: string) -> bool {
	return strings.has_prefix(text, ERROR_PREFIX)
}

@(require_results)
reply_is_result :: proc(text: string) -> bool {
	return reply_explained(text) || strings.has_prefix(text, FAIL_PREFIX)
}

@(private)
Writer :: struct {
	out:   ^strings.Builder,
	error: Error,
}

@(private)
put :: proc(w: ^Writer, s: string) {
	if w.error != .None {return}
	if _, err := append(&w.out.buf, ..transmute([]u8)s); err != nil {
		w.error = .Out_Of_Memory
	}
}

@(private)
integer :: proc(w: ^Writer, n: int) {
	buffer: [32]u8
	put(w, fmt.bprintf(buffer[:], "%d", n))
}

@(private)
quoted :: proc(w: ^Writer, s: string) {
	put(w, "\"")
	escaped(w, s)
	put(w, "\"")
}

@(private)
escaped :: proc(w: ^Writer, s: string) {
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		switch {
		case c == '"':
			put(w, "\\\"")
		case c == '\\':
			put(w, "\\\\")
		case c < 32 || c == 127:
			buffer: [4]u8
			put(w, fmt.bprintf(buffer[:], "\\x%02x", c))
		case:
			put(w, s[i:i + 1])
		}
	}
}

@(private)
span :: proc(w: ^Writer, first, last: int) {
	integer(w, first)
	if first != last {
		put(w, "-")
		integer(w, last)
	}
}

@(private)
bounds :: proc(r: Range, size: int) -> (int, int, bool) {
	if !r.specified {return 0, size - 1, size > 0}
	return r.first, r.last, r.first >= 0 && r.last >= r.first && r.last < size
}

@(private)
cursor :: proc(w: ^Writer, s: ^term.Snapshot) {
	put(w, "cursor ")
	if !s.cursor.viewport_has_value {
		put(w, "off-screen")
		return
	}
	integer(w, int(s.cursor.viewport_x))
	put(w, ",")
	integer(w, int(s.cursor.viewport_y))
	if !s.cursor.visible {
		put(w, " hidden")
	}
	if s.cursor.blinking {
		put(w, " blinking")
	}
}

@(require_results)
format_screen :: proc(out: ^strings.Builder, s: ^term.Snapshot, rows := Range{}) -> Error {
	if s == nil {return .Invalid_Argument}
	first, last, ok := bounds(rows, int(s.rows))
	if !ok {return .Invalid_Argument}
	w := Writer {
		out = out,
	}
	put(&w, "screen ")
	integer(&w, int(s.columns))
	put(&w, "x")
	integer(&w, int(s.rows))
	put(&w, " ")
	cursor(&w, s)
	put(&w, "\n")
	width := 1
	for n := last; n >= 10; n /= 10 {
		width += 1
	}
	blank := -1
	for row in first ..= last {
		text, err := term.row_text(s, row, out.buf.allocator)
		if err != .None {return .Out_Of_Memory}
		if text == "" {
			if blank < 0 {
				blank = row
			}
		} else {
			if blank >= 0 {
				span(&w, blank, row - 1)
				put(&w, " blank\n")
				blank = -1
			}
			buffer: [32]u8
			label := fmt.bprintf(buffer[:], "%d", row)
			for _ in len(label) ..< width {
				put(&w, " ")
			}
			put(&w, label)
			put(&w, "|")
			put(&w, text)
			put(&w, "\n")
		}
		delete(text, out.buf.allocator)
	}
	if blank >= 0 {
		span(&w, blank, last)
		put(&w, " blank\n")
	}
	return w.error
}

@(private)
attributes :: proc(s: ^term.Snapshot, c: ^term.Snapshot_Cell) -> Attributes {
	a := Attributes {
		fg        = c.foreground,
		bg        = c.background,
		underline = c.style.underline,
	}
	v := c.style
	if v.bold {
		a.flags += {.Bold}
	}
	if v.italic {
		a.flags += {.Italic}
	}
	if v.faint {
		a.flags += {.Faint}
	}
	if v.blink {
		a.flags += {.Blink}
	}
	if v.inverse {
		a.flags += {.Inverse}
	}
	if v.invisible {
		a.flags += {.Invisible}
	}
	if v.strikethrough {
		a.flags += {.Strike}
	}
	if v.overline {
		a.flags += {.Overline}
	}
	if c.selected {
		a.flags += {.Selected}
	}
	if c.width == .Wide || c.width == .Spacer_Tail {
		a.flags += {.Wide}
	}
	switch v.underline_color.tag {
	case .None:
	case .Palette:
		a.underline_color = s.palette[v.underline_color.value.palette]
	case .Rgb:
		a.underline_color = term.color_from_ghostty(v.underline_color.value.rgb)
	}
	return a
}

@(private)
attributes_at :: proc(s: ^term.Snapshot, column, row: int) -> Attributes {
	c := term.snapshot_cell(s, column, row)
	// libghostty can mark only the leading half selected; a wide glyph is one output run.
	if c.width == .Spacer_Tail && column > 0 {
		previous := term.snapshot_cell(s, column - 1, row)
		if previous.width == .Wide {
			c = previous
		}
	}
	return attributes(s, c)
}

@(private)
attribute_text :: proc(w: ^Writer, a: Attributes) {
	buffer: [16]u8
	for entry in ATTRIBUTE_CATALOGUE {
		if entry.kind == .Text {continue}
		value, set := attribute_value(entry, a, buffer[:])
		if !set {continue}
		put(w, " ")
		put(w, entry.name)
		if entry.kind != .Flag {
			put(w, "=")
			put(w, value)
		}
	}
}

@(require_results)
format_cells :: proc(out: ^strings.Builder, s: ^term.Snapshot, request: Cells) -> Error {
	if s == nil {return .Invalid_Argument}
	first, last, ok := bounds(request.columns, int(s.columns))
	if !ok || request.row < 0 || request.row >= int(s.rows) {return .Invalid_Argument}
	w := Writer {
		out = out,
	}
	put(&w, "row ")
	integer(&w, request.row)
	put(&w, " cols ")
	integer(&w, first)
	put(&w, "-")
	integer(&w, last)
	put(&w, "\n")
	m, map_error := term.row_map(s, request.row, out.buf.allocator)
	if map_error != .None {return .Out_Of_Memory}
	defer term.row_map_destroy(&m, out.buf.allocator)
	text_last := last
	for text_last >= first {
		if (m.columns[text_last] != "" && m.columns[text_last] != " ") ||
		   attributes_at(s, text_last, request.row) != (Attributes{}) {
			break
		}
		text_last -= 1
	}
	for start := first; start <= last; {
		if start > text_last {
			span(&w, start, last)
			put(&w, " blank\n")
			break
		}
		a := attributes_at(s, start, request.row)
		end := start
		for end < text_last && attributes_at(s, end + 1, request.row) == a {
			end += 1
		}
		span(&w, start, end)
		put(&w, " \"")
		for column in start ..= end {escaped(&w, m.columns[column])}
		put(&w, "\"")
		attribute_text(&w, a)
		put(&w, "\n")
		start = end + 1
	}
	return w.error
}

// Writes a value bare, or quoted when it is empty or has a space, quote or control byte. Inside
// quotes a quote is \" and a control byte \xNN; backslashes stay literal, so Windows paths read
// unchanged. value_parse is the decoder.
@(private)
value_text :: proc(w: ^Writer, value: string) {
	quote := value == ""
	for c in transmute([]u8)value {
		quote ||= c == ' ' || c == '"' || c < 32 || c == 127
	}
	if !quote {
		put(w, value)
		return
	}
	put(w, "\"")
	for i in 0 ..< len(value) {
		c := value[i]
		if c == '"' {
			put(w, "\\\"")
		} else if c < 32 || c == 127 {
			buffer: [4]u8
			put(w, fmt.bprintf(buffer[:], "\\x%02x", c))
		} else {
			put(w, value[i:i + 1])
		}
	}
	put(w, "\"")
}

@(require_results)
format_value :: proc(out: ^strings.Builder, value: string) -> Error {
	w := Writer {
		out = out,
	}
	value_text(&w, value)
	return w.error
}

@(require_results)
format_state :: proc(out: ^strings.Builder, entries: []State_Entry) -> Error {
	w := Writer {
		out = out,
	}
	for entry in entries {
		put(&w, entry.key)
		put(&w, "=")
		value_text(&w, entry.value)
		put(&w, "\n")
	}
	return w.error
}

// Decodes the value at the start of text as value_text wrote it, returning the rest after it. A
// quoted value reads \" as a quote, \xNN as a byte and any other backslash as itself. Because
// backslashes are not escaped, a value that itself contains \", \xNN or a trailing backslash is
// ambiguous; no state or ping value the app writes contains them except by accident of a path.
@(require_results)
value_parse :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	value, rest: string,
	ok: bool,
) {
	if text == "" || text[0] != '"' {
		end := strings.index_any(text, " \n")
		if end < 0 {end = len(text)}
		bare, err := strings.clone(text[:end], allocator)
		return bare, text[end:], err == nil
	}
	b, allocation_error := strings.builder_make(allocator)
	if allocation_error != nil {return "", "", false}
	for i := 1; i < len(text); {
		c := text[i]
		if c == '"' {return strings.to_string(b), text[i + 1:], true}
		decoded, width := c, 1
		if c == '\\' && i + 1 < len(text) && text[i + 1] == '"' {
			decoded, width = '"', 2
		} else if c == '\\' && i + 3 < len(text) && text[i + 1] == 'x' {
			high, high_ok := hex_digit(text[i + 2])
			low, low_ok := hex_digit(text[i + 3])
			if high_ok && low_ok {decoded, width = high << 4 | low, 4}
		}
		if strings.write_byte(&b, decoded) != 1 {break}
		i += width
	}
	strings.builder_destroy(&b)
	return "", "", false
}

@(private, require_results)
hex_digit :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}

// The value of key in a reply of key=value fields separated by spaces (ping) or lines (state), as
// format_ping and format_state write them. The value is allocated; false when the key is absent or
// the reply is malformed.
@(require_results)
reply_field :: proc(text, key: string, allocator := context.allocator) -> (string, bool) {
	remaining := text
	for remaining != "" {
		i := strings.index_byte(remaining, '=')
		if i < 1 {return "", false}
		name := remaining[:i]
		value, rest, ok := value_parse(remaining[i + 1:], allocator)
		if !ok {return "", false}
		if rest != "" && rest[0] != ' ' && rest[0] != '\n' {
			delete(value, allocator)
			return "", false
		}
		if name == key {return value, true}
		delete(value, allocator)
		remaining = strings.trim_left_space(rest)
	}
	return "", false
}

// The fields of the ping reply, in order.
Ping_Field :: enum {
	Pid,
	App,
	Build,
	Data,
	Settings,
	Log,
}

PING_FIELDS :: [Ping_Field]string {
	.Pid      = "pid",
	.App      = "app",
	.Build    = "build",
	.Data     = "data",
	.Settings = "settings",
	.Log      = "log",
}

// Writes the one-line ping reply: space-separated field=value pairs; reply_field reads them.
@(require_results)
format_ping :: proc(out: ^strings.Builder, values: [Ping_Field]string) -> Error {
	w := Writer {
		out = out,
	}
	for field in Ping_Field {
		if field != .Pid {put(&w, " ")}
		put(&w, PING_FIELDS[field])
		put(&w, "=")
		value_text(&w, values[field])
	}
	return w.error
}

@(require_results)
evaluate :: proc(
	out: ^strings.Builder,
	request: Expect,
	s: ^term.Snapshot,
	entries: []State_Entry = nil,
) -> (
	passed: bool,
	error: Error,
) {
	w := Writer {
		out = out,
	}
	if request.kind == .State {
		value := "<missing>"
		found := false
		for entry in entries {
			if entry.key == request.key {
				value, found = entry.value, true
				break
			}
		}
		passed = found && value == request.value
		put(&w, passed ? PASS_PREFIX : FAIL_PREFIX)
		put(&w, "state ")
		put(&w, request.key)
		if passed {
			put(&w, "=")
			value_text(&w, value)
		} else {
			put(&w, ": expected ")
			quoted(&w, request.value)
			put(&w, ", observed ")
			quoted(&w, value)
		}
		put(&w, "\n")
		return passed, w.error
	}
	if s == nil {return false, .Invalid_Argument}
	switch request.kind {
	case .State:
	case .Text, .No_Text:
		found := false
		position: Position
		recent: [2]int
		recent_count := 0
		for row in 0 ..< int(s.rows) {
			m, map_error := term.row_map(s, row, out.buf.allocator)
			if map_error != .None {return false, .Out_Of_Memory}
			if m.text != "" {
				if recent_count == len(recent) {
					recent[0], recent[1] = recent[1], row
				} else {
					recent[recent_count] = row
					recent_count += 1
				}
			}
			index := strings.index(m.text, request.text)
			if index >= 0 {
				// A match may begin inside a cell's text; it is reported at the cell's first column.
				at := 0
				for text, column in m.columns {
					if text == "" {continue}
					if index < at + len(text) {
						position = {column, row}
						break
					}
					at += len(text)
				}
				found = true
			}
			term.row_map_destroy(&m, out.buf.allocator)
			if found {
				break
			}
		}
		passed = request.kind == .Text ? found : !found
		put(&w, passed ? PASS_PREFIX : FAIL_PREFIX)
		put(&w, request.kind == .No_Text ? "no-text " : "text ")
		quoted(&w, request.text)
		if found {
			put(&w, passed ? " at " : " found at ")
			integer(&w, position.x)
			put(&w, ",")
			integer(&w, position.y)
		} else if !passed {
			put(&w, " not on screen; last rows:")
			for row in recent[:recent_count] {
				text, err := term.row_text(s, row, out.buf.allocator)
				if err != .None {return false, .Out_Of_Memory}
				if text != "" {
					put(&w, " ")
					integer(&w, row)
					put(&w, "|")
					put(&w, text)
				}
				delete(text, out.buf.allocator)
			}
			if recent_count == 0 {
				put(&w, " ")
				span(&w, 0, int(s.rows) - 1)
				put(&w, " blank")
			}
		}
	case .Cursor:
		p := request.position
		passed =
			s.cursor.viewport_has_value &&
			int(s.cursor.viewport_x) == p.x &&
			int(s.cursor.viewport_y) == p.y
		put(&w, passed ? PASS_PREFIX : FAIL_PREFIX)
		put(&w, "cursor ")
		integer(&w, p.x)
		put(&w, ",")
		integer(&w, p.y)
		if !passed {
			put(&w, ": observed ")
			cursor(&w, s)
		}
	case .Cell:
		p := request.position
		c := term.snapshot_cell(s, p.x, p.y)
		passed = c != nil
		failed_key, expected, observed := "", "", ""
		buffer: [32]u8
		a: Attributes
		if c != nil {
			a = attributes_at(s, p.x, p.y)
			for item in request.attributes {
				key, value, valid := assignment(item)
				if !valid || !valid_attribute(item) {return false, .Invalid_Argument}
				actual, kind, found := observed_attribute(c, a, key, buffer[:])
				if !found {return false, .Invalid_Argument}
				matches := kind == .Color ? strings.equal_fold(actual, value) : actual == value
				if !matches {
					passed = false
					failed_key, expected, observed = key, value, actual
					break
				}
			}
		}
		put(&w, passed ? PASS_PREFIX : FAIL_PREFIX)
		put(&w, "cell ")
		integer(&w, p.x)
		put(&w, ",")
		integer(&w, p.y)
		if c == nil {
			put(&w, " off-screen")
		} else {
			if !passed {
				put(&w, " ")
				put(&w, failed_key)
				put(&w, ": expected ")
				value_text(&w, expected)
				put(&w, ", observed ")
				value_text(&w, observed)
				put(&w, "; cell")
				if a.fg == nil {
					a.fg = s.foreground
				}
			}
			put(&w, " ")
			quoted(&w, c.text)
			attribute_text(&w, a)
		}
	}
	put(&w, "\n")
	return passed, w.error
}
