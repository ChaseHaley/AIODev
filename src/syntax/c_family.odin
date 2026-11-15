package syntax

import "core:strings"

// No keyword, builtin type or constant name is longer, so a longer identifier skips the tables.
@(private="file")
WORD_LIMIT :: 16
// The C++ standard's limit on a raw string delimiter, which also bounds the search for its end.
@(private="file")
RAW_DELIMITER_LIMIT :: 16

@(private="file")
Words :: struct {
	keywords, types, constants: []string,
}

@(private="file", rodata)
C_WORDS := #partial [Language]Words {
	.Odin = {
		keywords = {
			"asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue",
			"defer", "distinct", "do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if",
			"import", "in", "map", "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return",
			"package", "proc", "return", "struct", "switch", "transmute", "union", "using", "when", "where",
		},
		types = {
			"any", "b8", "b16", "b32", "b64", "bool", "byte", "complex32", "complex64", "complex128",
			"cstring", "cstring16", "f16", "f16be", "f16le", "f32", "f32be", "f32le", "f64", "f64be",
			"f64le", "i8", "i16", "i16be", "i16le", "i32", "i32be", "i32le", "i64", "i64be", "i64le",
			"i128", "i128be", "i128le", "int", "quaternion64", "quaternion128", "quaternion256", "rawptr",
			"rune", "string", "string16", "typeid", "u8", "u16", "u16be", "u16le", "u32", "u32be", "u32le",
			"u64", "u64be", "u64le", "u128", "u128be", "u128le", "uint", "uintptr",
		},
		constants = {"true", "false", "nil"},
	},
	.C = {
		keywords = {
			"auto", "break", "case", "const", "constexpr", "continue", "default", "do", "else", "enum",
			"extern", "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
			"struct", "switch", "typedef", "typeof", "union", "volatile", "while", "alignas", "alignof",
			"static_assert", "thread_local", "_Alignas", "_Alignof", "_Atomic", "_Generic", "_Noreturn",
			"_Static_assert", "_Thread_local",
		},
		types = {
			"void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool", "_Bool",
			"_Complex", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t",
			"int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t", "uint64_t", "wchar_t", "char16_t",
			"char32_t",
		},
		constants = {"true", "false", "NULL", "nullptr"},
	},
	.Cpp = {
		keywords = {
			"alignas", "alignof", "and", "and_eq", "asm", "auto", "bitand", "bitor", "break", "case",
			"catch", "class", "co_await", "co_return", "co_yield", "compl", "concept", "const",
			"const_cast", "consteval", "constexpr", "constinit", "continue", "decltype", "default",
			"delete", "do", "dynamic_cast", "else", "enum", "explicit", "export", "extern", "final", "for",
			"friend", "goto", "if", "import", "inline", "module", "mutable", "namespace", "new", "noexcept",
			"not", "not_eq", "operator", "or", "or_eq", "override", "private", "protected", "public",
			"register", "reinterpret_cast", "requires", "return", "sizeof", "static", "static_assert",
			"static_cast", "struct", "switch", "template", "this", "thread_local", "throw", "try",
			"typedef", "typeid", "typename", "union", "using", "virtual", "volatile", "while", "xor",
			"xor_eq",
		},
		types = {
			"void", "char", "char8_t", "char16_t", "char32_t", "wchar_t", "short", "int", "long", "float",
			"double", "signed", "unsigned", "bool", "size_t", "ssize_t", "ptrdiff_t", "intptr_t",
			"uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
			"uint64_t",
		},
		constants = {"true", "false", "nullptr", "NULL"},
	},
	.CSharp = {
		keywords = {
			"abstract", "as", "async", "await", "base", "break", "case", "catch", "checked", "class",
			"const", "continue", "default", "delegate", "do", "else", "enum", "event", "explicit", "extern",
			"finally", "fixed", "for", "foreach", "goto", "if", "implicit", "in", "interface", "internal",
			"is", "lock", "nameof", "namespace", "new", "operator", "out", "override", "params", "partial",
			"private", "protected", "public", "readonly", "record", "ref", "required", "return", "sealed",
			"sizeof", "stackalloc", "static", "struct", "switch", "this", "throw", "try", "typeof",
			"unchecked", "unsafe", "using", "var", "virtual", "volatile", "when", "where", "while", "yield",
		},
		types = {
			"bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "nint", "nuint",
			"object", "sbyte", "short", "string", "uint", "ulong", "ushort", "void",
		},
		constants = {"true", "false", "null"},
	},
	.Java = {
		keywords = {
			"abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default", "do",
			"else", "enum", "extends", "final", "finally", "for", "goto", "if", "implements", "import",
			"instanceof", "interface", "native", "new", "package", "permits", "private", "protected",
			"public", "record", "return", "sealed", "static", "strictfp", "super", "switch",
			"synchronized", "this", "throw", "throws", "transient", "try", "var", "volatile", "while",
			"yield",
		},
		types = {"boolean", "byte", "char", "double", "float", "int", "long", "short", "void"},
		constants = {"true", "false", "null"},
	},
	.JavaScript = {
		keywords = {
			"as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
			"default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function",
			"if", "import", "in", "instanceof", "let", "new", "of", "return", "static", "super", "switch",
			"this", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
		},
		constants = {"true", "false", "null", "undefined", "NaN", "Infinity"},
	},
	.TypeScript = {
		keywords = {
			"abstract", "as", "asserts", "async", "await", "break", "case", "catch", "class", "const",
			"continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export",
			"extends", "finally", "for", "from", "function", "if", "implements", "import", "in", "infer",
			"instanceof", "interface", "is", "keyof", "let", "module", "namespace", "new", "of", "override",
			"private", "protected", "public", "readonly", "return", "satisfies", "static", "super",
			"switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "with", "yield",
		},
		types = {"any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown"},
		constants = {"true", "false", "null", "undefined", "NaN", "Infinity"},
	},
	.Go = {
		keywords = {
			"break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for",
			"func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return",
			"select", "struct", "switch", "type", "var",
		},
		types = {
			"any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64",
			"int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32",
			"uint64", "uintptr",
		},
		constants = {"true", "false", "nil", "iota"},
	},
	.Rust = {
		keywords = {
			"as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
			"fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
			"return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use",
			"where", "while", "yield",
		},
		types = {
			"bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8", "u16",
			"u32", "u64", "u128", "usize",
		},
		constants = {"true", "false", "None"},
	},
}

