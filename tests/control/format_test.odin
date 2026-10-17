package control_test

import "core:strings"
import "core:testing"
import "aio:control"
import "aio:ghostty"
import "aio:term"

source :: proc(
	t: ^testing.T, text: string, columns: u16 = 12, rows: u16 = 4,
	selected: bool = false, scroll: int = 0,
) -> (term.Snapshot, bool) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, columns, rows), ghostty.Result.Success) {
		return {}, false
	}
	defer ghostty.terminal_free(terminal)
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), ghostty.Result.Success) {
		return {}, false
	}
	defer ghostty.render_state_free(state)
	ghostty.terminal_vt_write(terminal, raw_data(text), uint(len(text)))
	if selected {
		selection := ghostty.sized(ghostty.Selection)
		if !testing.expect_value(t, ghostty.terminal_select_all(terminal, &selection),
		                         ghostty.Result.Success) {
			return {}, false
		}
		if !testing.expect_value(t, ghostty.terminal_set(terminal, .Selection, &selection),
		                         ghostty.Result.Success) {
			return {}, false
		}
	}
	if scroll != 0 { ghostty.terminal_scroll_viewport(terminal, {tag = .Delta, value = {delta = scroll}}) }
	if !testing.expect_value(t, ghostty.render_state_update(state, terminal), ghostty.Result.Success) {
		return {}, false
	}
	s, err := term.snapshot(state)
	return s, testing.expect_value(t, err, term.Error.None)
}

check_expect :: proc(t: ^testing.T, s: ^term.Snapshot, args: []string, expected: string, pass: bool) {
	r, err := control.parse(args)
	defer control.request_destroy(&r)
	if !testing.expect_value(t, err.advice, "") { return }
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	passed, failure := control.evaluate(&b, r.(control.Expect), s)
	testing.expect_value(t, failure, control.Error.None)
	testing.expect_value(t, passed, pass)
	testing.expect_value(t, strings.to_string(b), expected)
}

@(test)
screen_cells_and_expectations :: proc(t: ^testing.T) {
	s, ok := source(t, "hello\r\nhi\x1b[2 q")
	if !ok { return }
	defer term.snapshot_destroy(&s)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, control.format_screen(&b, &s), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "screen 12x4 cursor 2,1\n0|hello\n1|hi\n2-3 blank\n")
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_screen(&b, &s, {1, 2, true}), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "screen 12x4 cursor 2,1\n1|hi\n2 blank\n")
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_cells(&b, &s, {0, {}}), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "row 0 cols 0-11\n0-4 \"hello\"\n5-11 blank\n")
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_cells(&b, &s, {0, {1, 3, true}}), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "row 0 cols 1-3\n1-3 \"ell\"\n")
	check_expect(t, &s, {"expect", "text", "hi"}, "PASS text \"hi\" at 0,1\n", true)
	check_expect(t, &s, {"expect", "no-text", "bye"}, "PASS no-text \"bye\"\n", true)
	check_expect(t, &s, {"expect", "no-text", "hi"}, "FAIL no-text \"hi\" found at 0,1\n", false)
	check_expect(t, &s, {"expect", "text", "done"},
		"FAIL text \"done\" not on screen; last rows: 0|hello 1|hi\n", false)
	check_expect(t, &s, {"expect", "cursor", "2,1"}, "PASS cursor 2,1\n", true)
	check_expect(t, &s, {"expect", "cursor", "0,0"}, "FAIL cursor 0,0: observed cursor 2,1\n", false)
	check_expect(t, &s, {"expect", "cell", "0,1", "text=h", "fg=default", "bold=false"},
		"PASS cell 0,1 \"h\"\n", true)
	check_expect(t, &s, {"expect", "cell", "0,1", "underline=single"},
		"FAIL cell 0,1 underline: expected single, observed none; cell \"h\" fg=#ffffff\n", false)
	check_expect(t, &s, {"expect", "cell", "99,1", "text=h"}, "FAIL cell 99,1 off-screen\n", false)
	testing.expect_value(t, control.format_screen(&b, &s, {0, 4, true}), control.Error.Invalid_Argument)
	testing.expect_value(t, control.format_cells(&b, &s, {4, {}}), control.Error.Invalid_Argument)
	testing.expect_value(t, control.format_cells(&b, &s, {0, {2, 1, true}}), control.Error.Invalid_Argument)
}

