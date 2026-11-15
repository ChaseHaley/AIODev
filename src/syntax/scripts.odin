// Lexers for the scripting languages: Python, Lua, POSIX shells and PowerShell.
package syntax

import "core:strings"

lex_python :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	line_start := true
	for i < n && !s.failed {
		c := text[i]
		if c == '\n' {
			line_start = true
			i += 1
			continue
		}
		if c == ' ' || c == '\t' || c == '\r' || c == '\f' {
			i += 1
			continue
		}
		start := i
		switch {
		case c == '#':
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
		case c == '"' || c == '\'':
			i = python_string_end(text, i)
			emit(&s, start, i, .String)
		case is_digit(c) || c == '.' && i + 1 < n && is_digit(text[i + 1]):
			i = number_end(text, i)
			emit(&s, start, i, .Number)
		// A decorator starts a line; elsewhere @ is matrix multiplication.
		case c == '@' && line_start && i + 1 < n && is_alpha(text[i + 1]):
			i += 1
			for i < n && (is_word(text[i]) || text[i] == '.') {i += 1}
			emit(&s, start, i, .Attribute)
		case is_alpha(c):
			i = word_end(text, i)
			if i < n && (text[i] == '"' || text[i] == '\'') && python_string_prefix(text[start:i]) {
				i = python_string_end(text, i)
				emit(&s, start, i, .String)
			} else {
				emit(&s, start, i, python_word(text, start, i))
			}
		case:
			i += 1
		}
		line_start = false
	}
	return !s.failed
}

lex_lua :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	for i < n && !s.failed {
		c := text[i]
		start := i
		switch {
		case c == '-' && i + 1 < n && text[i + 1] == '-':
			level := long_bracket_level(text, i + 2)
			if level >= 0 {
				i = long_bracket_end(text, i + 2, level)
			} else {
				i = line_end(text, i)
			}
			emit(&s, start, trim_cr(text, start, i), .Comment)
		case c == '[' && long_bracket_level(text, i) >= 0:
			i = long_bracket_end(text, i, long_bracket_level(text, i))
			emit(&s, start, i, .String)
		case c == '"' || c == '\'':
			i = quoted_end(text, i, '\\', false)
			emit(&s, start, i, .String)
		case is_digit(c) || c == '.' && i + 1 < n && is_digit(text[i + 1]):
			i = number_end(text, i)
			emit(&s, start, i, .Number)
		case is_alpha(c):
			i = word_end(text, i)
			emit(&s, start, i, lua_word(text, start, i))
		case strings.has_prefix(text[i:], "<const>") || strings.has_prefix(text[i:], "<close>"):
			i += len("<const>")
			emit(&s, start + 1, i - 1, .Attribute)
		case:
			i += 1
		}
	}
	return !s.failed
}

// Shell heredocs open on a line and their bodies follow it; a line rarely opens more than a few.
@(private="file")
Heredoc :: struct {
	word:       string,
	strip_tabs: bool,
}

lex_shell :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	heredocs: [4]Heredoc
	pending := 0
	i := 0
	for i < n && !s.failed {
		c := text[i]
		start := i
		switch {
		case c == '\n':
			i += 1
			if pending > 0 {
				i = heredoc_bodies(&s, heredocs[:pending], i)
				pending = 0
			}
		case c == '\\':
			i += 2
		case c == '#' && (i == 0 || shell_separator(text[i - 1])):
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
		case c == '\'':
			i = quoted_end(text, i, 0, true)
			emit(&s, start, i, .String)
		case c == '"':
			i = quoted_end(text, i, '\\', true)
			emit(&s, start, i, .String)
		case c == '$' && i + 1 < n && text[i + 1] == '\'':
			i = quoted_end(text, i + 1, '\\', true)
			emit(&s, start, i, .String)
		case c == '$':
			i = shell_variable_end(text, i)
			if i > start + 1 {emit(&s, start, i, .Attribute)}
		// A <<< here-string takes an ordinary word or string, so its third < must not open a heredoc.
		case c == '<' && i + 2 < n && text[i + 1] == '<' && text[i + 2] == '<':
			i += 3
		case c == '<' && i + 2 < n && text[i + 1] == '<':
			heredoc, word_start, end, ok := heredoc_opening(text, i)
			if ok && pending < len(heredocs) {
				heredocs[pending] = heredoc
				pending += 1
				emit(&s, word_start, end, .String)
				i = end
			} else {
				i += 2
			}
		case shell_word_char(c):
			for i < n && shell_word_char(text[i]) {i += 1}
			emit(&s, start, i, shell_word(text, start, i))
		case:
			i += 1
		}
	}
	return !s.failed
}

