package syntax

import "base:runtime"
import "core:strings"

// A file with a NUL byte this early is binary, not source.
@(private="file")
BINARY_PROBE :: 8 * 1024

@(private="file")
Extension :: struct {
	name:     string,
	language: Language,
}

@(private="file", rodata)
EXTENSIONS := [?]Extension {
	{"odin", .Odin},
	{"c", .C},
	{"h", .C},
	{"cpp", .Cpp},
	{"cc", .Cpp},
	{"cxx", .Cpp},
	{"hpp", .Cpp},
	{"hh", .Cpp},
	{"hxx", .Cpp},
	{"cs", .CSharp},
	{"java", .Java},
	{"js", .JavaScript},
	{"mjs", .JavaScript},
	{"cjs", .JavaScript},
	{"jsx", .JavaScript},
	{"ts", .TypeScript},
	{"mts", .TypeScript},
	{"cts", .TypeScript},
	{"tsx", .Tsx},
	{"go", .Go},
	{"rs", .Rust},
	{"py", .Python},
	{"pyw", .Python},
	{"lua", .Lua},
	{"sh", .Shell},
	{"bash", .Shell},
	{"zsh", .Shell},
	{"ps1", .PowerShell},
	{"psm1", .PowerShell},
	{"psd1", .PowerShell},
	{"json", .Json},
	{"jsonc", .Json},
	{"toml", .Toml},
	{"yml", .Yaml},
	{"yaml", .Yaml},
	{"html", .Html},
	{"htm", .Html},
	{"xml", .Html},
	{"svg", .Html},
	{"css", .Css},
	{"scss", .Css},
	{"md", .Markdown},
	{"markdown", .Markdown},
}

// By the extension of the path's last element, ignoring case. A name without an extension, such as
// Makefile, and a dot file, such as .bashrc, are .None.
@(require_results)
language_for_path :: proc(path: string) -> Language {
	name := path[strings.last_index_any(path, "/\\") + 1:]
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 {return .None}
	extension := name[dot + 1:]
	for entry in EXTENSIONS {
		if strings.equal_fold(extension, entry.name) {return entry.language}
	}
	return .None
}

@(private="file", require_results)
lexer_for :: proc(language: Language) -> Lexer {
	switch language {
	case .None:
		return nil
	case .Odin, .C, .Cpp, .CSharp, .Java, .JavaScript, .TypeScript, .Tsx, .Go, .Rust:
		return lex_c_family
	case .Python:
		return lex_python
	case .Lua:
		return lex_lua
	case .Shell:
		return lex_shell
	case .PowerShell:
		return lex_powershell
	case .Json:
		return lex_json
	case .Toml:
		return lex_toml
	case .Yaml:
		return lex_yaml
	case .Html:
		return lex_html
	case .Css:
		return lex_css
	case .Markdown:
		return lex_markdown
	}
	return nil
}

// Lexes `text` with the language's lexer and splits the tokens into per-line spans. ok = false for
// .None, text longer than HIGHLIGHT_LIMIT, text with a NUL byte in its first 8 KiB, or out of memory.
// Lines split on '\n'; a '\r' before it is not part of the line. A final line break ends the last line
// rather than starting an empty one. Every string the result needs is in `allocator`.
@(require_results)
highlight :: proc(
	language: Language,
	text: string,
	allocator := context.allocator,
) -> (
	file: File_Lines,
	ok: bool,
) {
	lexer := lexer_for(language)
	if lexer == nil || len(text) > HIGHLIGHT_LIMIT {return}
	if strings.index_byte(text[:min(len(text), BINARY_PROBE)], 0) >= 0 {return}
	// The tokens are scratch whatever the caller's allocator is, so an arena result does not keep them.
	tokens := make([dynamic]Token, runtime.heap_allocator())
	defer delete(tokens)
	if !lexer(language, text, &tokens) {return}
	line_count := strings.count(text, "\n")
	if len(text) > 0 && text[len(text) - 1] != '\n' {line_count += 1}
	if line_count == 0 {return {}, true}
	splitter := Splitter{text = text, tokens = tokens[:]}
	total := split(&splitter)
	lines, lines_error := make([][]Span, line_count, allocator)
	if lines_error != nil {return}
	if total > 0 {
		spans, spans_error := make([]Span, total, allocator)
		if spans_error != nil {
			delete(lines, allocator)
			return
		}
		splitter = Splitter{text = text, tokens = tokens[:], lines = lines, spans = spans}
		split(&splitter)
	}
	return File_Lines{lines}, true
}

// Frees what highlight allocated: the line table and the one span array the lines slice.
file_lines_destroy :: proc(file: ^File_Lines, allocator := context.allocator) {
	total := 0
	for line in file.lines {total += len(line)}
	if total > 0 {delete(([^]Span)(raw_data(file.lines[0]))[:total], allocator)}
	delete(file.lines, allocator)
	file.lines = nil
}

// Walks the tokens line by line. Without `spans` it only counts the spans; with them it fills `spans`
// in order and points each of `lines` at its part. Out-of-order, overlapping and out-of-range tokens
// are clipped, so a faulty lexer cannot break the result's ordering.
@(private="file")
Splitter :: struct {
	text:       string,
	tokens:     []Token,
	lines:      [][]Span,
	spans:      []Span,
	line:       int,
	line_start: int,
	// The line's '\n', or len(text) for a last line without one.
	line_end:   int,
	first:      int,
	count:      int,
}

@(private="file")
split :: proc(s: ^Splitter) -> int {
	s.line_end = line_end_from(s.text, 0)
	clip := 0
	for token in s.tokens {
		start := max(int(token.start), clip)
		end := min(int(token.end), len(s.text))
		if token.kind == .Plain || start >= end {continue}
		clip = end
		for start < end {
			// start < end <= len(text), so a line follows any line break start is past.
			for start > s.line_end {next_line(s)}
			content_end := s.line_end
			if s.line_end < len(s.text) && content_end > s.line_start && s.text[content_end - 1] == '\r' {
				content_end -= 1
			}
			piece_end := min(end, content_end)
			if piece_end > start {
				if s.spans != nil {
					s.spans[s.count] = {u32(start - s.line_start), u32(piece_end - s.line_start), token.kind}
				}
				s.count += 1
			}
			start = end <= s.line_end ? end : s.line_end + 1
		}
	}
	if s.spans != nil {
		for s.line + 1 < len(s.lines) {next_line(s)}
		s.lines[s.line] = s.spans[s.first:s.count]
	}
	return s.count
}

@(private="file")
next_line :: proc(s: ^Splitter) {
	if s.spans != nil {
		s.lines[s.line] = s.spans[s.first:s.count]
		s.first = s.count
	}
	s.line += 1
	s.line_start = s.line_end + 1
	s.line_end = line_end_from(s.text, s.line_start)
}

@(private="file", require_results)
line_end_from :: proc(text: string, start: int) -> int {
	if start >= len(text) {return len(text)}
	at := strings.index_byte(text[start:], '\n')
	return at < 0 ? len(text) : start + at
}
