package syntax_test

import "aio:syntax"
import "core:strings"
import "core:testing"

@(private)
Expect :: struct {
	word: string,
	kind: syntax.Token_Kind,
}

// The kind of the span over byte `column` of line `line`; .Plain where no span covers it.
@(private)
kind_at :: proc(file: syntax.File_Lines, line, column: int) -> syntax.Token_Kind {
	if line >= len(file.lines) {return .Plain}
	for span in file.lines[line] {
		if int(span.start) <= column && column < int(span.end) {return span.kind}
	}
	return .Plain
}

// Highlights `source` and checks that every byte of each word, searched in order after the previous
// one, has the word's kind. A word may span lines; its line breaks are not checked.
@(private)
expect_kinds :: proc(
	t: ^testing.T,
	language: syntax.Language,
	source: string,
	expects: []Expect,
	loc := #caller_location,
) {
	file, ok := syntax.highlight(language, source)
	if !testing.expect(t, ok, "highlight failed", loc = loc) {return}
	defer syntax.file_lines_destroy(&file)
	expect_valid_spans(t, file, source, loc)
	from := 0
	for e in expects {
		found := strings.index(source[from:], e.word)
		if !testing.expectf(t, found >= 0, "%q not found", e.word, loc = loc) {return}
		start := from + found
		from = start + len(e.word)
		line := strings.count(source[:start], "\n")
		line_start := strings.last_index_byte(source[:start], '\n') + 1
		bytes: for offset in start ..< from {
			switch source[offset] {
			case '\n':
				line += 1
				line_start = offset + 1
			case '\r':
			case:
				kind := kind_at(file, line, offset - line_start)
				if !testing.expectf(t, kind == e.kind, "%q: byte %d is %v, want %v", e.word, offset - start,
					kind, e.kind, loc = loc) {break bytes}
			}
		}
	}
}

// One line per '\n', plus a last line without one; spans sorted, disjoint, non-empty, not Plain and
// inside their line's text, which excludes a '\r' before the '\n'.
@(private)
expect_valid_spans :: proc(t: ^testing.T, file: syntax.File_Lines, source: string, loc := #caller_location) {
	line_count := strings.count(source, "\n")
	if len(source) > 0 && source[len(source) - 1] != '\n' {line_count += 1}
	if !testing.expect_value(t, len(file.lines), line_count, loc = loc) {return}
	rest := source
	for spans, index in file.lines {
		end := strings.index_byte(rest, '\n')
		text := end < 0 ? rest : rest[:end]
		if end >= 0 && len(text) > 0 && text[len(text) - 1] == '\r' {text = text[:len(text) - 1]}
		rest = end < 0 ? "" : rest[end + 1:]
		previous := u32(0)
		for span in spans {
			valid := previous <= span.start && span.start < span.end && int(span.end) <= len(text) &&
				span.kind != .Plain
			if !testing.expectf(t, valid, "line %d: bad span %v after %d (length %d)", index, span, previous,
				len(text), loc = loc) {return}
			previous = span.end
		}
	}
}

@(private)
Rng :: struct {
	state: u64,
}

@(private)
rng_next :: proc(r: ^Rng) -> u64 {
	x := r.state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.state = x
	return x
}

// Bytes weighted toward the ones that open and close constructs, so random text keeps starting
// strings, comments and attributes it never finishes.
@(private)
FUZZ_BYTES :: "\"'`/*#@$\\\n\r\t {}()[]<>=-+:;,.!?&|%~^_rRbBuLx0123456789eE aZ\x80\xc3\xe2\xf0"

@(private)
fuzz_text :: proc(r: ^Rng, buffer: []u8) -> string {
	alphabet := FUZZ_BYTES
	length := int(rng_next(r) % u64(len(buffer) + 1))
	for i in 0 ..< length {
		pick := rng_next(r)
		buffer[i] = pick % 8 == 0 ? u8(pick >> 8) : alphabet[(pick >> 8) % u64(len(alphabet))]
	}
	return string(buffer[:length])
}

@(test)
language_for_path_matches_extensions_ignoring_case :: proc(t: ^testing.T) {
	Case :: struct {
		path:     string,
		language: syntax.Language,
	}
	cases := [?]Case {
		{"src/syntax/syntax.odin", .Odin},
		{"C:\\work\\main.C", .C},
		{"include/a.h", .C},
		{"x.Hpp", .Cpp},
		{"x.cc", .Cpp},
		{"Program.cs", .CSharp},
		{"Main.java", .Java},
		{"app.mjs", .JavaScript},
		{"view.jsx", .JavaScript},
		{"lib.cts", .TypeScript},
		{"page.TSX", .Tsx},
		{"main.go", .Go},
		{"lib.rs", .Rust},
		{"tool.pyw", .Python},
		{"init.lua", .Lua},
		{"run.zsh", .Shell},
		{"build.psm1", .PowerShell},
		{"settings.jsonc", .Json},
		{"Cargo.toml", .Toml},
		{"ci.yml", .Yaml},
		{"icon.svg", .Html},
		{"site.scss", .Css},
		{"README.markdown", .Markdown},
		{"Makefile", .None},
		{".bashrc", .None},
		{"archive.tar.gz", .None},
		{"dir.rs/LICENSE", .None},
		{"trailing.", .None},
		{"", .None},
	}
	for c in cases {
		testing.expectf(t, syntax.language_for_path(c.path) == c.language, "%q", c.path)
	}
}

