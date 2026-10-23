package term_test

import "core:testing"
import "aio:term"

// A wide glyph is one run of text on its first column and covers its second column with
// nothing; a blank cell reads as a space and trailing blanks are trimmed from the row text.
@(test)
row_map_wide_blank_and_trailing_blanks :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, "\u754ce\u0301 \r\n\u6f22", 6)
	if !ok { return }
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	first, first_err := term.row_map(&s, 0)
	if !testing.expect_value(t, first_err, term.Error.None) { return }
	defer term.row_map_destroy(&first)
	testing.expect_value(t, len(first.columns), 6)
	testing.expect_value(t, first.columns[0], "\u754c")
	testing.expect_value(t, first.columns[1], "")
	testing.expect_value(t, first.columns[2], "e\u0301")
	testing.expect_value(t, first.columns[3], " ")
	testing.expect_value(t, first.columns[5], " ")
	testing.expect_value(t, first.text, "\u754ce\u0301")
	second, second_err := term.row_map(&s, 1)
	if !testing.expect_value(t, second_err, term.Error.None) { return }
	defer term.row_map_destroy(&second)
	testing.expect_value(t, second.columns[0], "\u6f22")
	testing.expect_value(t, second.columns[1], "")
	testing.expect_value(t, second.text, "\u6f22")
}

// A wide glyph that does not fit leaves a spacer head on the previous row: it covers a
// column but displays nothing, so the row text ends at the cells before it.
@(test)
row_map_spacer_head_and_empty_row :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, "abc\u754c\r\n", 4)
	if !ok { return }
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.snapshot_destroy(&s)
	wrapped, wrapped_err := term.row_map(&s, 0)
	if !testing.expect_value(t, wrapped_err, term.Error.None) { return }
	defer term.row_map_destroy(&wrapped)
	testing.expect_value(t, wrapped.columns[3], "")
	testing.expect_value(t, wrapped.text, "abc")
	moved, moved_err := term.row_map(&s, 1)
	if !testing.expect_value(t, moved_err, term.Error.None) { return }
	defer term.row_map_destroy(&moved)
	testing.expect_value(t, moved.columns[0], "\u754c")
	testing.expect_value(t, moved.columns[1], "")
	testing.expect_value(t, moved.text, "\u754c")
	blank, blank_err := term.row_map(&s, 2)
	if !testing.expect_value(t, blank_err, term.Error.None) { return }
	defer term.row_map_destroy(&blank)
	for text in blank.columns {testing.expect_value(t, text, " ")}
	testing.expect_value(t, blank.text, "")
	outside, outside_err := term.row_map(&s, 3)
	defer term.row_map_destroy(&outside)
	testing.expect_value(t, outside_err, term.Error.None)
	testing.expect_value(t, len(outside.columns), 0)
	testing.expect_value(t, outside.text, "")
}
