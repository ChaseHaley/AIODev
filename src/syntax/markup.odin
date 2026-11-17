// Lexers for data and markup: JSON, TOML, YAML, HTML and XML, CSS and SCSS, Markdown.
package syntax

import "core:strings"

// JSON and JSONC: a string followed by a colon is a key.
@(require_results)
lex_json :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	for i < n && !s.failed {
		c := text[i]
		start := i
		switch {
		case c == '"':
			i = quoted_end(text, i, '\\', false)
			j := i
			for j < n && is_space(text[j]) {j += 1}
			emit(&s, start, i, .Attribute if j < n && text[j] == ':' else .String)
		case c == '/' && i + 1 < n && text[i + 1] == '/':
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
		case c == '/' && i + 1 < n && text[i + 1] == '*':
			i = find_after(text, i + 2, "*/")
			emit(&s, start, i, .Comment)
		case is_digit(c) || c == '-' && i + 1 < n && is_digit(text[i + 1]):
			i = number_end(text, i if is_digit(c) else i + 1)
			emit(&s, start, i, .Number)
		case is_alpha(c):
			i = word_end(text, i)
			switch text[start:i] {
			case "true", "false", "null":
				emit(&s, start, i, .Constant)
			}
		case:
			i += 1
		}
	}
	return !s.failed
}

@(require_results)
lex_toml :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	line_start := true
	// A key may start here: at the start of a line outside arrays, and after { or , in an inline table.
	key := false
	nesting: Nesting
	for i < n && !s.failed {
		c := text[i]
		start := i
		if c == '\n' {
			line_start = true
			i += 1
			continue
		}
		if c == ' ' || c == '\t' || c == '\r' {
			i += 1
			continue
		}
		if line_start {
			line_start = false
			key = nesting.depth == 0 || in_brace(nesting)
			if c == '[' && nesting.depth == 0 {
				i = toml_header_end(text, i)
				emit(&s, start, i, .Type)
				key = false
				continue
			}
		}
		if key {
			key = false
			if end, ok := toml_key_end(text, i); ok {
				emit(&s, start, end, .Attribute)
				i = end
				continue
			}
		}
		switch {
		case c == '#':
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
		case c == '"' || c == '\'':
			escape: u8 = '\\' if c == '"' else 0
			i = triple_quoted_end(text, i, escape) if triple_quote(text, i) else quoted_end(text, i, escape, false)
			emit(&s, start, i, .String)
		case is_digit(c) || (c == '+' || c == '-') && i + 1 < n && is_digit(text[i + 1]):
			i = toml_number_end(text, i)
			emit(&s, start, i, .Number)
		case is_alpha(c):
			i = bare_key_end(text, i)
			switch text[start:i] {
			case "true", "false":
				emit(&s, start, i, .Constant)
			case "inf", "nan":
				emit(&s, start, i, .Number)
			}
		case c == '[' || c == '{':
			nesting_push(&nesting, c == '{')
			key = c == '{'
			i += 1
		case c == ']' || c == '}':
			nesting_pop(&nesting)
			i += 1
		case c == ',':
			key = in_brace(nesting)
			i += 1
		case:
			i += 1
		}
	}
	return !s.failed
}