// Languages that write types in Ada_Case or PascalCase, so a capitalised identifier names a type.
@(private="file")
CAPITAL_TYPES :: bit_set[Language]{.Odin, .CSharp, .Java, .JavaScript, .TypeScript, .Tsx, .Rust}
@(private="file")
SCRIPT_LANGUAGES :: bit_set[Language]{.JavaScript, .TypeScript, .Tsx}
// .jsx files are JavaScript; plain TypeScript keeps `<T>value` casts, so it has no JSX.
@(private="file")
JSX_LANGUAGES :: bit_set[Language]{.JavaScript, .Tsx}
@(private="file")
PREPROCESSED_LANGUAGES :: bit_set[Language]{.C, .Cpp, .CSharp}
// Languages where '$' is an identifier letter.
@(private="file")
DOLLAR_LANGUAGES :: bit_set[Language]{.JavaScript, .TypeScript, .Tsx, .Java}

@(private="file")
C_Lexer :: struct {
	text:     string,
	out:      ^[dynamic]Token,
	language: Language,
	words:    Words,
	dollar:   bool,
	// The last token ends a value, so '/' divides and '<' compares rather than starting a regular
	// expression or a JSX tag.
	value:    bool,
	// A regular expression search found no end before this offset; searching again before it could
	// only fail the same way, and would make a line of slashes quadratic.
	no_regex: int,
}

// Odin, C, C++, C#, Java, JavaScript, TypeScript, TSX, Go and Rust: one scanner whose comment, string
// and attribute forms each language switches on. Every branch moves forward by at least one byte and
// every inner search moves forward too, so the scan is linear and stops on any input.
@(require_results)
lex_c_family :: proc(language: Language, text: string, out: ^[dynamic]Token) -> bool {
	l := C_Lexer {
		text     = text,
		out      = out,
		language = language,
		words    = C_WORDS[language == .Tsx ? .TypeScript : language],
		dollar   = language in DOLLAR_LANGUAGES,
	}
	i := 0
	for i < len(text) {
		c := text[i]
		next := i + 1 < len(text) ? text[i + 1] : 0
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i += 1
		case c == '/' && next == '/':
			end := line_end(text, i)
			emit(&l, i, end, .Comment) or_return
			i = end
		case c == '/' && next == '*':
			end := block_comment_end(text, i + 2, language == .Odin || language == .Rust)
			emit(&l, i, end, .Comment) or_return
			i = end
		case is_digit(c) || c == '.' && is_digit(next) && !l.value:
			i = token(&l, i, number_end(text, i, language), .Number) or_return
		case is_identifier_start(c) || c == '$' && l.dollar:
			i = identifier(&l, i) or_return
		case:
			i = punctuation(&l, i) or_return
		}
	}
	return true
}

