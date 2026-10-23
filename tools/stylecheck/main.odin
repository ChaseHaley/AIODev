package stylecheck

import "core:fmt"
import "core:os"
import "core:strings"

USAGE :: `stylecheck [--fix] <file.odin>...
Checks the whitespace rules the source review found drifting:
  1. Binary +, -, *, / and % take one space on each side.
  2. No source line is wider than 110 columns.
Strings, rune literals and comments are skipped. --fix inserts the missing spaces and rewrites
the file; it never changes anything else. Exit codes: 0 clean, 1 issues, 2 usage.
`

MAX_WIDTH :: 110

Rule :: enum {
	Unspaced_Operator,
	Line_Width,
}

Issue :: struct {
	path:   string,
	line:   int,
	column: int,
	offset: int,
	rule:   Rule,
}

State :: enum {
	Code,
	Line_Comment,
	Block_Comment,
	String,
	Raw_String,
	Rune,
}

main :: proc() {
	args := os.args[1:]
	fix := false
	if len(args) > 0 && args[0] == "--fix" {
		fix, args = true, args[1:]
	}
	if len(args) == 0 {
		fmt.eprint(USAGE)
		os.exit(2)
	}
	issues: [dynamic]Issue
	defer delete(issues)
	for path in args {
		text, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			fmt.eprintfln("%s: cannot read", path)
			os.exit(2)
		}
		defer delete(text)
		if fix {
			fixed := fix_text(string(text))
			if fixed != string(text) && os.write_entire_file(path, fixed) != nil {
				fmt.eprintfln("%s: cannot write", path)
				os.exit(2)
			}
			scan(path, fixed, &issues)
			continue
		}
		scan(path, string(text), &issues)
	}
	for issue in issues {
		fmt.printfln("%s:%d:%d: %s", issue.path, issue.line, issue.column, rule_text(issue.rule))
	}
	if len(issues) > 0 {
		fmt.eprintfln("%d style issue(s)", len(issues))
		os.exit(1)
	}
}

rule_text :: proc(rule: Rule) -> string {
	switch rule {
	case .Unspaced_Operator:
		return "put one space around a binary operator"
	case .Line_Width:
		return "keep the line within 110 columns"
	}
	return ""
}

// Records every rule break in `text`. The caller owns the appended issues.
scan :: proc(path: string, text: string, issues: ^[dynamic]Issue) {
	state := State.Code
	line, column := 1, 1
	line_start := 0
	line_in_raw := false
	i := 0
	for i < len(text) {
		c := text[i]
		next := i + 1 < len(text) ? text[i + 1] : 0
		switch state {
		case .Code:
			if c == '/' && next == '/' {
				state = .Line_Comment
				i, column = i + 2, column + 2
				continue
			}
			if c == '/' && next == '*' {
				state = .Block_Comment
				i, column = i + 2, column + 2
				continue
			}
			if c == '"' {
				state = .String
				i, column = i + 1, column + 1
				continue
			}
			if c == '`' {
				state = .Raw_String
				i, column = i + 1, column + 1
				continue
			}
			if c == '\'' {
				state = .Rune
				i, column = i + 1, column + 1
				continue
			}
			if is_operator(c) && unspaced(text, i) {
				append(issues, Issue{path, line, column, i, .Unspaced_Operator})
			}
		case .Line_Comment:
			if c == '\n' {state = .Code}
		case .Block_Comment:
			if c == '*' && next == '/' {
				state = .Code
				i, column = i + 2, column + 2
				continue
			}
		case .String:
			if c == '\\' {
				i, column = i + 2, column + 2
				continue
			}
			if c == '"' {state = .Code}
		case .Raw_String:
			if c == '`' {state = .Code}
		case .Rune:
			if c == '\\' {
				i, column = i + 2, column + 2
				continue
			}
			if c == '\'' {state = .Code}
		}
		if c == '\n' {
			end := i
			if end > line_start && text[end - 1] == '\r' {end -= 1}
			if !line_in_raw && end - line_start > MAX_WIDTH {
				append(issues, Issue{path, line, 1, line_start, .Line_Width})
			}
			line, column, line_start = line + 1, 1, i + 1
			line_in_raw = state == .Raw_String
		} else {
			column += 1
		}
		i += 1
	}
	if len(text) > line_start && !line_in_raw {
		end := len(text)
		if text[end - 1] == '\r' {end -= 1}
		if end - line_start > MAX_WIDTH {
			append(issues, Issue{path, line, 1, line_start, .Line_Width})
		}
	}
}

// Inserts one space around every unspaced binary operator. Nothing else moves, so a caller can
// commit the result as a whitespace-only change. The returned text borrows the temp allocator.
fix_text :: proc(text: string) -> string {
	issues: [dynamic]Issue
	defer delete(issues)
	scan("", text, &issues)
	b := strings.builder_make(context.temp_allocator)
	cursor := 0
	for issue in issues {
		if issue.rule != .Unspaced_Operator {continue}
		at := issue.offset
		if at < cursor || at == 0 || at + 1 >= len(text) {continue}
		strings.write_string(&b, text[cursor:at])
		strings.write_string(&b, " ")
		strings.write_byte(&b, text[at])
		strings.write_string(&b, " ")
		cursor = at + 1
	}
	strings.write_string(&b, text[cursor:])
	return strings.to_string(b)
}

is_operator :: proc(c: u8) -> bool {
	switch c {
	case '+', '-', '*', '/', '%':
		return true
	}
	return false
}

is_word :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// The operator at `at` has an operand character hard against it on both sides.
unspaced :: proc(text: string, at: int) -> bool {
	if at == 0 || at + 1 >= len(text) {return false}
	before := text[at - 1]
	after := text[at + 1]
	left := is_word(before) || before == ')' || before == ']'
	right := is_word(after) || after == '(' || after == '['
	return left && right
}