@(require_results)
lex_yaml :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	line := 0
	line_start := true
	key := false
	// The column of the node a `|` or `>` block scalar belongs to; its content is indented deeper.
	owner := 0
	block := -1
	nesting: Nesting
	for i < n && !s.failed {
		if line_start {
			line_start = false
			line = i
			end := line_end(text, i)
			content := trim_cr(text, i, end)
			indent := 0
			for i + indent < content && text[i + indent] == ' ' {indent += 1}
			if block >= 0 {
				if i + indent == content || indent > block {
					emit(&s, i + indent, content, .String)
					i = end
					continue
				}
				block = -1
			}
			marker := text[i:content]
			if (strings.has_prefix(marker, "---") || strings.has_prefix(marker, "...")) &&
			   (len(marker) == 3 || is_space(marker[3])) {
				emit(&s, i, i + 3, .Keyword)
				i += 3
			} else {
				i += indent
			}
			key = nesting.depth == 0
			owner = indent
			continue
		}
		c := text[i]
		start := i
		if c == '\n' {
			line_start = true
			i += 1
			continue
		}
		if c == ' ' || c == '\t' || c == '\r' {
			i += 1
			continue
		}
		if c == '#' && (i == line || text[i - 1] == ' ' || text[i - 1] == '\t') {
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
			continue
		}
		flow := nesting.depth > 0
		if key {
			// A sequence entry may hold a mapping: "- name: value".
			if c == '-' && (i + 1 == n || is_space(text[i + 1])) {
				owner = i - line
				i += 1
				continue
			}
			key = false
			if end, colon, ok := yaml_key(text, i, flow); ok {
				emit(&s, start, end, .Attribute)
				owner = start - line
				i = colon + 1
				continue
			}
		}
		switch {
		case c == '"':
			i = quoted_end(text, i, '\\', true)
			emit(&s, start, i, .String)
		case c == '\'':
			i = quoted_end(text, i, 0, true)
			emit(&s, start, i, .String)
		case c == '|' || c == '>':
			if yaml_block_header(text, i) {block = owner}
			i += 1
		case (c == '&' || c == '*') && i + 1 < n && !is_space(text[i + 1]):
			i = yaml_name_end(text, i + 1)
			emit(&s, start, i, .Constant)
		case c == '!':
			i = yaml_name_end(text, i + 1)
			emit(&s, start, i, .Type)
		case c == '[' || c == '{':
			nesting_push(&nesting, c == '{')
			key = c == '{'
			i += 1
		case c == ']' || c == '}':
			nesting_pop(&nesting)
			i += 1
		case c == ',':
			key = in_brace(nesting)
			i += 1
		case:
			i = yaml_plain_end(text, i, flow)
			if i == start {
				i += 1
			} else {
				emit(&s, start, i, yaml_scalar(text[start:i]))
			}
		}
	}
	return !s.failed
}

// HTML, XML and SVG. Style and script elements hold CSS and JavaScript, lexed as such.
@(require_results)
lex_html :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	for i < n && !s.failed {
		c := text[i]
		start := i
		if c == '&' {
			i = max(entity_end(text, i), i + 1)
			if i > start + 1 {emit(&s, start, i, .Constant)}
			continue
		}
		if c != '<' || i + 1 >= n {
			i += 1
			continue
		}
		next := text[i + 1]
		switch {
		case strings.has_prefix(text[i:], "<!--"):
			i = find_after(text, i + 4, "-->")
			emit(&s, start, i, .Comment)
		case strings.has_prefix(text[i:], "<![CDATA["):
			i = find_after(text, i + 9, "]]>")
			emit(&s, start, i, .String)
		case next == '!' || next == '?':
			i = find_after(text, i + 2, ">")
			emit(&s, start, i, .Keyword)
		case is_alpha(next) || next == '/' && i + 2 < n && is_alpha(text[i + 2]):
			i = html_tag(&s, i)
		case:
			i += 1
		}
	}
	return !s.failed
}