lex_powershell :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	s := Scan{text = text, out = out}
	n := len(text)
	i := 0
	for i < n && !s.failed {
		c := text[i]
		start := i
		switch {
		case c == '`':
			i += 2
		case c == '<' && i + 1 < n && text[i + 1] == '#':
			i = find_after(text, i + 2, "#>")
			emit(&s, start, i, .Comment)
		case c == '#' && (i == 0 || shell_separator(text[i - 1])):
			i = line_end(text, i)
			emit(&s, start, trim_cr(text, start, i), .Comment)
		case c == '@' && i + 1 < n && (text[i + 1] == '"' || text[i + 1] == '\''):
			end := here_string_end(text, i)
			if end < 0 {
				i += 1
			} else {
				i = end
				emit(&s, start, i, .String)
			}
		case c == '\'':
			i = quoted_end(text, i, 0, true)
			emit(&s, start, i, .String)
		case c == '"':
			i = quoted_end(text, i, '`', true)
			emit(&s, start, i, .String)
		case c == '$':
			kind: Token_Kind
			i, kind = powershell_variable(text, i)
			emit(&s, start, i, kind)
		// [int] names a type and [CmdletBinding()] an attribute; $a[0] and $a[$i] index.
		case c == '[' && i + 1 < n && is_alpha(text[i + 1]) && (i == 0 || !closes_operand(text[i - 1])):
			i += 1
			for i < n && (is_word(text[i]) || text[i] == '.') {i += 1}
			if i < n && text[i] == '(' {
				emit(&s, start + 1, i, .Attribute)
			} else if i < n && (text[i] == ']' || text[i] == '[' || text[i] == ',') {
				emit(&s, start + 1, i, .Type)
			}
		case c == '-' && i + 1 < n && is_alpha(text[i + 1]) && (i == 0 || !is_word(text[i - 1])):
			i = word_end(text, i + 1)
			buffer: [16]u8
			if powershell_operator(ascii_lower(text[start + 1:i], buffer[:])) {
				emit(&s, start, i, .Operator)
			}
		case is_digit(c) || c == '.' && i + 1 < n && is_digit(text[i + 1]):
			i = number_end(text, i)
			emit(&s, start, i, .Number)
		case is_alpha(c):
			i = word_end(text, i)
			command := false
			// Verb-Noun names a command.
			for i + 1 < n && text[i] == '-' && is_alpha(text[i + 1]) {
				i = word_end(text, i + 1)
				command = true
			}
			if command {
				emit(&s, start, i, .Function)
			} else {
				buffer: [16]u8
				kind := powershell_word(ascii_lower(text[start:i], buffer[:]))
				if kind == .Plain && i < n && text[i] == '(' {kind = .Function}
				emit(&s, start, i, kind)
			}
		case:
			i += 1
		}
	}
	return !s.failed
}

@(private="file", require_results)
python_string_prefix :: proc(prefix: string) -> bool {
	if len(prefix) > 2 {return false}
	for c in transmute([]u8)prefix {
		switch c {
		case 'r', 'R', 'b', 'B', 'f', 'F', 'u', 'U', 't', 'T':
		case:
			return false
		}
	}
	return true
}

// `q` is the opening quote; returns the end of the string, or of its line when a one-line string is
// left open.
@(private="file", require_results)
python_string_end :: proc(text: string, q: int) -> int {
	n := len(text)
	quote := text[q]
	if q + 2 < n && text[q + 1] == quote && text[q + 2] == quote {
		i := q + 3
		for i < n {
			if text[i] == '\\' {
				i += 2
			} else if text[i] == quote && i + 2 < n && text[i + 1] == quote && text[i + 2] == quote {
				return i + 3
			} else {
				i += 1
			}
		}
		return n
	}
	return quoted_end(text, q, '\\', false)
}

@(private="file", require_results)
python_word :: proc(text: string, start, end: int) -> Token_Kind {
	word := text[start:end]
	switch word {
	case "False", "None", "True", "NotImplemented", "Ellipsis", "__debug__":
		return .Constant
	case "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
	     "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not",
	     "or", "pass", "raise", "return", "try", "while", "with", "yield":
		return .Keyword
	case "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset", "int", "list", "memoryview",
	     "object", "range", "set", "slice", "str", "tuple", "type":
		return .Type
	}
	if end < len(text) && text[end] == '(' {return .Function}
	// Classes are CapWords; an all-caps name is a constant.
	if word[0] >= 'A' && word[0] <= 'Z' {
		for c in transmute([]u8)word {
			if c >= 'a' && c <= 'z' {return .Type}
		}
	}
	return .Plain
}

