package syntax_test

import "aio:syntax"
import "core:strings"
import "core:testing"
import "core:time"

@(private)
C_FAMILY :: [?]syntax.Language{.Odin, .C, .Cpp, .CSharp, .Java, .JavaScript, .TypeScript, .Tsx, .Go, .Rust}

@(test)
odin_tokens :: proc(t: ^testing.T) {
	source := `package demo

import "core:fmt"

// line comment
Max_Size :: 1_000
LIMIT :: 0x1F
@(private="file")
area :: proc(x: f32, s: Shape) -> int {
	#partial switch s {
	}
	r := 'x'
	str := "a\"b"
	for i in 0..<n {}
	fmt.println(str)
	return int(x * 1.5e-3) + nil
}
poly :: proc($T: typeid) {}
/* outer /* inner */ still */ after
`
	expect_kinds(t, .Odin, source, {
		{"package", .Keyword},
		{`"core:fmt"`, .String},
		{"// line comment", .Comment},
		{"Max_Size", .Type},
		{"1_000", .Number},
		{"LIMIT", .Constant},
		{"0x1F", .Number},
		{`@(private="file")`, .Attribute},
		{"area", .Plain},
		{"proc", .Keyword},
		{"f32", .Type},
		{"Shape", .Type},
		{"int", .Type},
		{"#partial", .Keyword},
		{"switch", .Keyword},
		{"'x'", .String},
		{`"a\"b"`, .String},
		{"0", .Number},
		{"..<", .Plain},
		{"println", .Function},
		{"return", .Keyword},
		{"int", .Type},
		{"1.5e-3", .Number},
		{"nil", .Constant},
		{"$T", .Type},
		{"typeid", .Type},
		{"/* outer /* inner */ still */", .Comment},
		{"after", .Plain},
	})
}

@(test)
odin_raw_strings_span_lines :: proc(t: ^testing.T) {
	source := "s := `one\\n\r\ntwo`\r\nx := 1\r\n"
	expect_kinds(t, .Odin, source, {{"`one\\n\r\ntwo`", .String}, {"x", .Plain}, {"1", .Number}})
}

@(test)
c_tokens :: proc(t: ^testing.T) {
	source := `#include <stdio.h>
#define SQUARE(x) ((x) * (x))
  #  ifdef DEBUG
static unsigned int count = 0xFFu;
int main(void) {
	char c = '\n';
	const char *s = "say \"hi\"";
	wchar_t *w = L"wide";
	float f = 1.0f / 2;
	return printf("%d", count) + NULL; /* block
comment */
}
`
	expect_kinds(t, .C, source, {
		{"#include", .Keyword},
		{"<stdio.h>", .String},
		{"#define", .Keyword},
		{"SQUARE", .Function},
		{"#  ifdef", .Keyword},
		{"DEBUG", .Plain},
		{"static", .Keyword},
		{"unsigned", .Type},
		{"int", .Type},
		{"0xFFu", .Number},
		{"int", .Type},
		{"main", .Function},
		{"void", .Type},
		{"char", .Type},
		{`'\n'`, .String},
		{`"say \"hi\""`, .String},
		{"wchar_t", .Type},
		{`L"wide"`, .String},
		{"1.0f", .Number},
		{"/", .Plain},
		{"2", .Number},
		{"return", .Keyword},
		{"printf", .Function},
		{`"%d"`, .String},
		{"NULL", .Constant},
		{"/* block\ncomment */", .Comment},
	})
}

@(test)
cpp_tokens :: proc(t: ^testing.T) {
	source := `auto s = R"x(raw ")" text
second line)x";
int n = 1'000'000;
auto u = u8"utf";
class Foo : public Bar {};
if (p == nullptr) {}
template <typename T> T id(T v) { return v; }
`
	expect_kinds(t, .Cpp, source, {
		{"auto", .Keyword},
		{"R\"x(raw \")\" text\nsecond line)x\"", .String},
		{";", .Plain},
		{"int", .Type},
		{"1'000'000", .Number},
		{`u8"utf"`, .String},
		{"class", .Keyword},
		{"Foo", .Plain},
		{"public", .Keyword},
		{"nullptr", .Constant},
		{"template", .Keyword},
		{"typename", .Keyword},
		{"id", .Function},
	})
}