// CSS and SCSS.
@(require_results)
lex_css :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	statement := true
	mode := Css_Mode.Selector
	// The delimiter the last look-ahead stopped at and what it decided. A statement that starts before it
	// (the look-ahead read a quote the lexer did not) takes the same answer, so no byte is looked over twice.
	decided := 0
	decided_mode := Css_Mode.Selector
	for i < n && !s.failed {
		c := text[i]
		start := i
		if is_space(c) {
			i += 1
			continue
		}
		if c == '/' && i + 1 < n && text[i + 1] == '*' {
			i = find_after(text, i + 2, "*/")
			emit(&s, start, i, .Comment)
			continue
		}
		if c == '/' && i + 1 < n && text[i + 1] == '/' {
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
			continue
		}
		if statement {
			statement = false
			if c == '@' {
				mode = .Value
			} else {
				if i >= decided {decided_mode, decided = css_statement_mode(text, i)}
				mode = decided_mode
			}
		}
		switch {
		case c == '{' || c == '}' || c == ';':
			statement = true
			i += 1
		case c == '"' || c == '\'':
			i = quoted_end(text, i, '\\', false)
			emit(&s, start, i, .String)
		// SCSS interpolation, kept whole so a } inside it does not end the statement.
		case c == '#' && i + 1 < n && text[i + 1] == '{':
			k := strings.index_byte(text[i + 2:], '}')
			i = n if k < 0 else i + 2 + k + 1
		case c == '@' && i + 1 < n && (is_alpha(text[i + 1]) || text[i + 1] == '-'):
			i = css_name_end(text, i + 1)
			emit(&s, start, i, .Keyword)
		case mode == .Selector:
			if css_selector_char(c) {
				for i < n && css_selector_char(text[i]) {i += 1}
				emit(&s, start, i, .Tag)
			} else {
				i += 1
			}
		case mode == .Property:
			if c == ':' {
				mode = .Value
				i += 1
			} else if css_name_char(c) || c == '$' || c == '*' {
				i = css_name_end(text, i + 1)
				emit(&s, start, i, .Attribute)
			} else {
				i += 1
			}
		case:
			i = css_value(&s, i)
		}
	}
	return !s.failed
}

// Headings, code spans, fenced code and links; emphasis stays plain.
@(require_results)
lex_markdown :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	for i < n && !s.failed {
		end := line_end(text, i)
		content := trim_cr(text, i, end)
		indent := 0
		for indent < 4 && i + indent < content && text[i + indent] == ' ' {indent += 1}
		first := i + indent
		if indent < 4 && first < content {
			c := text[first]
			run := run_length(text, first, content)
			// A backtick fence's info string may not hold a backtick.
			if (c == '`' || c == '~') && run >= 3 &&
			   (c == '~' || strings.index_byte(text[first + run:content], '`') < 0) {
				close, resume := fence_close(text, end, c, run)
				emit(&s, first, close, .String)
				i = resume
				continue
			}
			if c == '#' && run <= 6 && (first + run == content || is_space(text[first + run])) {
				emit(&s, first, content, .Keyword)
				i = end + 1
				continue
			}
		}
		markdown_inline(&s, first, content)
		i = end + 1
	}
	return !s.failed
}

// The open brackets of TOML arrays and inline tables or of YAML flow collections; bit d is set when
// level d is a { (deeper levels count but are taken as [).
@(private="file")
Nesting :: struct {
	braces: u64,
	depth:  int,
}

@(private="file")
nesting_push :: proc(nesting: ^Nesting, brace: bool) {
	if nesting.depth < 64 {
		bit := u64(1) << uint(nesting.depth)
		nesting.braces = nesting.braces | bit if brace else nesting.braces & ~bit
	}
	nesting.depth += 1
}

@(private="file")
nesting_pop :: proc(nesting: ^Nesting) {
	if nesting.depth > 0 {nesting.depth -= 1}
}

@(private="file", require_results)
in_brace :: proc(nesting: Nesting) -> bool {
	return nesting.depth > 0 && nesting.depth <= 64 && nesting.braces & (u64(1) << uint(nesting.depth - 1)) != 0
}

// `i` is at the [ of a [table] or [[array]] header; the header ends with its line.
@(private="file", require_results)
toml_header_end :: proc(text: string, i: int) -> int {
	n := len(text)
	double := i + 1 < n && text[i + 1] == '['
	j := i + 1
	for j < n && text[j] != ']' && text[j] != '\n' {
		j = quoted_end(text, j, '\\', false) if text[j] == '"' else j + 1
	}
	if j >= n || text[j] != ']' {return trim_cr(text, i, min(j, n))}
	j += 1
	if double && j < n && text[j] == ']' {j += 1}
	return j
}

