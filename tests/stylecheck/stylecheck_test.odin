package stylecheck_test

import "core:strings"
import "core:testing"
import sc "../../tools/stylecheck"

count :: proc(text: string) -> (operators, widths: int) {
	issues: [dynamic]sc.Issue
	defer delete(issues)
	sc.scan("sample.odin", text, &issues)
	for issue in issues {
		#partial switch issue.rule {
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

design :: proc(path, text: string) -> (radii, sizes: int) {
	issues: [dynamic]sc.Issue
	defer delete(issues)
	if !sc.design_scope(path) {return}
	sc.scan_design(path, text, &issues)
	for issue in issues {
		#partial switch issue.rule {
		case .Design_Radius:
			radii += 1
		case .Design_Text_Size:
			sizes += 1
		}
	}
	return
}

@(test)
design_radius_uses_tokens :: proc(t: ^testing.T) {
	radii, _ := design("C:/repo/src/ui/sample.odin",
		"a := {radius = 6 * scale}\nb := {radius = s}\nc := {radius = 1.5 * s, stroke = s}\nd.radius = w.scale")
	testing.expect_value(t, radii, 4)
	radii, _ = design("C:/repo/src/ui/sample.odin",
		"a := {radius = RADIUS_CONTROL * s}\nb := {radius = pill_radius(r)}\nc := {radius = 0}\n" +
		"d := {radius = radius}\ne := {radius = knob / 2}\nf := {corner_radius = 7}\ng := radius == 3")
	testing.expect_value(t, radii, 0)
}

@(test)
design_text_sizes_come_from_styles :: proc(t: ^testing.T) {
	_, sizes := design("C:/repo/src/tooltip.odin", "text_set_size(&t, 14)\n// text_set_size(&t, 14)")
	testing.expect_value(t, sizes, 1)
	_, sizes = design("C:/repo/src/window.odin", "ui.text_set_size(&w.ui_text, px)")
	testing.expect_value(t, sizes, 0)
}

@(test)
design_rules_cover_interface_code_only :: proc(t: ^testing.T) {
	testing.expect(t, sc.design_scope(`C:\repo\src\ui\menu.odin`))
	testing.expect(t, sc.design_scope("C:/repo/src/tab_strip.odin"))
	testing.expect(t, !sc.design_scope("C:/repo/src/render/render.odin"))
	testing.expect(t, !sc.design_scope("C:/repo/src/ui/design.odin"))
	testing.expect(t, !sc.design_scope("C:/repo/src/ui/text.odin"))
}

@(test)
design_exemptions_name_a_reason :: proc(t: ^testing.T) {
	radii, sizes := design("C:/repo/src/ui/sample.odin",
		"// design-exempt: drawn glyph\ntext_set_size(&s, 9)\nx := {radius = 3 * s} // design-exempt: dot")
	testing.expect_value(t, radii, 0)
	testing.expect_value(t, sizes, 0)
}
