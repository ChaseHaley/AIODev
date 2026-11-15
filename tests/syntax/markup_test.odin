package syntax_test

import "core:strings"
import "core:testing"
import "aio:syntax"

@(private="file")
lex :: proc(t: ^testing.T, lexer: syntax.Lexer, language: syntax.Language, text: string) -> []syntax.Token {
	tokens := make([dynamic]syntax.Token, context.temp_allocator)
	testing.expect(t, lexer(language, text, &tokens))
	return tokens[:]
}

// The first occurrence of `needle` is exactly one token of `kind`.
@(private="file")
expect_token :: proc(
	t: ^testing.T,
	tokens: []syntax.Token,
	text, needle: string,
	kind: syntax.Token_Kind,
	loc := #caller_location,
) {
	start := strings.index(text, needle)
	if start < 0 {
		testing.expectf(t, false, "%q is not in the text", needle, loc = loc)
		return
	}
	for token in tokens {
		if int(token.start) == start && int(token.end) == start + len(needle) {
			testing.expectf(t, token.kind == kind, "%q is %v, want %v", needle, token.kind, kind, loc = loc)
			return
		}
	}
	testing.expectf(t, false, "no token spans %q", needle, loc = loc)
}

// No token touches the first occurrence of `needle`.
@(private="file")
expect_plain :: proc(t: ^testing.T, tokens: []syntax.Token, text, needle: string, loc := #caller_location) {
	start := strings.index(text, needle)
	testing.expectf(t, start >= 0, "%q is not in the text", needle, loc = loc)
	for token in tokens {
		if int(token.start) < start + len(needle) && int(token.end) > start {
			testing.expectf(t, false, "%q overlaps a %v token", needle, token.kind, loc = loc)
			return
		}
	}
}

// Every token is non-empty, in range and after the one before it.
@(private="file")
expect_sane :: proc(
	t: ^testing.T,
	lexer: syntax.Lexer,
	language: syntax.Language,
	text: string,
	loc := #caller_location,
) -> bool {
	tokens := make([dynamic]syntax.Token, context.temp_allocator)
	if !testing.expect(t, lexer(language, text, &tokens), loc = loc) {return false}
	previous: u32 = 0
	for token in tokens {
		if token.start >= token.end || token.start < previous || int(token.end) > len(text) {
			shown := text[:min(len(text), 200)]
			testing.expectf(t, false, "%v: bad token %v in %q", language, token, shown, loc = loc)
			return false
		}
		previous = token.end
	}
	return true
}

@(test)
json_keys_values_and_comments :: proc(t: ^testing.T) {
	text := "{\"name\": \"x\\\"y\", \"n\": -1.5e3, \"ok\": true, \"z\": null, // line\r\n" +
		"\"spaced\"\n  : [0, \"item\"] /* block\n */, \"open\n}"
	tokens := lex(t, syntax.lex_json, .Json, text)
	expect_token(t, tokens, text, "\"name\"", .Attribute)
	expect_token(t, tokens, text, "\"x\\\"y\"", .String)
	expect_token(t, tokens, text, "-1.5e3", .Number)
	expect_token(t, tokens, text, "true", .Constant)
	expect_token(t, tokens, text, "null", .Constant)
	expect_token(t, tokens, text, "// line", .Comment)
	expect_token(t, tokens, text, "\"spaced\"", .Attribute)
	expect_token(t, tokens, text, "0", .Number)
	expect_token(t, tokens, text, "\"item\"", .String)
	expect_token(t, tokens, text, "/* block\n */", .Comment)
	// A string left open ends with its line.
	expect_token(t, tokens, text, "\"open", .String)
}

