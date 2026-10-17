// Unicode fixtures shared by the term, term_view, and live tests. See unicode.txt for the format.
package fixtures_test

import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

UNICODE_FIXTURES :: #load("unicode.txt", string)

Unicode_Case :: struct {
	id: string,
	// Cell span of each grapheme cluster, left to right.
	widths: []int,
	// Bytes written to the terminal.
	input: []u8,
	// Codepoints the grid stores, in order; differs from the input only for invalid UTF-8.
	stored: []rune,
	line: int,
}

// Parses the fixture table. Any malformed line is an error, so a typo cannot silently drop a case.
@(require_results)
unicode_cases :: proc(text := UNICODE_FIXTURES, allocator := context.allocator) -> (cases: []Unicode_Case, error: string) {
	context.allocator = allocator
	out: [dynamic]Unicode_Case
	seen: map[string]bool
	defer delete(seen)
	rest := text
	line := 0
	for raw in strings.split_lines_iterator(&rest) {
		line += 1
		c, ok, err := parse_line(raw, line)
		if err == "" && ok && seen[c.id] {
			err = "duplicate id"
			unicode_case_destroy(c)
		}
		if err != "" {
			unicode_cases_destroy(out[:])
			return nil, failure(line, err)
		}
		if !ok { continue }
		seen[c.id] = true
		append(&out, c)
	}
	if len(out) == 0 {
		delete(out)
		return nil, "no fixtures"
	}
	return out[:], ""
}

// Returns ok false for blank and comment lines.
@(private, require_results)
parse_line :: proc(raw: string, line: int) -> (c: Unicode_Case, ok: bool, error: string) {
	defer if error != "" { unicode_case_destroy(c) }
	for b in transmute([]u8)raw {
		if b >= 0x80 || (b < 0x20 && b != '\t' && b != '\r') {
			return {}, false, "fixture lines must be printable ASCII; escape everything else"
		}
	}
	content := strings.trim_space(raw)
	if hash := strings.index(content, "#"); hash >= 0 {
		content = strings.trim_space(content[:hash])
	}
	if content == "" { return {}, false, "" }
	fields := strings.fields(content, context.temp_allocator)
	if len(fields) != 3 && len(fields) != 4 {
		return {}, false, "expected: id widths input [stored]"
	}
	c = Unicode_Case{id = fields[0], line = line}
	widths: [dynamic]int
	for part in strings.split(fields[1], ",", context.temp_allocator) {
		w, w_ok := strconv.parse_int(part, 10)
		if !w_ok || w < 1 || w > 2 {
			delete(widths)
			return c, false, "each width must be 1 or 2"
		}
		append(&widths, w)
	}
	c.widths = widths[:]
	c.input, error = unescape(fields[2])
	if error != "" { return }
	stored: []u8
	stored, error = unescape(fields[2] if len(fields) == 3 else fields[3])
	defer delete(stored)
	if error != "" { return }
	if !utf8.valid_string(string(stored)) {
		return c, false, "invalid UTF-8 input needs a stored column"
	}
	c.stored = utf8.string_to_runes(string(stored))
	return c, true, ""
}

unicode_cases_destroy :: proc(cases: []Unicode_Case, allocator := context.allocator) {
	context.allocator = allocator
	for c in cases { unicode_case_destroy(c) }
	delete(cases)
}

@(private)
unicode_case_destroy :: proc(c: Unicode_Case) {
	delete(c.widths)
	delete(c.input)
	delete(c.stored)
}

// Columns the cursor advances when the case is written at column 0.
columns :: proc(c: Unicode_Case) -> int {
	total := 0
	for w in c.widths { total += w }
	return total
}

// Decodes `<hex>` as a codepoint encoded in UTF-8 and `<xHH>` as one raw byte. Other characters are literal.
@(private, require_results)
unescape :: proc(text: string) -> ([]u8, string) {
	out: [dynamic]u8
	for i := 0; i < len(text); {
		if text[i] != '<' {
			append(&out, text[i])
			i += 1
			continue
		}
		end := strings.index_byte(text[i:], '>')
		if end < 2 {
			delete(out)
			return nil, "unterminated or empty <escape>"
		}
		body := text[i + 1:i + end]
		i += end + 1
		if body[0] == 'x' {
			value, ok := strconv.parse_uint(body[1:], 16)
			if !ok || len(body) != 3 {
				delete(out)
				return nil, "a byte escape is <xHH>"
			}
			append(&out, u8(value))
			continue
		}
		value, ok := strconv.parse_uint(body, 16)
		if !ok || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff) {
			delete(out)
			return nil, "a codepoint escape is <hex> for a Unicode scalar value"
		}
		bytes, n := utf8.encode_rune(rune(value))
		append(&out, ..bytes[:n])
	}
	return out[:], ""
}

@(private)
failure :: proc(line: int, message: string) -> string {
	return strings.concatenate({"unicode.txt:", line_number(line), ": ", message}, context.temp_allocator)
}

@(private)
line_number :: proc(line: int) -> string {
	buf := make([]u8, 16, context.temp_allocator)
	return strconv.write_int(buf, i64(line), 10)
}

@(test)
fixture_table_parses :: proc(t: ^testing.T) {
	cases, err := unicode_cases()
	defer unicode_cases_destroy(cases)
	testing.expect_value(t, err, "")
	testing.expect(t, len(cases) >= 40, "the fixture table lost cases")
}

@(test)
fixture_escapes :: proc(t: ^testing.T) {
	cases, err := unicode_cases("a 1,2 e<301><x41> e<301>A\nb 2 <1F600>\n")
	defer unicode_cases_destroy(cases)
	if !testing.expect_value(t, err, "") { return }
	testing.expect_value(t, string(cases[0].input), "e\xcc\x81A")
	testing.expect_value(t, len(cases[0].stored), 3)
	testing.expect_value(t, columns(cases[0]), 3)
	testing.expect_value(t, cases[1].stored[0], rune(0x1f600))
}

@(test)
fixture_errors :: proc(t: ^testing.T) {
	bad := []string{
		"a 3 x", "a 1 <D800>", "a 1 <xFF>", "a 1 <12", "a 1", "a 1 x\na 1 y", "a 1 é",
	}
	for text in bad {
		cases, err := unicode_cases(text)
		unicode_cases_destroy(cases)
		testing.expectf(t, err != "", "accepted %q", text)
	}
}