@(test)
attributes_wide_and_colors :: proc(t: ^testing.T) {
	s, ok := source(t,
		"\x1b[1;2;3;5;7;8;9;53mA\x1b[0m" +
		"\x1b[4mB\x1b[21mC\x1b[4:3mD\x1b[4:4mE\x1b[4:5;58:5:42mF\x1b[0m" +
		"\x1b[38;2;255;0;0;48;2;0;0;200mG\x1b[0m\u6f22" +
		"\x1b]4;42;#e06c75\x07\x1b[2 q")
	if !ok { return }
	defer term.snapshot_destroy(&s)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, control.format_cells(&b, &s, {0, {}}), control.Error.None)
	testing.expect_value(t, strings.to_string(b),
		"row 0 cols 0-11\n" +
		"0 \"A\" bold italic faint blink inverse invisible strike overline\n" +
		"1 \"B\" underline=single\n2 \"C\" underline=double\n3 \"D\" underline=curly\n" +
		"4 \"E\" underline=dotted\n5 \"F\" underline=dashed underline-color=#e06c75\n" +
		"6 \"G\" fg=#ff0000 bg=#0000c8\n7-8 \"\u6f22\" wide\n9-11 blank\n")
	check_expect(t, &s, {"expect", "cell", "0,0", "bold=true", "italic=true", "faint=true", "blink=true",
		"inverse=true", "invisible=true", "strike=true", "overline=true", "selected=false", "wide=false"},
		"PASS cell 0,0 \"A\" bold italic faint blink inverse invisible strike overline\n", true)
	check_expect(t, &s, {"expect", "cell", "5,0", "underline-color=#E06C75"},
		"PASS cell 5,0 \"F\" underline=dashed underline-color=#e06c75\n", true)
	check_expect(t, &s, {"expect", "cell", "6,0", "fg=#ff0000", "bg=#0000c8"},
		"PASS cell 6,0 \"G\" fg=#ff0000 bg=#0000c8\n", true)
	check_expect(t, &s, {"expect", "text", "\u6f22"}, "PASS text \"\u6f22\" at 7,0\n", true)
	selected, selected_ok := source(t, "\u6f22", selected = true)
	if !selected_ok { return }
	defer term.snapshot_destroy(&selected)
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_cells(&b, &selected, {0, {0, 1, true}}), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "row 0 cols 0-1\n0-1 \"\u6f22\" selected wide\n")
}