// A key path such as `a."b c".d` ends where `=` follows it after blanks.
@(private="file", require_results)
toml_key_end :: proc(text: string, i: int) -> (end: int, ok: bool) {
	n := len(text)
	j := i
	for {
		if j < n && (text[j] == '"' || text[j] == '\'') {
			quote := text[j]
			k := quoted_end(text, j, '\\' if quote == '"' else 0, false)
			if k - j < 2 || text[k - 1] != quote {return}
			j = k
		} else {
			k := bare_key_end(text, j)
			if k == j {return}
			j = k
		}
		end = j
		for j < n && (text[j] == ' ' || text[j] == '\t') {j += 1}
		if j < n && text[j] == '.' {
			j += 1
			for j < n && (text[j] == ' ' || text[j] == '\t') {j += 1}
			continue
		}
		return end, j < n && text[j] == '='
	}
}

@(private="file", require_results)
bare_key_end :: proc(text: string, i: int) -> int {
	j := i
	for j < len(text) && (is_word(text[j]) || text[j] == '-') {j += 1}
	return j
}

// Integers, floats, dates and times: 1_000, 6.6e-34, 0xdead_beef, 1979-05-27T07:32:00-08:00.
@(private="file", require_results)
toml_number_end :: proc(text: string, i: int) -> int {
	n := len(text)
	j := i + 1
	for j < n {
		c := text[j]
		sign := (c == '+' || c == '-') && j + 1 < n && is_digit(text[j + 1])
		if !(is_word(c) || c == '.' || c == ':' || sign) {break}
		j += 1
	}
	return j
}

@(private="file", require_results)
triple_quote :: proc(text: string, q: int) -> bool {
	return q + 2 < len(text) && text[q + 1] == text[q] && text[q + 2] == text[q]
}

// `q` is at the first of three quotes; the string ends after the next three.
@(private="file", require_results)
triple_quoted_end :: proc(text: string, q: int, escape: u8) -> int {
	n := len(text)
	quote := text[q]
	i := q + 3
	for i < n {
		if text[i] == escape && escape != 0 {
			i += 2
		} else if text[i] == quote && i + 2 < n && text[i + 1] == quote && text[i + 2] == quote {
			return i + 3
		} else {
			i += 1
		}
	}
	return n
}

// A mapping key at `i`: a quoted scalar or a plain one up to ": ". Returns the key's end without trailing
// blanks and the colon's index.
@(private="file", require_results)
yaml_key :: proc(text: string, i: int, flow: bool) -> (end, colon: int, ok: bool) {
	n := len(text)
	c := text[i]
	if c == '"' || c == '\'' {
		end = quoted_end(text, i, '\\' if c == '"' else 0, false)
		j := end
		for j < n && (text[j] == ' ' || text[j] == '\t') {j += 1}
		return end, j, j < n && text[j] == ':'
	}
	if strings.index_byte("[]{},&*!|>#%@`", c) >= 0 {return}
	for j := i; j < n; j += 1 {
		c = text[j]
		if c == '\n' {return}
		if c == ':' && (j + 1 == n || is_space(text[j + 1]) || flow && flow_indicator(text[j + 1])) {
			end = j
			for end > i && (text[end - 1] == ' ' || text[end - 1] == '\t') {end -= 1}
			return end, j, end > i
		}
		if c == '#' && (text[j - 1] == ' ' || text[j - 1] == '\t') {return}
		if flow && (flow_indicator(c) || c == '[' || c == '{') {return}
	}
	return
}

@(private="file", require_results)
flow_indicator :: proc(c: u8) -> bool {
	return c == ',' || c == ']' || c == '}'
}

// A plain scalar ends at a line break, ": ", " #" or, in a flow collection, at , ] or }.
@(private="file", require_results)
yaml_plain_end :: proc(text: string, i: int, flow: bool) -> int {
	n := len(text)
	j := i
	for j < n {
		c := text[j]
		if c == '\n' {break}
		if c == ':' && (j + 1 == n || is_space(text[j + 1]) || flow && flow_indicator(text[j + 1])) {break}
		if c == '#' && j > i && (text[j - 1] == ' ' || text[j - 1] == '\t') {break}
		if flow && (flow_indicator(c) || c == '[' || c == '{') {break}
		j += 1
	}
	for j > i && is_space(text[j - 1]) {j -= 1}
	return j
}