@(private="file", require_results)
emit :: proc(l: ^C_Lexer, start, end: int, kind: Token_Kind) -> bool {
	if kind == .Plain || end <= start {return true}
	_, err := append(l.out, Token{u32(start), u32(end), kind})
	return err == nil
}

// Emits a token that ends a value and returns where scanning goes on.
@(private="file", require_results)
token :: proc(l: ^C_Lexer, start, end: int, kind: Token_Kind) -> (int, bool) {
	l.value = true
	return end, emit(l, start, end, kind)
}

@(private="file", require_results)
identifier :: proc(l: ^C_Lexer, start: int) -> (int, bool) {
	text := l.text
	end := identifier_end(text, start, l.dollar)
	word := text[start:end]
	after := end < len(text) ? text[end] : 0
	#partial switch l.language {
	case .Rust:
		if after == '"' || after == '#' {
			if word == "r" || word == "br" || word == "cr" {
				hashes := 0
				for end + hashes < len(text) && text[end + hashes] == '#' {hashes += 1}
				if end + hashes < len(text) && text[end + hashes] == '"' {
					return token(l, start, rust_raw_end(text, end + hashes + 1, hashes), .String)
				}
				if word == "r" && hashes == 1 && end + 1 < len(text) && is_identifier_start(text[end + 1]) {
					l.value = true
					return identifier_end(text, end + 1, false), true
				}
			}
			if after == '"' && (word == "b" || word == "c") {
				return token(l, start, quoted_end(text, end, '"', true), .String)
			}
		}
		if after == '\'' && word == "b" {return token(l, start, quoted_end(text, end, '\'', false), .String)}
	case .C, .Cpp:
		if (after == '"' || after == '\'') && (word == "L" || word == "u" || word == "U" || word == "u8") {
			return token(l, start, quoted_end(text, end, after, false), .String)
		}
		if after == '"' && l.language == .Cpp &&
		   (word == "R" || word == "LR" || word == "uR" || word == "UR" || word == "u8R") {
			if raw_end, ok := cpp_raw_end(text, end + 1); ok {return token(l, start, raw_end, .String)}
		}
	}
	member := start > 0 && text[start - 1] == '.'
	if !member && len(word) <= WORD_LIMIT {
		if contains(l.words.keywords, word) {
			l.value = word == "this" || word == "self" || word == "super" || word == "Self"
			return end, emit(l, start, end, .Keyword)
		}
		if contains(l.words.constants, word) {return token(l, start, end, .Constant)}
		if contains(l.words.types, word) {return token(l, start, end, .Type)}
	}
	if after == '(' {return token(l, start, end, .Function)}
	if l.language == .Rust && after == '!' && (end + 1 >= len(text) || text[end + 1] != '=') {
		return token(l, start, end, .Function)
	}
	if l.language in CAPITAL_TYPES && 'A' <= word[0] && word[0] <= 'Z' {
		return token(l, start, end, capital_kind(word))
	}
	return token(l, start, end, .Plain)
}

// A capitalised word is a type, but an all-capitals one of two or more letters is a constant.
@(private="file", require_results)
capital_kind :: proc(word: string) -> Token_Kind {
	if len(word) == 1 {return .Type}
	for c in transmute([]u8)word {
		if 'a' <= c && c <= 'z' {return .Type}
	}
	return .Constant
}

