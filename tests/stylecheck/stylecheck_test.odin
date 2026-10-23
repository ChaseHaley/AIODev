package stylecheck_test

import "core:strings"
import "core:testing"
import sc "../../tools/stylecheck"

count :: proc(text: string) -> (operators, widths: int) {
	issues: [dynamic]sc.Issue
	defer delete(issues)
	sc.scan("sample.odin", text, &issues)
	for issue in issues {
		switch issue.rule {
		case .Unspaced_Operator:
			operators += 1
		case .Line_Width:
			widths += 1
		}
	}
	return
}

@(test)
operator_spacing :: proc(t: ^testing.T) {
	operators, _ := count("x := a+b\ny := c*d\nz := e/f\nw := g%h\nv := (i+1)*(j-2)")
	testing.expect_value(t, operators, 7)
	operators, _ = count("x := a + b\ny := c * d\nz := e / f\nw := g % h")
	testing.expect_value(t, operators, 0)
}

@(test)
unary_operators_are_not_binary :: proc(t: ^testing.T) {
	operators, _ := count("x := -1\ny := f(-1)\nz := a * -1\nw := {-2, -3}\nv := a-1")
	testing.expect_value(t, operators, 1)
}

@(test)
literals_and_comments_are_skipped :: proc(t: ^testing.T) {
	operators, _ := count("s := \"a+b\"\nr := `c*d`\nch := '-'\n// e/f\n/* g%h */\nok := true")
	testing.expect_value(t, operators, 0)
}

@(test)
escaped_quote_ends_the_string_scan_late :: proc(t: ^testing.T) {
	operators, _ := count("s := \"a\\\"+b\"\nx := 1+2")
	testing.expect_value(t, operators, 1)
}

@(test)
line_width :: proc(t: ^testing.T) {
	exact := strings.concatenate({"// ", strings.repeat("x", 107, context.temp_allocator)}, context.temp_allocator)
	_, widths := count(exact)
	testing.expect_value(t, widths, 0)
	_, widths = count(strings.concatenate({exact, "x"}, context.temp_allocator))
	testing.expect_value(t, widths, 1)
}

@(test)
carriage_return_is_not_a_column :: proc(t: ^testing.T) {
	line := strings.concatenate({"// ", strings.repeat("x", 107, context.temp_allocator)}, context.temp_allocator)
	_, widths := count(strings.concatenate({line, "\r\n", line, "\r\n"}, context.temp_allocator))
	testing.expect_value(t, widths, 0)
}

@(test)
raw_string_lines_are_content :: proc(t: ^testing.T) {
	long := strings.repeat("x", 120, context.temp_allocator)
	text := strings.concatenate({"s := `", "\n", long, "\n", "`\n", "x := 1+2"}, context.temp_allocator)
	operators, widths := count(text)
	testing.expect_value(t, widths, 0)
	testing.expect_value(t, operators, 1)
}

@(test)
fix_inserts_spaces_only_around_operators :: proc(t: ^testing.T) {
	testing.expect_value(t, sc.fix_text("x := a+b"), "x := a + b")
	testing.expect_value(t, sc.fix_text("v := (p+n)%(n+1)"), "v := (p + n) % (n + 1)")
	testing.expect_value(t, sc.fix_text("n := (x+1)*2-3"), "n := (x + 1) * 2 - 3")
}

@(test)
fix_leaves_literals_and_comments_alone :: proc(t: ^testing.T) {
	text := "s := \"a+b\" // c+d\nr := `e*f`\n"
	testing.expect_value(t, sc.fix_text(text), text)
}

@(test)
fix_is_idempotent :: proc(t: ^testing.T) {
	once := sc.fix_text("x := a+b*c")
	testing.expect_value(t, sc.fix_text(once), once)
	testing.expect_value(t, once, "x := a + b * c")
}