@(test)
toml_tables_keys_and_values :: proc(t: ^testing.T) {
	text := "# top\r\n[server]\nhost = \"localhost\" # where\n port = 8_080\n\"quoted key\".sub = 'lit'\n" +
		"[[items]]\nwhen = 1979-05-27T07:32:00Z\nflags = [true, false]\ninline = { k1 = 1, b.c = \"x\" }\n" +
		"text = \"\"\"\nmulti \"line\"\n\"\"\"\nratio = -inf\n"
	tokens := lex(t, syntax.lex_toml, .Toml, text)
	expect_token(t, tokens, text, "# top", .Comment)
	expect_token(t, tokens, text, "[server]", .Type)
	expect_token(t, tokens, text, "host", .Attribute)
	expect_token(t, tokens, text, "\"localhost\"", .String)
	expect_token(t, tokens, text, "# where", .Comment)
	expect_token(t, tokens, text, "port", .Attribute)
	expect_token(t, tokens, text, "8_080", .Number)
	expect_token(t, tokens, text, "\"quoted key\".sub", .Attribute)
	expect_token(t, tokens, text, "'lit'", .String)
	expect_token(t, tokens, text, "[[items]]", .Type)
	expect_token(t, tokens, text, "1979-05-27T07:32:00Z", .Number)
	expect_token(t, tokens, text, "true", .Constant)
	expect_token(t, tokens, text, "k1", .Attribute)
	expect_token(t, tokens, text, "b.c", .Attribute)
	expect_token(t, tokens, text, "\"\"\"\nmulti \"line\"\n\"\"\"", .String)
	expect_token(t, tokens, text, "inf", .Number)
}

@(test)
toml_nested_array_lines_are_not_headers :: proc(t: ^testing.T) {
	text := "nums = [\n  [7, 8],\n]\n[next]\n"
	tokens := lex(t, syntax.lex_toml, .Toml, text)
	expect_token(t, tokens, text, "7", .Number)
	expect_token(t, tokens, text, "[next]", .Type)
}

@(test)
yaml_keys_scalars_and_flow :: proc(t: ^testing.T) {
	text := "--- \nname: demo   # comment\r\n\"quoted\": 'it''s'\nlist:\n  - item: 42\n    on: yes\n" +
		"  - &anchor plain text\n  - *anchor\nnext: !!str 3.5\nflow: {k1: 1, k2: [x, y]}\n" +
		"url: http://example.com:8080/x\nmulti: \"one\n  two\"\n"
	tokens := lex(t, syntax.lex_yaml, .Yaml, text)
	expect_token(t, tokens, text, "---", .Keyword)
	expect_token(t, tokens, text, "name", .Attribute)
	expect_plain(t, tokens, text, "demo")
	expect_token(t, tokens, text, "# comment", .Comment)
	expect_token(t, tokens, text, "\"quoted\"", .Attribute)
	expect_token(t, tokens, text, "'it'", .String)
	expect_token(t, tokens, text, "list", .Attribute)
	expect_token(t, tokens, text, "item", .Attribute)
	expect_token(t, tokens, text, "42", .Number)
	expect_token(t, tokens, text, "on", .Attribute)
	expect_token(t, tokens, text, "yes", .Constant)
	expect_token(t, tokens, text, "&anchor", .Constant)
	expect_plain(t, tokens, text, "plain text")
	expect_token(t, tokens, text, "*anchor", .Constant)
	expect_token(t, tokens, text, "!!str", .Type)
	expect_token(t, tokens, text, "3.5", .Number)
	expect_token(t, tokens, text, "flow", .Attribute)
	expect_token(t, tokens, text, "k1", .Attribute)
	expect_token(t, tokens, text, "k2", .Attribute)
	expect_plain(t, tokens, text, "x, y")
	expect_token(t, tokens, text, "url", .Attribute)
	expect_plain(t, tokens, text, "http://example.com:8080/x")
	expect_token(t, tokens, text, "\"one\n  two\"", .String)
}