@(private="file", require_results)
punctuation :: proc(l: ^C_Lexer, start: int) -> (int, bool) {
	text := l.text
	c := text[start]
	next := start + 1 < len(text) ? text[start + 1] : 0
	switch c {
	case '"':
		if (l.language == .Java || l.language == .CSharp) && strings.has_prefix(text[start:], `"""`) {
			return token(l, start, fence_end(text, start + 3, `"""`, l.language == .Java), .String)
		}
		return token(l, start, quoted_end(text, start, '"', l.language == .Rust), .String)
	case '\'':
		if l.language == .Rust {return rust_quote(l, start)}
		return token(l, start, quoted_end(text, start, '\'', false), .String)
	case '`':
		if l.language == .Odin || l.language == .Go {
			return token(l, start, fence_end(text, start + 1, "`", false), .String)
		}
		if l.language in SCRIPT_LANGUAGES {
			return token(l, start, fence_end(text, start + 1, "`", true), .String)
		}
	case '#':
		return hash(l, start)
	case '@':
		return at(l, start)
	case '$':
		if l.language == .CSharp {
			quote := start + 1
			for quote < len(text) && text[quote] == '$' {quote += 1}
			if strings.has_prefix(text[quote:], `"""`) {
				return token(l, start, fence_end(text, quote + 3, `"""`, false), .String)
			}
			if strings.has_prefix(text[quote:], `@"`) {
				return token(l, start, verbatim_end(text, quote + 2), .String)
			}
			if quote < len(text) && text[quote] == '"' {
				return token(l, start, quoted_end(text, quote, '"', false), .String)
			}
			// Skipping the whole run keeps the next '$' from scanning it again.
			l.value = false
			return quote, true
		}
		if l.language == .Odin && is_identifier_start(next) {
			return token(l, start, identifier_end(text, start + 1, false), .Type)
		}
	case '/':
		if l.language in SCRIPT_LANGUAGES && !l.value && start >= l.no_regex {
			end, ok := regex_end(text, start + 1)
			if ok {return token(l, start, end, .String)}
			l.no_regex = end
		}
	case '<':
		// A closing tag usually follows text or a `{…}` child, which read as values.
		if l.language in JSX_LANGUAGES && (next == '/' || !l.value && is_identifier_start(next)) {
			name := next == '/' ? start + 2 : start + 1
			end := tag_name_end(text, name)
			if end > name {
				l.value = false
				return end, emit(l, start, end, .Tag)
			}
		}
	case ')', ']', '}':
		l.value = true
		return start + 1, true
	}
	l.value = false
	return start + 1, true
}

// A Rust quote starts a char literal, `'x'` or `'\n'`, or a lifetime, `'a`, which has no closing quote.
@(private="file", require_results)
rust_quote :: proc(l: ^C_Lexer, start: int) -> (int, bool) {
	text := l.text
	if start + 1 < len(text) && text[start + 1] == '\\' {
		return token(l, start, quoted_end(text, start, '\'', false), .String)
	}
	if start + 1 < len(text) {
		lead := text[start + 1]
		close := start + 1 + utf8_width(lead)
		if close < len(text) && text[close] == '\'' {return token(l, start, close + 1, .String)}
		if is_identifier_start(lead) {return token(l, start, identifier_end(text, start + 1, false), .Plain)}
	}
	l.value = false
	return start + 1, true
}

@(private="file", require_results)
hash :: proc(l: ^C_Lexer, start: int) -> (int, bool) {
	text := l.text
	next := start + 1 < len(text) ? text[start + 1] : 0
	if l.language in PREPROCESSED_LANGUAGES && at_line_start(text, start) {
		name := start + 1
		for name < len(text) && (text[name] == ' ' || text[name] == '\t') {name += 1}
		end := identifier_end(text, name, false)
		if !emit(l, start, end, .Keyword) {return end, false}
		l.value = false
		directive := text[name:end]
		if directive != "include" && directive != "import" {return end, true}
		path := end
		for path < len(text) && (text[path] == ' ' || text[path] == '\t') {path += 1}
		if path >= len(text) || text[path] != '<' {return end, true}
		path_line_end := line_end(text, path)
		close := strings.index_byte(text[path:path_line_end], '>')
		path_end := close < 0 ? path_line_end : path + close + 1
		return path_end, emit(l, path, path_end, .String)
	}
	if l.language == .Odin {
		name := next == '+' ? start + 2 : start + 1
		if name < len(text) && is_identifier_start(text[name]) {
			end := identifier_end(text, name, false)
			l.value = false
			return end, emit(l, start, end, .Keyword)
		}
	}
	if l.language == .Rust {
		open := next == '!' ? start + 2 : start + 1
		if open < len(text) && text[open] == '[' {
			end := bracket_end(text, open, '[', ']')
			l.value = false
			return end, emit(l, start, end, .Attribute)
		}
	}
	l.value = false
	return start + 1, true
}

