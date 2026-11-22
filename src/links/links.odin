package links

import "aio:localpath"
import "core:mem"
import "core:strings"
import "cosmos:weburl"
import "cosmos:winpath"

// Range is a byte span in the text the caller scanned. End is exclusive.
Range :: struct {
	start, end: int,
}

// Find appends terminal URLs in one line of text, with prose punctuation removed.
// It does not join lines: the caller decides which physical rows are one logical line.
@(require_results)
find :: proc(text: string, out: ^[dynamic]Range) -> bool {
	at := 0
	for at < len(text) {
		if !terminal_scheme_starts(text, at) || (at > 0 && word_byte(text[at - 1])) {
			at += 1
			continue
		}
		start := at
		end := start
		for end < len(text) {
			c := text[end]
			if c <= ' ' || c == 0x7f || c == '"' || c == '<' || c == '>' || c == '\\' ||
			   c == '`' || c == '|' {
				break
			}
			if (c == ',' || c == ';') && terminal_scheme_starts(text, end + 1) {
				break
			}
			end += 1
		}
		trimmed := trim_prose(text, start, end)
		if trimmed > start && terminal_uri(text[start:trimmed]) {
			if _, err := append(out, Range{start, trimmed}); err != nil {
				return false
			}
		}
		at = end > start ? end : start + 1
	}
	return true
}

@(private, require_results)
terminal_scheme_starts :: proc(text: string, at: int) -> bool {
	if at >= len(text) {return false}
	switch text[at] {
	case 'h', 'H':
		return scheme_starts(text, at, "https") || scheme_starts(text, at, "http")
	case 'o', 'O':
		return scheme_starts(text, at, "obsidian")
	}
	return false
}

// The terminal also detects local Obsidian note links. They are not web targets.
@(require_results)
terminal_uri :: proc(uri: string) -> bool {
	return obsidian_open(uri) || weburl.allowed(uri)
}