@(private="file", require_results)
yaml_scalar :: proc(word: string) -> Token_Kind {
	switch word {
	case "true", "True", "TRUE", "false", "False", "FALSE", "yes", "Yes", "YES", "no", "No", "NO", "on", "On",
	     "ON", "off", "Off", "OFF", "null", "Null", "NULL", "~":
		return .Constant
	case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF", "-.inf", "-.Inf", "-.INF", ".nan", ".NaN", ".NAN":
		return .Number
	}
	j := 0
	if word[0] == '-' || word[0] == '+' {j = 1}
	if j < len(word) && (is_digit(word[j]) || word[j] == '.' && j + 1 < len(word) && is_digit(word[j + 1])) {
		if number_end(word, j) == len(word) {return .Number}
	}
	return .Plain
}

// An anchor, alias or tag name runs to a blank or a flow indicator.
@(private="file", require_results)
yaml_name_end :: proc(text: string, i: int) -> int {
	j := i
	for j < len(text) && !is_space(text[j]) && !flow_indicator(text[j]) && text[j] != '[' && text[j] != '{' {
		j += 1
	}
	return j
}

// `|` or `>` with only indentation and chomping indicators, then a comment or the line end, after it.
@(private="file", require_results)
yaml_block_header :: proc(text: string, i: int) -> bool {
	n := len(text)
	j := i + 1
	for j < n && (is_digit(text[j]) || text[j] == '+' || text[j] == '-') {j += 1}
	for j < n && (text[j] == ' ' || text[j] == '\t') {j += 1}
	return j == n || text[j] == '\n' || text[j] == '\r' || text[j] == '#'
}

// `&name;`, `&#38;` or `&#x26;`; returns `i` when it is a lone ampersand.
@(private="file", require_results)
entity_end :: proc(text: string, i: int) -> int {
	limit := min(len(text), i + 32)
	j := i + 1
	if j < limit && text[j] == '#' {j += 1}
	for j < limit && is_word(text[j]) {j += 1}
	return j + 1 if j > i + 1 && j < limit && text[j] == ';' else i
}

// `i` is at the < of a start or end tag. Returns where lexing resumes: after the tag, or for a style or
// script element, at the end tag that closes its content.
@(private="file", require_results)
html_tag :: proc(s: ^Scan, i: int) -> int {
	text := s.text
	n := len(text)
	closing := text[i + 1] == '/'
	name_start := i + 2 if closing else i + 1
	j := name_start
	for j < n && (is_word(text[j]) || text[j] == '-' || text[j] == ':' || text[j] == '.') {j += 1}
	name := text[name_start:j]
	emit(s, i, j, .Tag)
	for j < n && !s.failed {
		c := text[j]
		start := j
		switch {
		case c == '>':
			emit(s, j, j + 1, .Tag)
			j += 1
			if closing {return j}
			lexer: Lexer
			language: Language
			if strings.equal_fold(name, "style") {
				lexer, language = lex_css, .Css
			} else if strings.equal_fold(name, "script") {
				lexer, language = lex_c_family, .JavaScript
			} else {
				return j
			}
			end := raw_text_end(text, j, name)
			embed(s, j, end, lexer, language)
			return end
		case c == '/' && j + 1 < n && text[j + 1] == '>':
			emit(s, j, j + 2, .Tag)
			return j + 2
		case c == '<':
			return j
		case c == '"' || c == '\'':
			j = quoted_end(text, j, 0, true)
			emit(s, start, j, .String)
		case c == '=':
			j += 1
			for j < n && is_space(text[j]) {j += 1}
			if j < n && (text[j] == '"' || text[j] == '\'') {continue}
			value := j
			for j < n && !is_space(text[j]) && text[j] != '>' && text[j] != '<' {j += 1}
			emit(s, value, j, .String)
		case is_space(c) || c == '/':
			j += 1
		case:
			for j < n && !is_space(text[j]) && strings.index_byte("=>/<\"'", text[j]) < 0 {j += 1}
			emit(s, start, j, .Attribute)
		}
	}
	return j
}