@(private="file", require_results)
at :: proc(l: ^C_Lexer, start: int) -> (int, bool) {
	text := l.text
	next := start + 1 < len(text) ? text[start + 1] : 0
	#partial switch l.language {
	case .Odin:
		if next == '(' {
			end := bracket_end(text, start + 1, '(', ')')
			l.value = false
			return end, emit(l, start, end, .Attribute)
		}
		if is_identifier_start(next) {
			end := identifier_end(text, start + 1, false)
			l.value = false
			return end, emit(l, start, end, .Attribute)
		}
	case .Java, .JavaScript, .TypeScript, .Tsx:
		if is_identifier_start(next) {
			end := identifier_end(text, start + 1, true)
			for end + 1 < len(text) && text[end] == '.' && is_identifier_start(text[end + 1]) {
				end = identifier_end(text, end + 1, true)
			}
			l.value = false
			return end, emit(l, start, end, .Attribute)
		}
	case .CSharp:
		if next == '"' {return token(l, start, verbatim_end(text, start + 2), .String)}
		if next == '$' && start + 2 < len(text) && text[start + 2] == '"' {
			return token(l, start, verbatim_end(text, start + 3), .String)
		}
		// @class is an identifier spelled like a keyword.
		if is_identifier_start(next) {return token(l, start, identifier_end(text, start + 1, false), .Plain)}
	}
	l.value = false
	return start + 1, true
}

@(private="file", require_results)
is_digit :: proc(c: u8) -> bool {
	return '0' <= c && c <= '9'
}

// Bytes from 0x80 up are UTF-8 letters as far as highlighting cares.
@(private="file", require_results)
is_identifier_start :: proc(c: u8) -> bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || c == '_' || c >= 0x80
}

@(private="file", require_results)
identifier_end :: proc(text: string, start: int, dollar: bool) -> int {
	i := start
	for i < len(text) {
		c := text[i]
		if !is_identifier_start(c) && !is_digit(c) && !(dollar && c == '$') {break}
		i += 1
	}
	return i
}

@(private="file", require_results)
contains :: proc(words: []string, word: string) -> bool {
	for candidate in words {
		if candidate == word {return true}
	}
	return false
}

// Digits, letters for prefixes, suffixes and hex digits, `_` and C++ `'` separators, one fraction and a
// signed exponent. A '.' followed by another '.' is a range, so `0..<n` stops before it.
@(private="file", require_results)
number_end :: proc(text: string, start: int, language: Language) -> int {
	hex := start + 1 < len(text) && text[start] == '0' && (text[start + 1] == 'x' || text[start + 1] == 'X')
	fraction := false
	i := start
	for i < len(text) {
		c := text[i]
		next := i + 1 < len(text) ? text[i + 1] : 0
		switch {
		case (c == 'e' || c == 'E') && !hex || (c == 'p' || c == 'P') && hex:
			i += next == '+' || next == '-' ? 2 : 1
		case is_identifier_start(c) && c < 0x80 || is_digit(c):
			i += 1
		case c == '.' && !fraction && is_digit(next):
			fraction = true
			i += 1
		case c == '\'' && language == .Cpp && (is_digit(next) || is_identifier_start(next) && next < 0x80):
			i += 1
		case:
			return i
		}
	}
	return len(text)
}

// The end of a quoted string or char that starts at `start`. A backslash escapes the next byte, a line
// break included; an unescaped line break ends an unterminated literal unless the language's strings
// span lines.
@(private="file", require_results)
quoted_end :: proc(text: string, start: int, quote: u8, multiline: bool) -> int {
	i := start + 1
	for i < len(text) {
		c := text[i]
		if c == '\\' {
			i += 1
			if i + 1 < len(text) && text[i] == '\r' && text[i + 1] == '\n' {i += 1}
			i += 1
			continue
		}
		if c == quote {return i + 1}
		if c == '\n' && !multiline {return i}
		i += 1
	}
	return len(text)
}

// The end of text closed by `fence`, searched from `start`; with `escapes` a backslash skips a byte.
@(private="file", require_results)
fence_end :: proc(text: string, start: int, fence: string, escapes: bool) -> int {
	i := start
	for i < len(text) {
		if escapes && text[i] == '\\' {
			i += 2
			continue
		}
		if strings.has_prefix(text[i:], fence) {return i + len(fence)}
		i += 1
	}
	return len(text)
}

// C# verbatim strings, `@"…"`, span lines and escape a quote by doubling it.
@(private="file", require_results)
verbatim_end :: proc(text: string, start: int) -> int {
	i := start
	for i < len(text) {
		if text[i] == '"' {
			if i + 1 < len(text) && text[i + 1] == '"' {
				i += 2
				continue
			}
			return i + 1
		}
		i += 1
	}
	return len(text)
}

