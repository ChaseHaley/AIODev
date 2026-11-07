package settings

import "base:runtime"
import "core:strings"

@(private)
UTF8_BOM :: "\xef\xbb\xbf"

// One physical settings line split by the file grammar. `raw` is the exact line after the
// file BOM, including its line ending, so a rewriting caller can preserve unrelated bytes.
Line :: struct {
	number: int,
	raw:    string,
	text:   string,
	key:    string,
	value:  string,
	eol:    string,
	split:  bool,
}

// Physical line format: one optional leading UTF-8 BOM, '\n' line endings, and the EOL
// convention that a caller reuses when it inserts or replaces a line.
Line_Scanner :: struct {
	rest:   string,
	number: int,
	bom:    bool,
	eol:    string,
}

line_scanner_init :: proc(text: string) -> Line_Scanner {
	return {
		rest = strings.trim_prefix(text, UTF8_BOM),
		bom = strings.has_prefix(text, UTF8_BOM),
		eol = strings.contains(text, "\r\n") ? "\r\n" : "\n",
	}
}

// Returns the next physical line without allocating. `text` is trimmed and excludes the line
// ending; `key` and `value` are the trimmed sides of the first '='.
@(require_results)
line_next :: proc(scanner: ^Line_Scanner) -> (line: Line, ok: bool) {
	if len(scanner.rest) == 0 {return {}, false}
	scanner.number += 1
	line.number = scanner.number
	end := strings.index_byte(scanner.rest, '\n')
	if end < 0 {
		line.raw = scanner.rest
		scanner.rest = ""
	} else {
		line.raw = scanner.rest[:end + 1]
		scanner.rest = scanner.rest[end + 1:]
	}
	switch {
	case strings.has_suffix(line.raw, "\r\n"):
		line.eol = "\r\n"
	case strings.has_suffix(line.raw, "\n"):
		line.eol = "\n"
	}
	line.text = strings.trim_space(line.raw[:len(line.raw) - len(line.eol)])
	if equal := strings.index_byte(line.text, '='); equal >= 0 {
		line.key = strings.trim_space(line.text[:equal])
		line.value = strings.trim_space(line.text[equal + 1:])
		line.split = true
	}
	return line, true
}

// id_valid's grammar as a regular expression, for the exported theme schema.
ID_PATTERN :: "^[a-z0-9][a-z0-9_-]*$"

// The ID grammar profiles and themes share: lowercase ASCII letters, digits, - and _, not starting
// with - or _, and at most `max_length` bytes. Each domain declares its own limit.
id_valid :: proc(id: string, max_length: int) -> bool {
	if len(id) == 0 || len(id) > max_length {return false}
	if id[0] == '-' || id[0] == '_' {return false}
	for i in 0 ..< len(id) {
		if !id_byte_valid(id[i]) {return false}
	}
	return true
}

// Whether `c` may appear in an ID; the first byte also excludes - and _.
id_byte_valid :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
}

// Writes the on-disk form of a schema value. Strings are quoted; the other kinds pass their value
// text through.
@(require_results)
encode_value :: proc(
	b: ^strings.Builder,
	entry: Schema_Entry,
	value: string,
) -> runtime.Allocator_Error {
	switch entry.kind {
	case .String:
		return write_parts(b, "\"", value, "\"")
	case .Int, .Float, .Bool, .Enum, .Set:
		return write_parts(b, value)
	}
	return nil
}

@(private, require_results)
write_parts :: proc(b: ^strings.Builder, parts: ..string) -> runtime.Allocator_Error {
	for part in parts {
		if strings.write_string(b, part) != len(part) {return .Out_Of_Memory}
	}
	return nil
}