@(test)
yaml_block_scalars_are_strings :: proc(t: ^testing.T) {
	text := "script: |\n  echo \"hi\"\n\n  # not a comment\nkeep: >-\n    folded: text\n" +
		"items:\n  - |\n    body\n  - after\n"
	tokens := lex(t, syntax.lex_yaml, .Yaml, text)
	expect_token(t, tokens, text, "script", .Attribute)
	expect_token(t, tokens, text, "echo \"hi\"", .String)
	expect_token(t, tokens, text, "# not a comment", .String)
	expect_token(t, tokens, text, "keep", .Attribute)
	expect_token(t, tokens, text, "folded: text", .String)
	expect_token(t, tokens, text, "items", .Attribute)
	expect_token(t, tokens, text, "body", .String)
	expect_plain(t, tokens, text, "after")
}

@(test)
yaml_crlf_block_scalar_lines_leave_out_the_cr :: proc(t: ^testing.T) {
	file, ok := syntax.highlight(.Yaml, "a: |\r\n  x\r\nb: 1\r\n")
	defer syntax.file_lines_destroy(&file)
	testing.expect(t, ok)
	testing.expect_value(t, len(file.lines), 3)
	if len(file.lines) != 3 {return}
	testing.expect_value(t, file.lines[1][0], syntax.Span{start = 2, end = 3, kind = .String})
	testing.expect_value(t, file.lines[2][0], syntax.Span{start = 0, end = 1, kind = .Attribute})
	testing.expect_value(t, file.lines[2][1], syntax.Span{start = 3, end = 4, kind = .Number})
}

@(test)
html_tags_attributes_comments_and_entities :: proc(t: ^testing.T) {
	text := "<!DOCTYPE html>\n<!-- note\n more -->\n" +
		"<div class=\"a\" data-x=1 hidden>Tom &amp; Jerry & co</div>\n<img src='i.png'/><![CDATA[ <raw> ]]>\n"
	tokens := lex(t, syntax.lex_html, .Html, text)
	expect_token(t, tokens, text, "<!DOCTYPE html>", .Keyword)
	expect_token(t, tokens, text, "<!-- note\n more -->", .Comment)
	expect_token(t, tokens, text, "<div", .Tag)
	expect_token(t, tokens, text, "class", .Attribute)
	expect_token(t, tokens, text, "\"a\"", .String)
	expect_token(t, tokens, text, "data-x", .Attribute)
	expect_token(t, tokens, text, "1", .String)
	expect_token(t, tokens, text, "hidden", .Attribute)
	expect_token(t, tokens, text, "&amp;", .Constant)
	expect_plain(t, tokens, text, "& co")
	expect_token(t, tokens, text, "</div", .Tag)
	expect_token(t, tokens, text, "'i.png'", .String)
	expect_token(t, tokens, text, "/>", .Tag)
	expect_token(t, tokens, text, "<![CDATA[ <raw> ]]>", .String)
}

@(test)
html_style_and_script_contents_are_lexed_in_their_language :: proc(t: ^testing.T) {
	text := "<style>\np { color: red; }\n</style><script>let n = \"</p>\";</script><p>lets</p>"
	tokens := lex(t, syntax.lex_html, .Html, text)
	expect_token(t, tokens, text, "<style", .Tag)
	expect_token(t, tokens, text, "p", .Tag)
	expect_token(t, tokens, text, "color", .Attribute)
	expect_token(t, tokens, text, "</style", .Tag)
	expect_token(t, tokens, text, "let", .Keyword)
	expect_token(t, tokens, text, "\"</p>\"", .String)
	expect_token(t, tokens, text, "</script", .Tag)
	expect_plain(t, tokens, text, "lets")
}

@(test)
xml_declarations_and_namespaced_tags :: proc(t: ^testing.T) {
	text := "<?xml version=\"1.0\"?>\n<svg:rect xmlns:svg=\"u\" width='2'\n  height=\"3\"/>"
	tokens := lex(t, syntax.lex_html, .Html, text)
	expect_token(t, tokens, text, "<?xml version=\"1.0\"?>", .Keyword)
	expect_token(t, tokens, text, "<svg:rect", .Tag)
	expect_token(t, tokens, text, "xmlns:svg", .Attribute)
	expect_token(t, tokens, text, "height", .Attribute)
	expect_token(t, tokens, text, "\"3\"", .String)
}