@(private="file", require_results)
block_comment_end :: proc(text: string, start: int, nested: bool) -> int {
	depth := 1
	i := start
	for i + 1 < len(text) {
		if text[i] == '*' && text[i + 1] == '/' {
			depth -= 1
			i += 2
			if depth == 0 {return i}
		} else if nested && text[i] == '/' && text[i + 1] == '*' {
			depth += 1
			i += 2
		} else {
			i += 1
		}
	}
	return len(text)
}

// Closes on `"` followed by `hashes` '#'. Each check reads only the '#' run after its quote, so the
// search stays linear.
@(private="file", require_results)
rust_raw_end :: proc(text: string, start: int, hashes: int) -> int {
	i := start
	for i < len(text) {
		if text[i] == '"' {
			run := 0
			for run < hashes && i + 1 + run < len(text) && text[i + 1 + run] == '#' {run += 1}
			if run == hashes {return i + 1 + hashes}
		}
		i += 1
	}
	return len(text)
}

// `start` is just after the opening quote of `R"delim(…)delim"`. Not ok when no valid delimiter and
// '(' follow, so the prefix and quote lex as an identifier and an ordinary string.
@(private="file", require_results)
cpp_raw_end :: proc(text: string, start: int) -> (end: int, ok: bool) {
	open := start
	for open < len(text) && open - start <= RAW_DELIMITER_LIMIT {
		c := text[open]
		if c == '(' {break}
		if c == ')' || c == '\\' || c == '"' || c == ' ' || c == '\t' || c == '\n' || c == '\r' {return}
		open += 1
	}
	if open >= len(text) || text[open] != '(' {return}
	delimiter := text[start:open]
	i := open + 1
	for i < len(text) {
		if text[i] == ')' && strings.has_prefix(text[i + 1:], delimiter) {
			close := i + 1 + len(delimiter)
			if close < len(text) && text[close] == '"' {return close + 1, true}
		}
		i += 1
	}
	return len(text), true
}

// Depth-counted brackets from the opener at `start`, skipping one-line strings inside; an unclosed
// attribute runs to the end of the text.
@(private="file", require_results)
line_end :: proc(text: string, start: int) -> int {
	at := strings.index_byte(text[start:], '\n')
	return at < 0 ? len(text) : start + at
}

@(private="file", require_results)
bracket_end :: proc(text: string, start: int, open, close: u8) -> int {
	depth := 0
	i := start
	for i < len(text) {
		c := text[i]
		if c == '"' {
			i = quoted_end(text, i, '"', false)
			continue
		}
		if c == open {
			depth += 1
		} else if c == close {
			depth -= 1
			if depth == 0 {return i + 1}
		}
		i += 1
	}
	return len(text)
}

// `start` is just after the opening '/'. A regular expression ends at an unescaped '/' outside a
// character class, then its flags; one that reaches the end of its line is not one, and `end` is
// where the search stopped.
@(private="file", require_results)
regex_end :: proc(text: string, start: int) -> (end: int, ok: bool) {
	class := false
	i := start
	for i < len(text) {
		c := text[i]
		switch {
		case c == '\n':
			return i, false
		case c == '\\':
			if i + 1 < len(text) && text[i + 1] == '\n' {return i + 1, false}
			i += 2
			continue
		case c == '[':
			class = true
		case c == ']':
			class = false
		case c == '/' && !class:
			i += 1
			for i < len(text) && ('a' <= text[i] && text[i] <= 'z') {i += 1}
			return i, true
		}
		i += 1
	}
	return len(text), false
}

@(private="file", require_results)
tag_name_end :: proc(text: string, start: int) -> int {
	if start >= len(text) || !is_identifier_start(text[start]) {return start}
	i := start
	for i < len(text) {
		c := text[i]
		if !is_identifier_start(c) && !is_digit(c) && c != '.' && c != ':' && c != '-' {break}
		i += 1
	}
	return i
}

// Only blanks precede `at` on its line. The backward scan stops at the first other byte, so the bytes
// it reads lie between this '#' and the previous token and the whole lex stays linear.
@(private="file", require_results)
at_line_start :: proc(text: string, at: int) -> bool {
	i := at - 1
	for i >= 0 && (text[i] == ' ' || text[i] == '\t') {i -= 1}
	return i < 0 || text[i] == '\n'
}

@(private="file", require_results)
utf8_width :: proc(lead: u8) -> int {
	switch {
	case lead < 0xc0:
		return 1
	case lead < 0xe0:
		return 2
	case lead < 0xf0:
		return 3
	}
	return 4
}