// The start of the `</name` that ends a raw text element's content at `i`, or len(text).
@(private="file", require_results)
raw_text_end :: proc(text: string, i: int, name: string) -> int {
	n := len(text)
	for j := i; j + 2 + len(name) <= n; j += 1 {
		if text[j] == '<' && text[j + 1] == '/' && strings.equal_fold(text[j + 2:j + 2 + len(name)], name) {
			return j
		}
	}
	return n
}

// Lexes text[start:end] in another language and moves its tokens to their place in the whole text.
@(private="file")
embed :: proc(s: ^Scan, start, end: int, lexer: Lexer, language: Language) {
	if end <= start || s.failed {return}
	before := len(s.out)
	if !lexer(language, s.text[start:end], s.out) {
		s.failed = true
		return
	}
	for &token in s.out[before:] {
		token.start += u32(start)
		token.end += u32(start)
	}
}

@(private="file")
Css_Mode :: enum u8 {
	Selector,
	Property,
	Value,
}

// A statement is a rule when a { comes before the ; or } that would end it as a declaration. Also returns
// where the look-ahead stopped.
@(private="file", require_results)
css_statement_mode :: proc(text: string, i: int) -> (mode: Css_Mode, stop: int) {
	n := len(text)
	j := i
	for j < n {
		c := text[j]
		next: u8 = text[j + 1] if j + 1 < n else 0
		switch {
		case c == '{':
			return .Selector, j
		case c == ';' || c == '}':
			return .Property, j
		case c == '"' || c == '\'':
			j = quoted_end(text, j, '\\', false)
		case c == '/' && next == '*':
			j = find_after(text, j + 2, "*/")
		case c == '/' && next == '/':
			j = line_end(text, j)
		case c == '#' && next == '{':
			k := strings.index_byte(text[j + 2:], '}')
			if k < 0 {return .Property, n}
			j += 2 + k + 1
		case:
			j += 1
		}
	}
	return .Property, n
}

@(private="file", require_results)
css_name_char :: proc(c: u8) -> bool {
	return is_word(c) || c == '-'
}

@(private="file", require_results)
css_name_end :: proc(text: string, i: int) -> int {
	j := i
	for j < len(text) && css_name_char(text[j]) {j += 1}
	return j
}

// Element, class, id and pseudo-class names, the SCSS parent `&` and placeholder `%`, keyframe stops.
@(private="file", require_results)
css_selector_char :: proc(c: u8) -> bool {
	switch c {
	case '.', '#', ':', '&', '*', '%':
		return true
	}
	return css_name_char(c)
}

// One token of a declaration value at `i`; returns where it ends.
@(private="file", require_results)
css_value :: proc(s: ^Scan, i: int) -> int {
	text := s.text
	n := len(text)
	c := text[i]
	next: u8 = text[i + 1] if i + 1 < n else 0
	after: u8 = text[i + 2] if i + 2 < n else 0
	signed := (c == '-' || c == '+') && (i == 0 || !css_name_char(text[i - 1])) &&
		(is_digit(next) || next == '.' && is_digit(after))
	switch {
	case is_digit(c) || c == '.' && is_digit(next) || signed:
		j := number_end(text, i + 1 if signed else i)
		if j < n && text[j] == '%' {j += 1}
		emit(s, i, j, .Number)
		return j
	case c == '#':
		j := word_end(text, i + 1)
		emit(s, i, j, .Number)
		return max(j, i + 1)
	case c == '!':
		j := i + 1
		for j < n && (text[j] == ' ' || text[j] == '\t') {j += 1}
		end := word_end(text, j)
		if end > j {emit(s, i, end, .Keyword)}
		return max(end, i + 1)
	case is_alpha(c) || c == '-' && (is_alpha(next) || next == '-'):
		j := css_name_end(text, i)
		if j >= n || text[j] != '(' {return j}
		emit(s, i, j, .Function)
		if !strings.equal_fold(text[i:j], "url") {return j}
		// An unquoted URL may hold // and ; so it is one string.
		k := j + 1
		for k < n && (text[k] == ' ' || text[k] == '\t') {k += 1}
		if k < n && (text[k] == '"' || text[k] == '\'') {return k}
		end := k
		for end < n && text[end] != ')' && text[end] != '\n' {end += 1}
		emit(s, k, end, .String)
		return end
	}
	return i + 1
}