@(test)
css_selectors_properties_and_values :: proc(t: ^testing.T) {
	text := "@media (max-width: 600px) {\n" +
		"  .card > a:hover, #id { color: #fff; margin: -1.5em 0 !important; }\n}\n/* c\n */ " +
		".x { background: url(//cdn.example.com/a.png); width: calc(100% - 2px); content: \"q\"; }\n" +
		"$pad: 4px; // line\r\n.y { &:hover { --gap: .5rem; } }\n"
	tokens := lex(t, syntax.lex_css, .Css, text)
	expect_token(t, tokens, text, "@media", .Keyword)
	expect_plain(t, tokens, text, "max-width")
	expect_token(t, tokens, text, "600px", .Number)
	expect_token(t, tokens, text, ".card", .Tag)
	expect_token(t, tokens, text, "a:hover", .Tag)
	expect_token(t, tokens, text, "#id", .Tag)
	expect_token(t, tokens, text, "color", .Attribute)
	expect_token(t, tokens, text, "#fff", .Number)
	expect_token(t, tokens, text, "-1.5em", .Number)
	expect_token(t, tokens, text, "!important", .Keyword)
	expect_token(t, tokens, text, "/* c\n */", .Comment)
	expect_token(t, tokens, text, "background", .Attribute)
	expect_token(t, tokens, text, "url", .Function)
	expect_token(t, tokens, text, "//cdn.example.com/a.png", .String)
	expect_token(t, tokens, text, "calc", .Function)
	expect_token(t, tokens, text, "100%", .Number)
	expect_plain(t, tokens, text, "- ")
	expect_token(t, tokens, text, "\"q\"", .String)
	expect_token(t, tokens, text, "$pad", .Attribute)
	expect_token(t, tokens, text, "// line", .Comment)
	expect_token(t, tokens, text, "&:hover", .Tag)
	expect_token(t, tokens, text, "--gap", .Attribute)
	expect_token(t, tokens, text, ".5rem", .Number)
}

@(test)
markdown_headings_code_and_links :: proc(t: ^testing.T) {
	text := "# Title\r\nSome `code` and ``a ` b`` and [link](http://x.y) and ![img](a.png).\n" +
		"Ref [x][y], <https://a.b> and a <b> tag, `open and [no](paren.\n\n" +
		"```odin\nmain :: proc() {}\n# not a heading\n  ```\n[y]: https://example.com\n" +
		"## Unclosed `tick\n    # indented code\n####### seven\n"
	tokens := lex(t, syntax.lex_markdown, .Markdown, text)
	expect_token(t, tokens, text, "# Title", .Keyword)
	expect_token(t, tokens, text, "`code`", .String)
	expect_token(t, tokens, text, "``a ` b``", .String)
	expect_token(t, tokens, text, "[link](http://x.y)", .Function)
	expect_token(t, tokens, text, "![img](a.png)", .Function)
	expect_token(t, tokens, text, "[x][y]", .Function)
	expect_token(t, tokens, text, "<https://a.b>", .Function)
	expect_plain(t, tokens, text, "<b>")
	expect_plain(t, tokens, text, "`open")
	expect_plain(t, tokens, text, "[no](paren.")
	expect_token(t, tokens, text, "```odin\nmain :: proc() {}\n# not a heading\n  ```", .String)
	expect_token(t, tokens, text, "[y]: https://example.com", .Function)
	expect_token(t, tokens, text, "## Unclosed `tick", .Keyword)
	expect_plain(t, tokens, text, "# indented code")
	expect_plain(t, tokens, text, "####### seven")
}