@(test)
highlight_refuses_what_it_cannot_colour :: proc(t: ^testing.T) {
	_, plain := syntax.highlight(.None, "x := 1")
	testing.expect(t, !plain)
	large := strings.repeat("a", syntax.HIGHLIGHT_LIMIT + 1)
	defer delete(large)
	_, too_large := syntax.highlight(.Odin, large)
	testing.expect(t, !too_large)
	binary := "x := 1\x00"
	_, nul := syntax.highlight(.Odin, binary)
	testing.expect(t, !nul)
	late := strings.concatenate({strings.repeat("a", 8 * 1024, context.temp_allocator), "\x00"})
	defer delete(late)
	file, ok := syntax.highlight(.Odin, late)
	testing.expect(t, ok)
	syntax.file_lines_destroy(&file)
}

@(test)
lines_follow_line_breaks :: proc(t: ^testing.T) {
	Case :: struct {
		source: string,
		lines:  int,
	}
	cases := [?]Case{{"", 0}, {"a", 1}, {"a\n", 1}, {"a\nb", 2}, {"\n\n", 2}, {"a\r\n\r\nb\r\n", 3}}
	for c in cases {
		file, ok := syntax.highlight(.Odin, c.source)
		testing.expect(t, ok)
		testing.expectf(t, len(file.lines) == c.lines, "%q: %d lines", c.source, len(file.lines))
		syntax.file_lines_destroy(&file)
	}
}

@(test)
crlf_line_breaks_stay_out_of_spans :: proc(t: ^testing.T) {
	source := "// note\r\nx := \"a\"\r\n/* one\r\ntwo */\r\n"
	file, ok := syntax.highlight(.Odin, source)
	if !testing.expect(t, ok) {return}
	defer syntax.file_lines_destroy(&file)
	expect_valid_spans(t, file, source)
	testing.expect_value(t, len(file.lines), 4)
	testing.expect_value(t, file.lines[0][0], syntax.Span{0, 7, .Comment})
	testing.expect_value(t, file.lines[1][0], syntax.Span{5, 8, .String})
	testing.expect_value(t, file.lines[2][0], syntax.Span{0, 6, .Comment})
	testing.expect_value(t, file.lines[3][0], syntax.Span{0, 6, .Comment})
}

@(test)
a_token_over_several_lines_gets_a_span_on_each :: proc(t: ^testing.T) {
	source := "a /* one\n\ntwo\n */ b"
	file, ok := syntax.highlight(.C, source)
	if !testing.expect(t, ok) {return}
	defer syntax.file_lines_destroy(&file)
	expect_valid_spans(t, file, source)
	testing.expect_value(t, len(file.lines), 4)
	testing.expect_value(t, len(file.lines[0]), 1)
	testing.expect_value(t, file.lines[0][0], syntax.Span{2, 8, .Comment})
	// An empty line inside the comment has nothing to colour.
	testing.expect_value(t, len(file.lines[1]), 0)
	testing.expect_value(t, file.lines[2][0], syntax.Span{0, 3, .Comment})
	testing.expect_value(t, file.lines[3][0], syntax.Span{0, 3, .Comment})
	testing.expect_value(t, len(file.lines[3]), 1)
}

@(test)
highlight_keeps_the_result_in_the_given_allocator :: proc(t: ^testing.T) {
	file, ok := syntax.highlight(.Go, "func main() {\n\treturn\n}\n", context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, len(file.lines), 3)
	testing.expect_value(t, file.lines[0][0], syntax.Span{0, 4, .Keyword})
	syntax.file_lines_destroy(&file, context.temp_allocator)
	testing.expect(t, file.lines == nil)
}

// Every language survives random text: highlight returns and its spans stay well formed.
@(test)
highlight_survives_random_text_in_every_language :: proc(t: ^testing.T) {
	r := Rng{0x9e3779b97f4a7c15}
	buffer: [512]u8
	for language in syntax.Language {
		if language == .None {continue}
		for _ in 0 ..< 200 {
			source := fuzz_text(&r, buffer[:])
			file, ok := syntax.highlight(language, source)
			if !ok {
				testing.expectf(t, strings.index_byte(source, 0) >= 0, "%v refused %q", language, source)
				continue
			}
			expect_valid_spans(t, file, source)
			syntax.file_lines_destroy(&file)
		}
	}
}