@(test)
csharp_tokens :: proc(t: ^testing.T) {
	source := `#region Setup
[Serializable]
public class Foo {
	string path = @"C:\dir\""quoted""";
	var hi = $"Hi {name}\n";
	var raw = """
		raw "text"
		""";
	int @class = 0;
	object o = null;
}
#endregion
`
	expect_kinds(t, .CSharp, source, {
		{"#region", .Keyword},
		{"public", .Keyword},
		{"class", .Keyword},
		{"Foo", .Type},
		{"string", .Type},
		{`@"C:\dir\""quoted"""`, .String},
		{"var", .Keyword},
		{`$"Hi {name}\n"`, .String},
		{"\"\"\"\n\t\traw \"text\"\n\t\t\"\"\"", .String},
		{"int", .Type},
		{"@class", .Plain},
		{"0", .Number},
		{"object", .Type},
		{"null", .Constant},
		{"#endregion", .Keyword},
	})
}

@(test)
java_tokens :: proc(t: ^testing.T) {
	source := `@Override
public static final int MAX_VALUE = 0b1010;
String text = """
    Hello "there"
    """;
char c = 'c';
long big = 10_000L;
var $x = list.get(0);
Object o = null; // done
`
	expect_kinds(t, .Java, source, {
		{"@Override", .Attribute},
		{"public", .Keyword},
		{"static", .Keyword},
		{"final", .Keyword},
		{"int", .Type},
		{"MAX_VALUE", .Constant},
		{"0b1010", .Number},
		{"String", .Type},
		{"\"\"\"\n    Hello \"there\"\n    \"\"\"", .String},
		{"char", .Type},
		{"'c'", .String},
		{"long", .Type},
		{"10_000L", .Number},
		{"var", .Keyword},
		{"$x", .Plain},
		{"get", .Function},
		{"null", .Constant},
		{"// done", .Comment},
	})
}

@(test)
javascript_tokens :: proc(t: ^testing.T) {
	source :=
		"const re = /a\\/b[/]c/gi;\n" +
		"let q = a / b / c;\n" +
		"function greet(name) {\n" +
		"\treturn name === undefined ? 'none' : `hi ${name}\n" +
		"again`;\n" +
		"}\n" +
		"const el = <div className=\"x\">{greet(\"a\")}</div>;\n" +
		"map.get(key);\n" +
		"x = 10n + 0x1F + .5;\n" +
		"@decorator\n" +
		"class A {}\n"
	expect_kinds(t, .JavaScript, source, {
		{"const", .Keyword},
		{"/a\\/b[/]c/gi", .String},
		{"let", .Keyword},
		{"a", .Plain},
		{"/", .Plain},
		{"b", .Plain},
		{"/", .Plain},
		{"function", .Keyword},
		{"greet", .Function},
		{"return", .Keyword},
		{"undefined", .Constant},
		{"'none'", .String},
		{"`hi ${name}\nagain`", .String},
		{"<div", .Tag},
		{"className", .Plain},
		{`"x"`, .String},
		{"greet", .Function},
		{`"a"`, .String},
		{"</div", .Tag},
		{"get", .Function},
		{"10n", .Number},
		{"0x1F", .Number},
		{".5", .Number},
		{"@decorator", .Attribute},
		{"class", .Keyword},
		{"A", .Type},
	})
}

@(test)
typescript_tokens :: proc(t: ^testing.T) {
	source := `interface Point { x: number; label?: string }
type Id = string | null;
const p = <Point>value;
enum Color { Red }
let n: unknown = undefined as any;
function f<T>(v: T): T { return v; }
`
	expect_kinds(t, .TypeScript, source, {
		{"interface", .Keyword},
		{"Point", .Type},
		{"number", .Type},
		{"string", .Type},
		{"type", .Keyword},
		{"Id", .Type},
		{"string", .Type},
		{"null", .Constant},
		{"<", .Plain},
		{"Point", .Type},
		{"enum", .Keyword},
		{"Color", .Type},
		{"unknown", .Type},
		{"undefined", .Constant},
		{"as", .Keyword},
		{"any", .Type},
		{"function", .Keyword},
		{"f", .Plain},
		{"T", .Type},
	})
}

