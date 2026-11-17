package agent

import "base:runtime"
import "core:bytes"
import "core:strings"
import "core:unicode/utf8"

// <config>/projects/<slug>/<session>.jsonl; slug = cwd with every character other than an ASCII letter
// or digit replaced by '-' (C:\Users\chale\Projects\AIODev → C--Users-chale-Projects-AIODev).
claude_transcript_path :: proc(
	config_directory, cwd, session: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	config := strings.trim_right(config_directory, "/\\")
	strings.write_string(&b, config)
	strings.write_string(&b, "/projects/")
	for r in cwd {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
			strings.write_rune(&b, r)
		case:
			// Claude names the folder per UTF-16 unit, so a supplementary character counts twice.
			strings.write_byte(&b, '-')
			if r > 0xFFFF {strings.write_byte(&b, '-')}
		}
	}
	strings.write_byte(&b, '/')
	strings.write_string(&b, session)
	strings.write_string(&b, ".jsonl")
	return strings.to_string(b)
}

@(private = "file")
PLACE_KEYS :: [?]string{`"cwd"`, `"file_path"`, `"notebook_path"`}

// Tools that change the file they name (see turn_hooks.odin); Read and the like only look.
@(private = "file")
EDIT_TOOLS :: [?]string{`"name":"Edit",`, `"name":"MultiEdit",`, `"name":"Write",`, `"name":"NotebookEdit",`}

// Whether the "file_path" at `at` is a member of the input of an editing tool_use, which Claude writes as
// ..."name":"Edit","input":{...}.
@(private = "file")
edit_input_at :: proc(line: string, at: int) -> bool {
	input := strings.last_index(line[:at], `"input":{`)
	if input < 0 {return false}
	head := line[:input]
	for tool in EDIT_TOOLS {
		if strings.has_suffix(head, tool) {return true}
	}
	return false
}

// The folders and files a chunk of transcript lines names: every "cwd" value and every tool input
// "file_path" / "notebook_path" value, JSON-unescaped, with '/' separators. Lines cut at either end of the
// chunk and malformed lines are skipped. Pure; never reads files.
claude_transcript_places :: proc(chunk: []u8, out: ^[dynamic]string, allocator := context.allocator) {
	// A transcript repeats the same cwd on nearly every line: report each place once per chunk.
	seen := make(map[string]struct{}, allocator)
	defer delete(seen)
	scratch := make([dynamic]u8, 0, 256, allocator)
	defer delete(scratch)

	rest := chunk
	for len(rest) > 0 {
		line := rest
		if end := bytes.index_byte(rest, '\n'); end >= 0 {
			line = rest[:end]
			rest = rest[end + 1:]
		} else {
			rest = nil
		}
		for len(line) > 0 && (line[len(line) - 1] == '\r' || line[len(line) - 1] == ' ') {
			line = line[:len(line) - 1]
		}
		for len(line) > 0 && line[0] == ' ' {line = line[1:]}
		// A line cut at either end of the chunk lacks its opening or closing brace.
		if len(line) < 2 || line[0] != '{' || line[len(line) - 1] != '}' {continue}
		text := string(line)
		for key in PLACE_KEYS {
			places_scan_key(text, key, &scratch, &seen, out, allocator)
		}
	}
}

@(private = "file")
places_scan_key :: proc(
	line, key: string,
	scratch: ^[dynamic]u8,
	seen: ^map[string]struct{},
	out: ^[dynamic]string,
	allocator: runtime.Allocator,
) {
	from := 0
	for from < len(line) {
		hit := strings.index(line[from:], key)
		if hit < 0 {return}
		at := from + hit
		from = at + len(key)
		// Inside a string value the quotes are escaped: an odd run of backslashes before the quote.
		slashes := 0
		for at - slashes > 0 && line[at - slashes - 1] == '\\' {slashes += 1}
		if slashes % 2 == 1 {continue}
		if key != `"cwd"` && !edit_input_at(line, at) {continue}

		i := skip_blank(line, from)
		if i >= len(line) || line[i] != ':' {continue}
		i = skip_blank(line, i + 1)
		if i >= len(line) || line[i] != '"' {continue}
		i += 1
		end := i
		for end < len(line) && line[end] != '"' {
			end += 2 if line[end] == '\\' else 1
		}
		if end >= len(line) {return}
		from = end + 1

		clear(scratch)
		if !json_unescape(line[i:end], scratch) {continue}
		place_normalise(scratch[:])
		if len(scratch) == 0 {continue}
		value := string(scratch[:])
		if value in seen^ {continue}
		owned := strings.clone(value, allocator)
		seen[owned] = {}
		append(out, owned)
	}
}

@(private = "file")
skip_blank :: proc(s: string, i: int) -> int {
	i := i
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {i += 1}
	return i
}

// Appends the UTF-8 value of a JSON string body. false for an invalid escape.
@(private = "file")
json_unescape :: proc(body: string, out: ^[dynamic]u8) -> bool {
	i := 0
	for i < len(body) {
		c := body[i]
		if c != '\\' {
			start := i
			for i < len(body) && body[i] != '\\' {i += 1}
			append(out, body[start:i])
			continue
		}
		if i + 1 >= len(body) {return false}
		e := body[i + 1]
		i += 2
		switch e {
		case '"', '\\', '/': append(out, e)
		case 'b': append(out, '\b')
		case 'f': append(out, '\f')
		case 'n': append(out, '\n')
		case 'r': append(out, '\r')
		case 't': append(out, '\t')
		case 'u':
			r, used, ok := unicode_escape(body[i:])
			if !ok {return false}
			i += used
			encoded, width := utf8.encode_rune(r)
			append(out, ..encoded[:width])
		case:
			return false
		}
	}
	return true
}

// Decodes XXXX (and a following \uXXXX low surrogate when the first is a high one).
@(private = "file")
unicode_escape :: proc(s: string) -> (r: rune, used: int, ok: bool) {
	hex4 :: proc(s: string) -> (v: u32, ok: bool) {
		if len(s) < 4 {return 0, false}
		for k in 0 ..< 4 {
			d: u32
			switch s[k] {
			case '0' ..= '9': d = u32(s[k] - '0')
			case 'a' ..= 'f': d = u32(s[k] - 'a') + 10
			case 'A' ..= 'F': d = u32(s[k] - 'A') + 10
			case: return 0, false
			}
			v = v * 16 + d
		}
		return v, true
	}
	hi := hex4(s) or_return
	if hi >= 0xD800 && hi < 0xDC00 {
		if len(s) >= 10 && s[4] == '\\' && s[5] == 'u' {
			lo, lo_ok := hex4(s[6:])
			if lo_ok && lo >= 0xDC00 && lo < 0xE000 {
				return rune(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)), 10, true
			}
		}
		return utf8.RUNE_ERROR, 4, true
	}
	if hi >= 0xDC00 && hi < 0xE000 {return utf8.RUNE_ERROR, 4, true}
	return rune(hi), 4, true
}

// '\' → '/', and the MSYS form /c/Users → C:/Users.
@(private = "file")
place_normalise :: proc(path: []u8) {
	for &c in path {
		if c == '\\' {c = '/'}
	}
	if len(path) >= 2 && path[0] == '/' && (len(path) == 2 || path[2] == '/') {
		switch path[1] {
		case 'a' ..= 'z': path[0] = path[1] - 32
		case 'A' ..= 'Z': path[0] = path[1]
		case: return
		}
				path[1] = ':'
	}
}