@(private="file", require_results)
lua_word :: proc(text: string, start, end: int) -> Token_Kind {
	switch text[start:end] {
	case "true", "false", "nil":
		return .Constant
	case "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not",
	     "or", "repeat", "return", "then", "until", "while":
		return .Keyword
	}
	if end < len(text) && text[end] == '(' {return .Function}
	return .Plain
}

// The level of a Lua long bracket opening at `i` ("[[" is 0, "[==[" is 2), or -1 when there is none.
@(private="file", require_results)
long_bracket_level :: proc(text: string, i: int) -> int {
	if i >= len(text) || text[i] != '[' {return -1}
	j := i + 1
	for j < len(text) && text[j] == '=' {j += 1}
	if j < len(text) && text[j] == '[' {return j - i - 1}
	return -1
}

@(private="file", require_results)
long_bracket_end :: proc(text: string, i, level: int) -> int {
	n := len(text)
	j := i + level + 2
	for j < n {
		if text[j] != ']' {
			j += 1
			continue
		}
		k := j + 1
		for k < n && text[k] == '=' {k += 1}
		if k - j - 1 == level && k < n && text[k] == ']' {return k + 1}
		j = k
	}
	return n
}

// Bytes after which a # starts a comment rather than continuing a word.
@(private="file", require_results)
shell_separator :: proc(c: u8) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', ';', '&', '|', '(', ')':
		return true
	}
	return false
}

@(private="file", require_results)
shell_word_char :: proc(c: u8) -> bool {
	switch c {
	case '-', '.', '/', '+', '%', '~', ':', '@', ',':
		return true
	}
	return is_word(c)
}

@(private="file", require_results)
shell_word :: proc(text: string, start, end: int) -> Token_Kind {
	word := text[start:end]
	if is_digit(word[0]) {return .Number if number_end(text, start) == end else .Plain}
	switch word {
	case "true", "false":
		return .Constant
	case "if", "then", "else", "elif", "fi", "case", "esac", "for", "select", "while", "until", "do", "done",
	     "in", "function", "time", "coproc", "return", "break", "continue", "exit", "local", "export",
	     "readonly", "declare", "typeset", "unset", "shift", "eval", "exec", "source", "trap":
		return .Keyword
	}
	if end < len(text) && text[end] == '(' && is_alpha(word[0]) {return .Function}
	return .Plain
}

// `i` is at a $; returns the end of the variable it names, or i + 1 when it names none.
@(private="file", require_results)
shell_variable_end :: proc(text: string, i: int) -> int {
	n := len(text)
	j := i + 1
	if j >= n {return j}
	c := text[j]
	switch {
	case c == '{':
		j += 1
		for j < n && text[j] != '}' && text[j] != '\n' {j += 1}
		if j < n && text[j] == '}' {return j + 1}
		return trim_cr(text, i, j)
	case is_alpha(c):
		return word_end(text, j)
	case is_digit(c):
		return j + 1
	}
	switch c {
	case '@', '#', '?', '$', '!', '*', '-':
		return j + 1
	}
	return j
}

// `i` is at "<<"; reads the delimiter of `<<WORD`, `<<-WORD`, `<<'WORD'` or `<<"WORD"`. Arithmetic
// shifts like `1<<2` are not heredocs because a delimiter starts with a letter or a quote.
@(private="file", require_results)
heredoc_opening :: proc(text: string, i: int) -> (heredoc: Heredoc, word_start, end: int, ok: bool) {
	n := len(text)
	j := i + 2
	if j < n && text[j] == '-' {
		heredoc.strip_tabs = true
		j += 1
	}
	for j < n && (text[j] == ' ' || text[j] == '\t') {j += 1}
	word_start = j
	if j < n && (text[j] == '\'' || text[j] == '"') {
		k := j + 1
		for k < n && text[k] != text[j] && text[k] != '\n' {k += 1}
		if k >= n || text[k] != text[j] || k == j + 1 {return}
		heredoc.word = text[j + 1:k]
		return heredoc, word_start, k + 1, true
	}
	if j < n && text[j] == '\\' {j += 1}
	if j >= n || !is_alpha(text[j]) {return}
	k := word_end(text, j)
	heredoc.word = text[j:k]
	return heredoc, word_start, k, true
}