@(test)
tsx_tokens :: proc(t: ^testing.T) {
	source := "const view = <Panel title=\"x\" />;\nconst less = (a: number) => a < 2;\n// `not a template\n"
	expect_kinds(t, .Tsx, source, {
		{"<Panel", .Tag},
		{"title", .Plain},
		{`"x"`, .String},
		{"number", .Type},
		{"<", .Plain},
		{"2", .Number},
		{"// `not a template", .Comment},
	})
}

@(test)
go_tokens :: proc(t: ^testing.T) {
	source :=
		"package main\n\n" +
		"import \"fmt\"\n\n" +
		"type Reader struct{ name string }\n\n" +
		"func main() {\n" +
		"\tr := 'x'\n" +
		"\ts := `raw \\n\n" +
		"string`\n" +
		"\tvar n int64 = 0o17 + iota\n" +
		"\tfmt.Println(r, s, n, nil, true)\n" +
		"}\n"
	expect_kinds(t, .Go, source, {
		{"package", .Keyword},
		{"main", .Plain},
		{`"fmt"`, .String},
		{"type", .Keyword},
		{"Reader", .Plain},
		{"struct", .Keyword},
		{"string", .Type},
		{"func", .Keyword},
		{"main", .Function},
		{"'x'", .String},
		{"`raw \\n\nstring`", .String},
		{"var", .Keyword},
		{"int64", .Type},
		{"0o17", .Number},
		{"iota", .Constant},
		{"Println", .Function},
		{"nil", .Constant},
		{"true", .Constant},
	})
}

@(test)
rust_tokens :: proc(t: ^testing.T) {
	source := `#[derive(Debug, Clone)]
pub struct Holder<'a> { name: &'a str }
fn main() {
	let mut v: Vec<i32> = vec![1, 2];
	let c = 'x';
	let b = b'y';
	let raw = r#"a "quoted"
b"#;
	let n = 1u8 + 0b1010 + 1_000.5e3;
	println!("{}", v.len());
	/* outer /* inner */ still */
	let o: Option<Self> = None;
	let t = x.0 != y;
}
`
	expect_kinds(t, .Rust, source, {
		{"#[derive(Debug, Clone)]", .Attribute},
		{"pub", .Keyword},
		{"struct", .Keyword},
		{"Holder", .Type},
		{"'a", .Plain},
		{"'a", .Plain},
		{"str", .Type},
		{"fn", .Keyword},
		{"main", .Function},
		{"let", .Keyword},
		{"mut", .Keyword},
		{"Vec", .Type},
		{"i32", .Type},
		{"vec", .Function},
		{"'x'", .String},
		{"b'y'", .String},
		{"r#\"a \"quoted\"\nb\"#", .String},
		{"1u8", .Number},
		{"0b1010", .Number},
		{"1_000.5e3", .Number},
		{"println", .Function},
		{`"{}"`, .String},
		{"len", .Function},
		{"/* outer /* inner */ still */", .Comment},
		{"Option", .Type},
		{"Self", .Keyword},
		{"None", .Constant},
		{"x", .Plain},
		{"0", .Number},
		{"y", .Plain},
	})
}

@(test)
unterminated_constructs_stop_at_their_limit :: proc(t: ^testing.T) {
	// A one-line string ends at its line; a block comment, raw string or template runs to the end.
	expect_kinds(t, .C, "a = \"open\nb = 1;\n", {{"\"open", .String}, {"b", .Plain}, {"1", .Number}})
	expect_kinds(t, .Go, "x := `open\ny := 1\n", {{"`open\ny := 1", .String}})
	expect_kinds(t, .Rust, "/* a /* b */ c\nd", {{"/* a /* b */ c\nd", .Comment}})
	expect_kinds(t, .JavaScript, "x = `a ${b\nc", {{"`a ${b\nc", .String}})
	expect_kinds(t, .Cpp, "R\"(open\nx", {{"R\"(open\nx", .String}})
}