@(private="file", require_results)
run_length :: proc(text: string, i, end: int) -> int {
	j := i
	for j < end && text[j] == text[i] {j += 1}
	return j - i
}

// `end` ends a fence's opening line. Returns the end of its closing line (without the line break) and
// where lexing resumes; an unclosed fence runs to the end of the text's last line.
@(private="file", require_results)
fence_close :: proc(text: string, end: int, fence: u8, run: int) -> (close, resume: int) {
	n := len(text)
	last := trim_cr(text, 0, end)
	i := end + 1
	for i < n {
		line := line_end(text, i)
		content := trim_cr(text, i, line)
		j := i
		for j - i < 4 && j < content && text[j] == ' ' {j += 1}
		if j - i < 4 && j < content && text[j] == fence {
			k := j + run_length(text, j, content)
			if k - j >= run {
				for k < content && (text[k] == ' ' || text[k] == '\t') {k += 1}
				if k == content {return content, line + 1}
			}
		}
		last = content
		i = line + 1
	}
	return last, n
}

// Code spans, links and autolinks within one line. A code span here does not continue onto the next
// line. `absent` remembers backtick run lengths with no closing run later on the line and `no_paren`
// that no `)` follows, so every search past the first one for a length stops at once.
@(private="file")
markdown_inline :: proc(s: ^Scan, start, end: int) {
	text := s.text
	absent: u64
	no_paren := false
	j := start
	for j < end && !s.failed {
		c := text[j]
		switch {
		case c == '\\':
			j += 2
		case c == '`':
			run := run_length(text, j, end)
			close := -1
			if run <= 64 && absent & (u64(1) << uint(run - 1)) == 0 {
				close = backtick_close(text, j + run, end, run)
				if close < 0 {absent |= u64(1) << uint(run - 1)}
			}
			if close >= 0 {
				emit(s, j, close, .String)
				j = close
			} else {
				j += run
			}
		case c == '[' || c == '!' && j + 1 < end && text[j + 1] == '[':
			j = markdown_link(s, j, end, j == start, &no_paren)
		case c == '<':
			k := j + 1
			linked := false
			for k < end && text[k] != '>' && text[k] != '<' && text[k] != ' ' && text[k] != '\t' {
				linked = linked || text[k] == ':' || text[k] == '@'
				k += 1
			}
			if linked && k < end && text[k] == '>' {
				emit(s, j, k + 1, .Function)
				j = k + 1
			} else {
				j += 1
			}
		case:
			j += 1
		}
	}
}

// The end of the next backtick run of exactly `run` from `i` on, or -1.
@(private="file", require_results)
backtick_close :: proc(text: string, i, end, run: int) -> int {
	k := i
	for k < end {
		if text[k] != '`' {
			k += 1
			continue
		}
		length := run_length(text, k, end)
		if length == run {return k + length}
		k += length
	}
	return -1
}

