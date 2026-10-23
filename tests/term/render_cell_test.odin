package term_test

import "core:testing"
import "aio:ghostty"
import "aio:term"

// The frame reader and the snapshot reader must describe the same cells: one field list supplies
// both, and the codepoint span used for shaping must match the UTF-8 text the snapshot keeps.
@(test)
render_cell_frame_and_snapshot_agree :: proc(t: ^testing.T) {
	input :=
		"\x1b[1;38;5;123;48;2;4;5;6mA\x1b[0m" + "\u754ce\u0301" + "\x1b[7;2mB\x1b[0m"
	source, ok := snapshot_source(t, input, 8)
	if !ok {return}
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) {return}
	defer term.snapshot_destroy(&s)
	rows: ghostty.Render_State_Row_Iterator
	if !testing.expect_value(
		t,
		ghostty.render_state_row_iterator_new(nil, &rows),
		ghostty.Result.Success,
	) {return}
	defer ghostty.render_state_row_iterator_free(rows)
	cells: ghostty.Render_State_Row_Cells
	if !testing.expect_value(
		t,
		ghostty.render_state_row_cells_new(nil, &cells),
		ghostty.Result.Success,
	) {return}
	defer ghostty.render_state_row_cells_free(cells)
	testing.expect_value(
		t,
		ghostty.render_state_get(source.state, .Row_Iterator, &rows),
		ghostty.Result.Success,
	)
	codepoints: [dynamic]u32
	defer delete(codepoints)
	utf8: [dynamic]u8
	defer delete(utf8)
	seen: int
	for ghostty.render_state_row_iterator_next(rows) {
		y: i32
		testing.expect_value(
			t,
			ghostty.render_state_row_get(rows, .Viewport_Y, &y),
			ghostty.Result.Success,
		)
		if y < 0 || y >= i32(s.rows) {continue}
		testing.expect_value(
			t,
			ghostty.render_state_row_get(rows, .Cells, &cells),
			ghostty.Result.Success,
		)
		for x in 0 ..< int(s.columns) {
			testing.expect_value(
				t,
				ghostty.render_state_row_cells_select(cells, u16(x)),
				ghostty.Result.Success,
			)
			cell := term.read_render_cell(cells)
			clear(&codepoints)
			span, span_err := term.render_cell_graphemes(cells, cell.width, &codepoints)
			testing.expect_value(t, span_err, term.Error.None)
			clear(&utf8)
			text, text_err := term.render_cell_graphemes(cells, cell.width, &utf8)
			testing.expect_value(t, text_err, term.Error.None)
			expected := term.snapshot_cell(&s, x, int(y))
			if !testing.expect(t, expected != nil) {continue}
			testing.expect_value(t, cell.width, expected.width)
			testing.expect_value(t, cell.style, expected.style)
			if rgb, has := cell.foreground.?; has {
				foreground: Maybe(term.Color) = term.Color{rgb.r, rgb.g, rgb.b}
				testing.expect_value(t, foreground, expected.foreground)
			} else {
				testing.expect(t, expected.foreground == nil)
			}
			if rgb, has := cell.background.?; has {
				background: Maybe(term.Color) = term.Color{rgb.r, rgb.g, rgb.b}
				testing.expect_value(t, background, expected.background)
			} else {
				testing.expect(t, expected.background == nil)
			}
			testing.expect_value(t, string(text), expected.text)
			runes: [16]rune
			count := 0
			for r in expected.text {
				runes[count] = r
				count += 1
			}
			if !testing.expect_value(t, len(span), count) {continue}
			for r, i in runes[:count] {
				testing.expect_value(t, span[i], u32(r))
			}
			seen += 1
		}
	}
	testing.expect_value(t, seen, len(s.cells))
}

// A cell with no styling, colour, width or text reports the documented fallback: the default
// style, narrow width, no colour and an empty span. Spacer halves never report text.
@(test)
render_cell_absent_values_fall_back :: proc(t: ^testing.T) {
	source, ok := snapshot_source(t, "abc\u754c", 4)
	if !ok {return}
	defer snapshot_source_destroy(&source)
	s, err := term.snapshot(source.state)
	if !testing.expect_value(t, err, term.Error.None) {return}
	defer term.snapshot_destroy(&s)
	rows: ghostty.Render_State_Row_Iterator
	if !testing.expect_value(
		t,
		ghostty.render_state_row_iterator_new(nil, &rows),
		ghostty.Result.Success,
	) {return}
	defer ghostty.render_state_row_iterator_free(rows)
	cells: ghostty.Render_State_Row_Cells
	if !testing.expect_value(
		t,
		ghostty.render_state_row_cells_new(nil, &cells),
		ghostty.Result.Success,
	) {return}
	defer ghostty.render_state_row_cells_free(cells)
	testing.expect_value(
		t,
		ghostty.render_state_get(source.state, .Row_Iterator, &rows),
		ghostty.Result.Success,
	)
	testing.expect(t, ghostty.render_state_row_iterator_next(rows))
	testing.expect_value(
		t,
		ghostty.render_state_row_get(rows, .Cells, &cells),
		ghostty.Result.Success,
	)
	codepoints: [dynamic]u32
	defer delete(codepoints)
	testing.expect_value(
		t,
		ghostty.render_state_row_cells_select(cells, 0),
		ghostty.Result.Success,
	)
	bare := term.read_render_cell(cells)
	testing.expect(t, ghostty.style_is_default(&bare.style))
	testing.expect_value(t, bare.width, ghostty.Cell_Wide.Narrow)
	testing.expect(t, bare.foreground == nil && bare.background == nil)
	span, span_err := term.render_cell_graphemes(cells, bare.width, &codepoints)
	testing.expect_value(t, span_err, term.Error.None)
	if testing.expect_value(t, len(span), 1) {
		testing.expect_value(t, span[0], u32('a'))
	}
	clear(&codepoints)
	testing.expect_value(
		t,
		ghostty.render_state_row_cells_select(cells, 3),
		ghostty.Result.Success,
	)
	spacer := term.read_render_cell(cells)
	testing.expect_value(t, spacer.width, ghostty.Cell_Wide.Spacer_Head)
	spacer_span, spacer_err := term.render_cell_graphemes(cells, spacer.width, &codepoints)
	testing.expect_value(t, spacer_err, term.Error.None)
	testing.expect_value(t, len(spacer_span), 0)
}