@(test)
cursor_blanks_escaping_and_state :: proc(t: ^testing.T) {
	s, ok := source(t, "\x1b[?25l\x1b[5 q", 4, 12)
	if !ok { return }
	defer term.snapshot_destroy(&s)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, control.format_screen(&b, &s), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "screen 4x12 cursor 0,0 hidden blinking\n0-11 blank\n")
	s.cursor.viewport_has_value = false
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_screen(&b, &s), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "screen 4x12 cursor off-screen\n0-11 blank\n")
	s.cells[0].text = "\"\\\x01\x7f"
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_cells(&b, &s, {0, {}}), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "row 0 cols 0-3\n0 \"\\\"\\\\\\x01\\x7f\"\n1-3 blank\n")
	entries := []control.State_Entry{{"palette.open", "false"}, {"palette.query", "a \"b\""}, {"empty", ""}}
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_state(&b, entries), control.Error.None)
	testing.expect_value(t, strings.to_string(b),
		"palette.open=false\npalette.query=\"a \\\"b\\\"\"\nempty=\"\"\n")
	for test in ([3]struct { key, value, output: string, pass: bool }{
		{"palette.open", "false", "PASS state palette.open=false\n", true},
		{"palette.open", "true", "FAIL state palette.open: expected \"true\", observed \"false\"\n", false},
		{"missing", "", "FAIL state missing: expected \"\", observed \"<missing>\"\n", false},
	}) {
		strings.builder_reset(&b)
		pass, err := control.evaluate(&b, {kind = .State, key = test.key, value = test.value}, nil, entries)
		testing.expect_value(t, err, control.Error.None)
		testing.expect_value(t, pass, test.pass)
		testing.expect_value(t, strings.to_string(b), test.output)
	}
	failing := strings.builder_make(failing_allocator())
	defer strings.builder_destroy(&failing)
	testing.expect_value(t, control.format_state(&failing, entries), control.Error.Out_Of_Memory)
	testing.expect_value(t, control.format_screen(&failing, &s), control.Error.Out_Of_Memory)
	testing.expect_value(t, control.format_cells(&failing, &s, {0, {}}), control.Error.Out_Of_Memory)
	testing.expect_value(t, control.help(&failing), control.Error.Out_Of_Memory)
	testing.expect_value(t, control.format_screen(&b, nil), control.Error.Invalid_Argument)
	testing.expect_value(t, control.format_cells(&b, nil, {}), control.Error.Invalid_Argument)
}

@(test)
row_alignment_scrollback_and_palette_colors :: proc(t: ^testing.T) {
	s, ok := source(t, "a\x1b[11;1Hz\x1b[2 q", 4, 12)
	if !ok { return }
	defer term.snapshot_destroy(&s)
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	testing.expect_value(t, control.format_screen(&b, &s), control.Error.None)
	testing.expect_value(t, strings.to_string(b),
		"screen 4x12 cursor 1,10\n 0|a\n1-9 blank\n10|z\n11 blank\n")
	history, history_ok := source(t, "0\r\n1\r\n2\r\n3\r\n4", 4, 3, scroll = -1)
	if !history_ok { return }
	defer term.snapshot_destroy(&history)
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_screen(&b, &history), control.Error.None)
	testing.expect_value(t, strings.to_string(b), "screen 4x3 cursor off-screen\n0|1\n1|2\n2|3\n")
	colors, colors_ok := source(t,
		"\x1b]4;42;#abcdef\x07\x1b[38;5;42;48;5;42;4;58:2::1:2:3mXe\u0301")
	if !colors_ok { return }
	defer term.snapshot_destroy(&colors)
	strings.builder_reset(&b)
	testing.expect_value(t, control.format_cells(&b, &colors, {0, {0, 1, true}}), control.Error.None)
	testing.expect_value(t, strings.to_string(b),
		"row 0 cols 0-1\n0-1 \"Xe\u0301\" fg=#abcdef bg=#abcdef underline=single underline-color=#010203\n")
	check_expect(t, &colors, {"expect", "text", "\u0301"}, "PASS text \"\u0301\" at 1,0\n", true)
}

@(test)
value_formatting :: proc(t: ^testing.T) {
	Fixture :: struct { value, expected: string }
	for f in ([]Fixture{
		{`C:\Users\me\logs`, `C:\Users\me\logs`},
		{`C:\My Files\logs`, `"C:\My Files\logs"`},
		{"", `""`}, {"true", "true"}, {"a\"b", `"a\"b"`},
		{"a\tb\nc\r\x00\x7f", `"a\x09b\x0ac\x0d\x00\x7f"`},
		{"é漢", "é漢"},
	}) {
		out := strings.builder_make()
		testing.expect_value(t, control.format_value(&out, f.value), control.Error.None)
		testing.expect_value(t, strings.to_string(out), f.expected)
		strings.builder_destroy(&out)
	}
	out := strings.builder_make(failing_allocator())
	defer strings.builder_destroy(&out)
	testing.expect_value(t, control.format_value(&out, "x"), control.Error.Out_Of_Memory)
}