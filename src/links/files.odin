package links

import "aio:localpath"
import "core:strings"

// The UTF-8 byte capacity of one link target's spelling and of the path it resolves to. Every buffer
// handed to resolve_file or holding a reading is this size, and a longer result is refused. Native
// UTF-16 path buffers in the opener are a separate, unrelated capacity.
TARGET_BYTES :: 4096

@(private, require_results)
hex_digit :: proc(c: u8) -> int {
	if c >= '0' && c <= '9' {return int(c - '0')}
	if c >= 'a' && c <= 'f' {return int(c - 'a') + 10}
	if c >= 'A' && c <= 'F' {return int(c - 'A') + 10}
	return -1
}

@(private, require_results)
local_authority :: proc(host: string, hosts: []string) -> bool {
	if host == "" || strings.equal_fold(host, "localhost") {return true}
	for name in hosts {
		if name != "" && strings.equal_fold(host, name) {return true}
	}
	return false
}

// URI decoding happens exactly once, before path validation. Remote authorities are refused
// before any filesystem access; hosts lists this machine's own names, which shells and ls
// write into OSC 7 and OSC 8. WSL shares are deliberately excluded with all other UNC paths.
@(private, require_results)
file_uri_path :: proc(uri: string, hosts: []string, buffer: []u8) -> (string, bool) {
	if len(uri) < 8 || !strings.equal_fold(uri[:7], "file://") {return "", false}
	rest := uri[7:]
	slash := strings.index_byte(rest, '/')
	if slash < 0 {return "", false}
	if !local_authority(rest[:slash], hosts) {return "", false}
	raw := rest[slash + 1:]
	at := 0
	for i := 0; i < len(raw); i += 1 {
		if at >= len(buffer) {return "", false}
		c := raw[i]
		if c == '#' || c == '?' {return "", false}
		if c == '%' {
			if i + 2 >= len(raw) {return "", false}
			hi, lo := hex_digit(raw[i + 1]), hex_digit(raw[i + 2])
			if hi < 0 || lo < 0 {return "", false}
			c = u8(hi * 16 + lo)
			i += 2
		}
		buffer[at] = c
		at += 1
	}
	path := string(buffer[:at])
	return path, localpath.local_absolute(path)
}

// Compiler locations: path:12, path:12:4, and the Odin and MSVC forms path(12), path(12,4)
// and path(12:4).
@(private, require_results)
strip_location :: proc(path: string) -> string {
	if strings.has_suffix(path, ")") {
		open := strings.last_index_byte(path, '(')
		if open > 0 {
			digits, separated := 0, false
			numbers := true
			for c in transmute([]u8)path[open + 1:len(path) - 1] {
				if c >= '0' && c <= '9' {digits += 1; continue}
				if (c == ',' || c == ':') && digits > 0 && !separated {
					separated, digits = true, 0
					continue
				}
				numbers = false
				break
			}
			if numbers && digits > 0 {return path[:open]}
		}
	}
	end := len(path)
	for _ in 0 ..< 2 {
		at := end
		for at > 0 && path[at - 1] >= '0' && path[at - 1] <= '9' {at -= 1}
		if at == end || at == 0 || path[at - 1] != ':' {break}
		end = at - 1
	}
	return path[:end]
}

// Resolve a printed target using only a shell-reported local cwd. The returned string borrows
// buffer; there is no filesystem access or allocation. File URIs name literal files, not locations.
@(require_results)
resolve_file :: proc(target, cwd: string, hosts: []string, buffer: []u8) -> (string, bool) {
	if len(target) >= 5 && strings.equal_fold(target[:5], "file:") {
		path, ok := file_uri_path(target, hosts, buffer)
		if !ok {return "", false}
		return path, true
	}
	path := strip_location(target)
	if localpath.local_absolute(path) {
		if len(path) > len(buffer) {return "", false}
		copy(buffer, transmute([]u8)path)
		return string(buffer[:len(path)]), true
	}
	if !localpath.valid_characters(path) || path[0] == '/' || path[0] == '\\' {return "", false}
	base := cwd
	if len(cwd) >= 5 && strings.equal_fold(cwd[:5], "file:") {
		decoded, ok := file_uri_path(cwd, hosts, buffer)
		if !ok {return "", false}
		base = decoded
	}
	if !localpath.local_absolute(base) || len(base) + 1 + len(path) > len(buffer) {return "", false}
	copy(buffer, transmute([]u8)base)
	buffer[len(base)] = '\\'
	copy(buffer[len(base) + 1:], transmute([]u8)path)
	return string(buffer[:len(base) + 1 + len(path)]), true
}

// Quoted paths may contain spaces, and a drive path extends across spaces when later words show it
// goes on. The original byte range retains compiler location suffixes and row breaks.
// Printed file URIs need an empty or localhost authority; machine names are honoured in OSC 8.
@(require_results)
find_files :: proc(text: string, relative: bool, out: ^[dynamic]Range) -> bool {
	at := 0
	buffer: [TARGET_BYTES]u8 = ---
	spaced: [TARGET_BYTES]u8 = ---
	for at < len(text) {
		for at < len(text) && (text[at] <= ' ' || text[at] == '(' || text[at] == '[') {at += 1}
		if at == len(text) {break}
		quote := u8(0)
		if text[at] == '"' || text[at] == '\'' || text[at] == '`' {
			quote = text[at]
			at += 1
		}
		start := at
		for at < len(text) {
			c := text[at]
			if quote != 0 && c == quote || quote == 0 &&
			   (c <= ' ' || c == '"' || c == '\'' || c == '`' || c == '<' || c == '>' || c == '|') {
				break
			}
			at += 1
		}
		end := quote != 0 ? at : trim_prose(text, start, at)
		if quote == 0 && end == at && end > start && localpath.local_absolute(strip_location(text[start:end])) {
			end = spaced_end(text, start, at)
			at = end
		}
		if end > start {
			candidate, spaced_ok := break_variant(text[start:end], break_variants(text[start:end]) - 1, spaced[:])
			if !spaced_ok {continue}
			shaped := strings.contains_any(candidate, ".\\/")
			absolute := localpath.local_absolute(strip_location(candidate)) ||
				len(candidate) >= 5 && strings.equal_fold(candidate[:5], "file:")
			cwd := relative ? "C:/" : ""
			if shaped && (absolute || relative_plausible(candidate)) {
				if _, ok := resolve_file(candidate, cwd, nil, buffer[:]); ok {
					if _, err := append(out, Range{start, end}); err != nil {return false}
				}
			}
		}
		// A quote that ends an unquoted token may open the next quoted token, so it is left in place.
		if at < len(text) && (quote != 0 || (text[at] != '"' && text[at] != '`')) {at += 1}
	}
	return true
}

// Relative names need a letter in their final segment. A bare name also needs an extension of two
// or more characters with a letter, so "e.g", "v1.2" and "1/2" stay prose. "and/or" still passes.
@(private, require_results)
relative_plausible :: proc(path: string) -> bool {
	name := strip_location(path)
	last := name
	if i := strings.last_index_any(name, "/\\"); i >= 0 {last = name[i + 1:]}
	if !has_letter(last) {return false}
	if strings.contains_any(name, "/\\") {return true}
	dot := strings.last_index_byte(name, '.')
	return dot >= 0 && len(name) - dot - 1 >= 2 && has_letter(name[dot + 1:])
}

@(private, require_results)
has_letter :: proc(text: string) -> bool {
	for i in 0 ..< len(text) {
		c := text[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') {return true}
	}
	return false
}