@(private)
expect_valid_tokens :: proc(
	t: ^testing.T,
	language: syntax.Language,
	tokens: []syntax.Token,
	text: string,
) -> bool {
	previous := u32(0)
	for token in tokens {
		valid := previous <= token.start && token.start < token.end && int(token.end) <= len(text)
		if !testing.expectf(t, valid, "%v: bad token %v after %d in %q", language, token, previous, text) {
			return false
		}
		previous = token.end
	}
	return true
}

// Random text and every prefix of a sample full of constructs: the lexer returns, its tokens are in
// order, disjoint and inside the text.
@(test)
lex_c_family_survives_random_and_truncated_text :: proc(t: ^testing.T) {
	samples := [?]string {
		"@(private=\"file\") #+build windows\n/* a /* b */ c */ `raw` 'x' \"s\\\"\" $T 0x1F 1.5e-3 0..<n",
		"#include <a.h>\n#define F(x) x\nR\"d(raw)d\" u8\"s\" L'c' 1'000 /* c */ // l\n",
		"@\"v\"\"x\" $\"i{a}\" @$\"b\" $$\"\"\"r\"\"\" \"\"\"t\"\"\" @class #region\n[A] 'c'",
		"x = /re[/]\\//g; y = a / b; `t ${`n`} \\` e` <div a=\"b\">{c}</div> @dec.x A_B",
		"#![attr] #[a(\"]\")] r##\"x\"#\"## br\"b\" b'c' 'a 'x' '\\n' r#type println!(1) 1u8 x.0",
	}
	tokens := make([dynamic]syntax.Token)
	defer delete(tokens)
	for language in C_FAMILY {
		for sample in samples {
			for length in 0 ..= len(sample) {
				clear(&tokens)
				testing.expect(t, syntax.lex_c_family(language, sample[:length], &tokens))
				if !expect_valid_tokens(t, language, tokens[:], sample[:length]) {return}
			}
		}
		r := Rng{0x2545f4914f6cdd1d + u64(language)}
		buffer: [400]u8
		for _ in 0 ..< 400 {
			text := fuzz_text(&r, buffer[:])
			clear(&tokens)
			testing.expect(t, syntax.lex_c_family(language, text, &tokens))
			if !expect_valid_tokens(t, language, tokens[:], text) {return}
		}
	}
}

// Long runs of constructs that open without closing; a lexer that rescans would take minutes here.
@(test)
lex_c_family_stays_linear_on_pathological_text :: proc(t: ^testing.T) {
	patterns := [?]string {
		"/[", "r#", "R\"", "#[", "@(", "/*", "\"\\", "'", "`", "$\"", "@\"", "\"\"\"", "'a", "#  ", "</",
		"r###\"#", ")\"", "0x", "1.",
	}
	tokens := make([dynamic]syntax.Token)
	defer delete(tokens)
	for pattern in patterns {
		text := strings.repeat(pattern, 128 * 1024 / len(pattern))
		defer delete(text)
		for language in C_FAMILY {
			clear(&tokens)
			start := time.tick_now()
			testing.expect(t, syntax.lex_c_family(language, text, &tokens))
			elapsed := time.tick_since(start)
			testing.expectf(t, elapsed < 2 * time.Second, "%v on %q took %v", language, pattern, elapsed)
		}
	}
}

// A run of one byte that may open a construct, as long as the largest highlighted file: a branch that
// looks ahead over the run and then moves on by one byte would rescan it from every byte.
@(test)
lex_c_family_stays_linear_on_long_runs :: proc(t: ^testing.T) {
	tokens := make([dynamic]syntax.Token)
	defer delete(tokens)
	for run in "$#@'" {
		text := strings.repeat(string([]u8{u8(run)}), syntax.HIGHLIGHT_LIMIT)
		defer delete(text)
		for language in C_FAMILY {
			clear(&tokens)
			start := time.tick_now()
			testing.expect(t, syntax.lex_c_family(language, text, &tokens))
			elapsed := time.tick_since(start)
			testing.expectf(t, elapsed < 2 * time.Second, "%v on a run of %q took %v", language, run, elapsed)
		}
	}
}