// `i` is at the [ (or ![) of a possible link: [text](url), [text][label], or a line's [label]: url
// definition. Returns where lexing resumes.
@(private="file", require_results)
markdown_link :: proc(s: ^Scan, i, end: int, first: bool, no_paren: ^bool) -> int {
	text := s.text
	open := i + 1 if text[i] == '!' else i
	k := open + 1
	for k < end && text[k] != ']' && text[k] != '[' {k += 2 if text[k] == '\\' else 1}
	if k >= end {return end}
	if text[k] == '[' {return k}
	next: u8 = text[k + 1] if k + 1 < end else 0
	switch {
	case next == '(' && !no_paren^:
		m := k + 2
		for m < end && text[m] != ')' {m += 2 if text[m] == '\\' else 1}
		if m < end {
			emit(s, i, m + 1, .Function)
			return m + 1
		}
		no_paren^ = true
	case next == '[':
		m := k + 2
		for m < end && text[m] != ']' && text[m] != '[' {m += 1}
		if m < end && text[m] == ']' {
			emit(s, i, m + 1, .Function)
			return m + 1
		}
	case next == ':' && first:
		emit(s, i, end, .Function)
		return end
	}
	return k + 1
}

// Shared by every lexer in this file.

@(private="file")
Scan :: struct {
	text:   string,
	out:    ^[dynamic]Token,
	failed: bool,
}

// Plain text is left out; an allocation failure makes every later emit a no-op.
@(private="file")
emit :: proc(s: ^Scan, start, end: int, kind: Token_Kind) {
	if end <= start || kind == .Plain || s.failed {return}
	if _, err := append(s.out, Token{start = u32(start), end = u32(end), kind = kind}); err != nil {
		s.failed = true
	}
}

@(private="file", require_results)
is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
}

@(private="file", require_results)
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// Bytes of multi-byte UTF-8 count as letters so names in any script stay whole.
@(private="file", require_results)
is_alpha :: proc(c: u8) -> bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_' || c >= 0x80
}

@(private="file", require_results)
is_word :: proc(c: u8) -> bool {
	return is_alpha(c) || is_digit(c)
}

@(private="file", require_results)
word_end :: proc(text: string, i: int) -> int {
	j := i
	for j < len(text) && is_word(text[j]) {j += 1}
	return j
}

// The index of the '\n' ending the line holding `i`, or len(text).
@(private="file", require_results)
line_end :: proc(text: string, i: int) -> int {
	k := strings.index_byte(text[i:], '\n')
	return len(text) if k < 0 else i + k
}

// A token ending at a line break leaves out the '\r' of a CRLF.
@(private="file", require_results)
trim_cr :: proc(text: string, start, end: int) -> int {
	return end - 1 if end > start && text[end - 1] == '\r' else end
}

// The end of `needle` after `from`, or len(text) when it never comes.
@(private="file", require_results)
find_after :: proc(text: string, from: int, needle: string) -> int {
	k := strings.index(text[from:], needle)
	return len(text) if k < 0 else from + k + len(needle)
}

// `q` is the opening quote; `escape` (0 for none) hides the byte after it. A string that may not span
// lines and is left open ends with its line.
@(private="file", require_results)
quoted_end :: proc(text: string, q: int, escape: u8, multiline: bool) -> int {
	n := len(text)
	quote := text[q]
	i := q + 1
	for i < n {
		c := text[i]
		if c == escape && escape != 0 {
			i += 2
		} else if c == quote {
			return i + 1
		} else if c == '\n' && !multiline {
			return trim_cr(text, q, i)
		} else {
			i += 1
		}
	}
	return n
}

// Decimal, hex, binary and octal integers and floats with `_` separators; a trailing unit or suffix
// (`px`, `em`) stays part of the number.
@(private="file", require_results)
number_end :: proc(text: string, i: int) -> int {
	n := len(text)
	j := i
	if j + 1 < n && text[j] == '0' {
		switch text[j + 1] {
		case 'x', 'X', 'b', 'B', 'o', 'O':
			return word_end(text, j + 2)
		}
	}
	for j < n && (is_digit(text[j]) || text[j] == '_') {j += 1}
	if j + 1 < n && text[j] == '.' && is_digit(text[j + 1]) {
		j += 1
		for j < n && (is_digit(text[j]) || text[j] == '_') {j += 1}
	}
	if j < n && (text[j] == 'e' || text[j] == 'E') {
		k := j + 1
		if k < n && (text[k] == '+' || text[k] == '-') {k += 1}
		if k < n && is_digit(text[k]) {j = k}
	}
	return word_end(text, j)
}
