// Syntax colouring for source text (WORK-489). A lexer per language family turns a whole file into
// tokens; highlight splits them into spans per line, which is what a diff line looks up. A tree-sitter
// backend could later fill the same per-line spans.
package syntax

Language :: enum u8 {
	None,
	Odin,
	C,
	Cpp,
	CSharp,
	Java,
	JavaScript,
	TypeScript,
	Tsx,
	Go,
	Rust,
	Python,
	Lua,
	Shell,
	PowerShell,
	Json,
	Toml,
	Yaml,
	Html,
	Css,
	Markdown,
}

Token_Kind :: enum u8 {
	Plain,
	Keyword,
	Type,
	Function,
	String,
	Number,
	Constant,
	Comment,
	Operator,
	Attribute,
	Tag,
}

// Byte offsets into the whole text, end exclusive.
Token :: struct {
	start, end: u32,
	kind:       Token_Kind,
}

// Byte offsets into one line's text (without its line break), end exclusive. A line's spans are sorted
// and do not overlap; plain text between them has no span.
Span :: struct {
	start, end: u32,
	kind:       Token_Kind,
}

// Appends the tokens of `text` in order. Plain text may be left out. False only when out of memory.
Lexer :: #type proc(language: Language, text: string, out: ^[dynamic]Token) -> bool

// A file larger than this is not highlighted.
HIGHLIGHT_LIMIT :: 1 << 20

// The spans of each line of a file, 0-based: lines[i] belongs to the file's line i + 1.
File_Lines :: struct {
	lines: [][]Span,
}