@(private, require_results)
scheme_starts :: proc(text: string, at: int, scheme: string) -> bool {
	if at + len(scheme) + 3 > len(text) {
		return false
	}
	for i in 0 ..< len(scheme) {
		c := text[at + i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != scheme[i] {
			return false
		}
	}
	return text[at + len(scheme)] == ':' &&
		text[at + len(scheme) + 1] == '/' &&
		text[at + len(scheme) + 2] == '/'
}

@(private, require_results)
word_byte :: proc(c: u8) -> bool {
	return(
		c >= 'a' && c <= 'z' ||
		c >= 'A' && c <= 'Z' ||
		c >= '0' && c <= '9' ||
		c == '_' \
	)
}

// trim_prose drops punctuation that belongs to the sentence rather than the target. A closing
// bracket survives when the URL opens it, so paths such as Foo_(bar) stay intact.
@(private, require_results)
trim_prose :: proc(text: string, start, end: int) -> int {
	round_open, round_close := 0, 0
	square_open, square_close := 0, 0
	brace_open, brace_close := 0, 0
	for i in start ..< end {
		switch text[i] {
		case '(':
			round_open += 1
		case ')':
			round_close += 1
		case '[':
			square_open += 1
		case ']':
			square_close += 1
		case '{':
			brace_open += 1
		case '}':
			brace_close += 1
		}
	}
	trim := end
	for trim > start {
		switch text[trim - 1] {
		case '.', ',', ';', ':', '!', '?', '\'', '"', '`':
			trim -= 1
		case ')':
			if round_close <= round_open {
				return trim
			}
			round_close -= 1
			trim -= 1
		case ']':
			if square_close <= square_open {
				return trim
			}
			square_close -= 1
			trim -= 1
		case '}':
			if brace_close <= brace_open {
				return trim
			}
			brace_close -= 1
			trim -= 1
		case:
			switch {
			case strings.has_suffix(text[start:trim], "\u2026"),
			     strings.has_suffix(text[start:trim], "\u3002"),
			     strings.has_suffix(text[start:trim], "\u3001"),
			     strings.has_suffix(text[start:trim], "\u300d"),
			     strings.has_suffix(text[start:trim], "\u300f"),
			     strings.has_suffix(text[start:trim], "\uff09"),
			     strings.has_suffix(text[start:trim], "\uff0c"),
			     strings.has_suffix(text[start:trim], "\u2014"),
			     strings.has_suffix(text[start:trim], "\u2013"):
				trim -= 3
			case strings.has_suffix(text[start:trim], "\u2019"),
			     strings.has_suffix(text[start:trim], "\u201d"):
				trim -= 3
			case strings.has_suffix(text[start:trim], "\u00bb"),
			     strings.has_suffix(text[start:trim], "\u00a0"):
				trim -= 2
			case:
				return trim
			}
		}
	}
	return trim
}

// Normalize_web_input accepts HTTP(S), local file URLs and absolute Windows drive paths for web panes,
// including shorthand that expands to one, such as "~\page.html" or "%TEMP%\page.html". A bare host
// gets HTTPS (HTTP for localhost, 127.0.0.1 and [::1]). The result uses `allocator`.
@(require_results)
normalize_web_input :: proc(raw: string, allocator := context.temp_allocator) -> (string, bool) {
	trimmed := strings.trim_space(raw)
	if trimmed == "" {return "", false}
	path := trimmed
	if len(path) >= 2 && path[0] == '"' && path[len(path) - 1] == '"' {
		path = path[1:len(path) - 1]
	}
	expanded: [TARGET_BYTES]u8 = ---
	if spelling, fits := localpath.expand_variables(path, expanded[:]); fits {path = spelling}
	if winpath.is_drive_absolute(path) {
		if !localpath.local_absolute(path) {return "", false}
		return web_file_url_from_path(path, allocator)
	}
	if web_file_url(trimmed) || weburl.allowed(trimmed) {
		cloned, err := strings.clone(trimmed, allocator)
		return cloned, err == nil
	}
	if strings.contains(trimmed, "://") {return "", false}
	host, valid := bare_authority_host(trimmed)
	if !valid {return "", false}
	prefix := "https://"
	if strings.equal_fold(host, "localhost") || host == "127.0.0.1" || host == "[::1]" {
		prefix = "http://"
	}
	candidate, err := strings.concatenate({prefix, trimmed}, allocator)
	if err != nil {return "", false}
	if !weburl.allowed(candidate) {delete(candidate, allocator); return "", false}
	return candidate, true
}

// Encode the native path literally: '#' and '%' in a filename are not URI syntax.
@(private, require_results)
web_file_url_from_path :: proc(path: string, allocator: mem.Allocator) -> (string, bool) {
	PREFIX :: "file:///"
	hex := "0123456789ABCDEF"
	suffix := transmute([]u8)path[2:]
	size := len(PREFIX) + len(path)
	for c in suffix {
		if !web_file_url_path_byte(c) {size += 2}
	}
	out, err := make([]u8, size, allocator)
	if err != nil {return "", false}
	copy(out, PREFIX)
	at := len(PREFIX)
	out[at], out[at + 1] = path[0], ':'
	at += 2
	for c in suffix {
		if winpath.is_separator(c) {
			out[at] = '/'
		} else if web_file_url_path_byte(c) {
			out[at] = c
		} else {
			out[at], out[at + 1], out[at + 2] = '%', hex[c >> 4], hex[c & 0xf]
			at += 2
		}
		at += 1
	}
	return string(out), true
}

@(private, require_results)
web_file_url_path_byte :: proc(c: u8) -> bool {
	switch c {
	case 'A'..='Z', 'a'..='z', '0'..='9', '-', '_', '.', '~', '/', '\\': return true
	case: return false
	}
}

// Require a drive path, not a file authority (which could name a network share).
@(private, require_results)
web_file_url :: proc(uri: string) -> bool {
	if len(uri) < 11 || !weburl.scheme_is(uri[:8], "file:///") {return false}
	drive := uri[8]
	if !(drive >= 'A' && drive <= 'Z' || drive >= 'a' && drive <= 'z') {return false}
	if uri[9:11] != ":/" {return false}
	for c in uri[11:] {
		if c < 0x20 || c == 0x7f || c == '\\' {return false}
	}
	return true
}

// The host in a bare address with at most a numeric port. A scheme without slashes (such as
// `about:blank` or `file:name`) is not a host and port.
@(private, require_results)
bare_authority_host :: proc(text: string) -> (string, bool) {
	authority := text
	if end := strings.index_any(authority, "/?#"); end >= 0 {authority = authority[:end]}
	port_at := strings.index_byte(authority, ':')
	if strings.has_prefix(authority, "[") {
		close := strings.index_byte(authority, ']')
		if close < 0 {return "", false}
		if close + 1 == len(authority) {return authority, true}
		port_at = close + 1
		if authority[port_at] != ':' {return "", false}
	}
	if port_at < 0 {return authority, true}
	port := authority[port_at + 1:]
	if port == "" {return "", false}
	for c in transmute([]u8)port {if c < '0' || c > '9' {return "", false}}
	return authority[:port_at], true
}