@(test)
markdown_unclosed_fence_runs_to_the_end :: proc(t: ^testing.T) {
	text := "~~~\ncode\n```\nmore\r\n"
	tokens := lex(t, syntax.lex_markdown, .Markdown, text)
	expect_token(t, tokens, text, "~~~\ncode\n```\nmore", .String)
}

@(test)
markup_lexers_survive_random_and_truncated_input :: proc(t: ^testing.T) {
	Case :: struct {
		language: syntax.Language,
		lexer:    syntax.Lexer,
		sample:   string,
	}
	cases := [?]Case {
		{.Json, syntax.lex_json, "{\"a\\\"\": [1.5e-3, true, \"b\"], // c\n /* d */ \"e\": null}"},
		{.Toml, syntax.lex_toml, "[t]\na.\"b\" = \"\"\"x\\\"\"\"\" # c\nd = { e = [1, 'f'] }\n[[g]]\n"},
		{.Yaml, syntax.lex_yaml, "--- \na: |+\n  b\nc: {d: 'e''f', g: [h]} # i\n- &j \"k\\\"\" !t\n"},
		{.Html, syntax.lex_html, "<!--a--><p x=\"y\" z=w>&amp;<style>p{c:d}</style><script>`${x}`</script>"},
		{.Css, syntax.lex_css, "@m (a:1px){.b:c,#d{e:-1.5em url(f;g) !important;#{h}:i}}/*j*/ //k\n"},
		{.Markdown, syntax.lex_markdown, "# a\n``b`c``[d](e)![f][g]<h:i>\n```x\ny\n```\n[k]: l\n"},
	}
	alphabet := "\"'`#<>!-[]{}()=:;,.$@*&|/\\\n\r \t0123456789aZx_~%+?&;\x80\xff"
	state: u64 = 0x2545f4914f6cdd1d
	buffer: [256]u8
	for c in cases {
		for k in 0 ..= len(c.sample) {
			if !expect_sane(t, c.lexer, c.language, c.sample[:k]) {return}
		}
		for _ in 0 ..< 400 {
			state ~= state << 13
			state ~= state >> 7
			state ~= state << 17
			length := int(state % u64(len(buffer)))
			for i in 0 ..< length {
				state ~= state << 13
				state ~= state >> 7
				state ~= state << 17
				buffer[i] = alphabet[state % u64(len(alphabet))]
			}
			if !expect_sane(t, c.lexer, c.language, string(buffer[:length])) {return}
			free_all(context.temp_allocator)
		}
	}
}

@(test)
markup_lexers_stay_linear_on_repeated_bytes :: proc(t: ^testing.T) {
	patterns := []string {
		"<", "&", "[", "]", "`", "\"", "'", "#", "-", "!", "{", ",", ":", "/", "*", "|", ">", "@", " ", "\n",
		"a", "0", "/*'*/;", "a:url(')x;", "a:'b;", "#{", "[a](", "[a][", "![", "<a", "<a:", "<!", "<style>",
		"<script>", "- ", "{a", "{a,", "\"a\" ", "a.", "a = ", "`` ` ", "&#", "| ", "!a", "a: |\n",
	}
	text := make([]u8, 256 * 1024)
	defer delete(text)
	Case :: struct {
		language: syntax.Language,
		lexer:    syntax.Lexer,
	}
	lexers := [?]Case {
		{.Json, syntax.lex_json},
		{.Toml, syntax.lex_toml},
		{.Yaml, syntax.lex_yaml},
		{.Html, syntax.lex_html},
		{.Css, syntax.lex_css},
		{.Markdown, syntax.lex_markdown},
	}
	for l in lexers {
		for pattern in patterns {
			for i in 0 ..< len(text) {text[i] = pattern[i % len(pattern)]}
			if !expect_sane(t, l.lexer, l.language, string(text)) {return}
			free_all(context.temp_allocator)
		}
	}
}