// `i` starts the line after the one that opened `heredocs`; each body runs through its terminator line.
// Returns where lexing resumes.
@(private="file", require_results)
heredoc_bodies :: proc(s: ^Scan, heredocs: []Heredoc, i: int) -> int {
	text := s.text
	n := len(text)
	i := i
	for heredoc in heredocs {
		body := i
		for {
			if i >= n {
				emit(s, body, n, .String)
				return n
			}
			end := line_end(text, i)
			content := trim_cr(text, i, end)
			k := i
			if heredoc.strip_tabs {
				for k < content && text[k] == '\t' {k += 1}
			}
			i = end + 1
			if text[k:content] == heredoc.word {
				emit(s, body, content, .String)
				break
			}
		}
	}
	return min(i, n)
}

// `i` is at "@\"" or "@'"; the opening must end its line and the closing "\"@" or "'@" starts one.
// Returns -1 when this is not a here-string.
@(private="file", require_results)
here_string_end :: proc(text: string, i: int) -> int {
	n := len(text)
	quote := text[i + 1]
	j := i + 2
	for j < n && (text[j] == ' ' || text[j] == '\t' || text[j] == '\r') {j += 1}
	if j >= n || text[j] != '\n' {return -1}
	for j < n {
		j += 1
		if j + 1 < n && text[j] == quote && text[j + 1] == '@' {return j + 2}
		j = line_end(text, j)
	}
	return n
}

@(private="file", require_results)
powershell_variable :: proc(text: string, i: int) -> (end: int, kind: Token_Kind) {
	n := len(text)
	j := i + 1
	if j >= n {return j, .Plain}
	c := text[j]
	switch {
	case c == '{':
		j += 1
		for j < n && text[j] != '}' && text[j] != '\n' {j += 1}
		if j < n && text[j] == '}' {return j + 1, .Attribute}
		return trim_cr(text, i, j), .Attribute
	case is_alpha(c):
		j = word_end(text, j)
		// A scope or drive qualifier: $env:Path, $script:count.
		if j + 1 < n && text[j] == ':' && is_alpha(text[j + 1]) {return word_end(text, j + 1), .Attribute}
		buffer: [8]u8
		switch ascii_lower(text[i + 1:j], buffer[:]) {
		case "true", "false", "null":
			return j, .Constant
		}
		return j, .Attribute
	case c == '$' || c == '?' || c == '^':
		return j + 1, .Attribute
	}
	return j, .Plain
}

// The bytes after which [ indexes rather than opening a type or attribute.
@(private="file", require_results)
closes_operand :: proc(c: u8) -> bool {
	return is_word(c) || c == ']' || c == ')'
}

// `word` is lowercase.
@(private="file", require_results)
powershell_word :: proc(word: string) -> Token_Kind {
	switch word {
	case "begin", "break", "catch", "class", "clean", "continue", "data", "default", "define", "do",
	     "dynamicparam", "else", "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "from",
	     "function", "hidden", "if", "in", "inlinescript", "param", "parallel", "process", "return",
	     "sequence", "static", "switch", "throw", "trap", "try", "until", "using", "var", "while", "workflow":
		return .Keyword
	}
	return .Plain
}

// `word` is lowercase, without the dash; -ceq and -ieq are the case-sensitive and -insensitive -eq.
@(private="file", require_results)
powershell_operator :: proc(word: string) -> bool {
	switch word {
	case "and", "or", "not", "xor", "band", "bor", "bxor", "bnot", "shl", "shr", "is", "isnot", "as", "join",
	     "f":
		return true
	}
	if powershell_case_operator(word) {return true}
	return len(word) > 1 && (word[0] == 'c' || word[0] == 'i') && powershell_case_operator(word[1:])
}

@(private="file", require_results)
powershell_case_operator :: proc(word: string) -> bool {
	switch word {
	case "eq", "ne", "gt", "ge", "lt", "le", "like", "notlike", "match", "notmatch", "contains",
	     "notcontains", "in", "notin", "replace", "split":
		return true
	}
	return false
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
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

// Bytes of multi-byte UTF-8 count as letters so identifiers in any script stay whole.
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

// Decimal, hex, binary and octal integers and floats with `_` separators; a trailing suffix (`L`, `j`,
// `kb`) stays part of the number.
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

@(private="file", require_results)
ascii_lower :: proc(word: string, buffer: []u8) -> string {
	if len(word) > len(buffer) {return ""}
	for i in 0 ..< len(word) {
		c := word[i]
		buffer[i] = c + 32 if c >= 'A' && c <= 'Z' else c
	}
	return string(buffer[:len(word)])
}
