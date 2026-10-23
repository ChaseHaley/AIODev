package control_test

import "core:testing"
import "aio:ghostty"
import "aio:term"

// A match may begin inside a wide cell and continue into the next one; it is reported at
// the first cell's column, and a wide cell covers its columns once rather than once per
// column.
@(test)
text_match_inside_wide_cell :: proc(t: ^testing.T) {
	s, ok := source(t, "\x1b[2 q\u754c\U0001F469\u200D\U0001F4BB hi", 20)
	if !ok { return }
	defer term.snapshot_destroy(&s)
	wide := term.snapshot_cell(&s, 2, 0)
	if !testing.expect(t, wide != nil && wide.width == ghostty.Cell_Wide.Wide) { return }
	testing.expect_value(t, wide.text, "\U0001F469\u200D")
	check_expect(t, &s, {"expect", "text", "\u200D\U0001F4BB"},
		"PASS text \"\u200D\U0001F4BB\" at 2,0\n", true)
	check_expect(t, &s, {"expect", "text", "\U0001F4BB"},
		"PASS text \"\U0001F4BB\" at 4,0\n", true)
	check_expect(t, &s, {"expect", "text", "hi"}, "PASS text \"hi\" at 7,0\n", true)
	check_expect(t, &s, {"expect", "no-text", "\u200D\U0001F4BB"},
		"FAIL no-text \"\u200D\U0001F4BB\" found at 2,0\n", false)
}
