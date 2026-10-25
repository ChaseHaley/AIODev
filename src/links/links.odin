package links

import "core:strings"

// Range is a byte span in the text the caller scanned. End is exclusive.
Range :: struct {
	start, end: int,
}

// Allowed reports whether a target may be opened. Only plain http and https URLs pass: the
// authority must exist and look like a host, and Windows path shapes, credentials, control
// characters and backslashes are refused. This is the one allowlist both detection and the
// opener use, so a target can never be clickable but unopenable, or openable but invisible.
@(require_results)
allowed :: proc(uri: string) -> bool {
	if len(uri) < 8 {
		return false
	}
	for c in uri {
		if c <= 0x20 || c == 0x7f || c == '\\' || c == '"' || c == '<' || c == '>' {
			return false
		}
	}
	separator := -1
	for i := 0; i + 2 < len(uri); i += 1 {
		if uri[i] == ':' && uri[i + 1] == '/' && uri[i + 2] == '/' {
			separator = i
			break
		}
	}
	if separator <= 0 {
		return false
	}
	if !scheme_is(uri[:separator], "http") && !scheme_is(uri[:separator], "https") {
		return false
	}
	rest := uri[separator + 3:]
	authority_end := len(rest)
	for c, i in rest {
		if c == '/' || c == '?' || c == '#' {
			authority_end = i
			break
		}
	}
	authority := rest[:authority_end]
	if authority == "" {
		return false
	}
	// A drive-letter authority is a Windows path wearing a URL scheme, not a web host.
	if len(authority) == 2 && authority[1] == ':' {
		return false
	}
	if authority[0] == ':' || authority[0] == '.' || authority[len(authority) - 1] == ':' {
		return false
	}
	has_alphanumeric, bracket_open, bracket_close := false, false, false
	for c in authority {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
			has_alphanumeric = true
		case c == '-', c == '.', c == '_', c == ':':
		case c == '[':
			bracket_open = true
		case c == ']':
			bracket_close = true
		case:
			return false
		}
	}
	return has_alphanumeric && bracket_open == bracket_close
}

@(private, require_results)
scheme_is :: proc(value, expected: string) -> bool {
	if len(value) != len(expected) {
		return false
	}
	for i in 0 ..< len(value) {
		c := value[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != expected[i] {
			return false
		}
	}
	return true
}

// Find appends the http and https URLs in one line of text, with prose punctuation removed.
// It does not join lines: the caller decides which physical rows are one logical line.
@(require_results)
find :: proc(text: string, out: ^[dynamic]Range) -> bool {
	at := 0
	for at < len(text) {
		start := -1
		if scheme_starts(text, at, "https") || scheme_starts(text, at, "http") {
			start = at
		}
		if start < 0 {
			at += 1
			continue
		}
		if start > 0 && word_byte(text[start - 1]) {
			at = start + 1
			continue
		}
		end := start
		for end < len(text) {
			c := text[end]
			if c <= ' ' || c == 0x7f || c == '"' || c == '<' || c == '>' || c == '\\' ||
			   c == '`' || c == '|' {
				break
			}
			end += 1
		}
		trimmed := trim_prose(text, start, end)
		if trimmed > start && allowed(text[start:trimmed]) {
			if _, err := append(out, Range{start, trimmed}); err != nil {
				return false
			}
		}
		at = end > start ? end : start + 1
	}
	return true
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
			case strings.has_suffix(text[start:trim], "\u2026"):
				trim -= 3
			case strings.has_suffix(text[start:trim], "\u2019"),
			     strings.has_suffix(text[start:trim], "\u201d"):
				trim -= 3
			case strings.has_suffix(text[start:trim], "\u00bb"):
				trim -= 2
			case:
				return trim
			}
		}
	}
	return trim
}
