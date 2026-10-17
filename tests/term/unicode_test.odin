package term_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "aio:ghostty"
import "aio:term"
import fixtures "../fixtures"

// A terminal with the session defaults, holding the snapshot of what was written.
Unicode_Grid :: struct {
	source: Snapshot_Source,
	snapshot: term.Snapshot,
}

unicode_grid :: proc(t: ^testing.T, input: []u8, columns: u16 = 40, rows: u16 = 3) -> (Unicode_Grid, bool) {
	g: Unicode_Grid
	if !testing.expect_value(t, ghostty.terminal_new(nil, &g.source.terminal, columns, rows), ghostty.Result.Success) {
		return {}, false
	}
	if !testing.expect_value(t, ghostty.render_state_new(nil, &g.source.state), ghostty.Result.Success) {
		ghostty.terminal_free(g.source.terminal)
		return {}, false
	}
	if !testing.expect(t, term.apply_mode_defaults(g.source.terminal)) {
		snapshot_source_destroy(&g.source)
		return {}, false
	}
	ghostty.terminal_vt_write(g.source.terminal, raw_data(input), uint(len(input)))
	if !unicode_grid_refresh(t, &g) {
		snapshot_source_destroy(&g.source)
		return {}, false
	}
	return g, true
}

unicode_grid_refresh :: proc(t: ^testing.T, g: ^Unicode_Grid) -> bool {
	term.snapshot_destroy(&g.snapshot)
	if !testing.expect_value(t, ghostty.render_state_update(g.source.state, g.source.terminal), ghostty.Result.Success) {
		return false
	}
	err: term.Error
	g.snapshot, err = term.snapshot(g.source.state)
	return testing.expect_value(t, err, term.Error.None)
}

unicode_grid_destroy :: proc(g: ^Unicode_Grid) {
	term.snapshot_destroy(&g.snapshot)
	snapshot_source_destroy(&g.source)
}

cursor_x :: proc(g: ^Unicode_Grid) -> int {
	x: u16
	_ = ghostty.terminal_get(g.source.terminal, .Cursor_X, &x)
	return int(x)
}

// Describes row 0 as clusters, for failure messages: "[1F468 200D 1F469]w2 [61]w1".
describe_row :: proc(s: ^term.Snapshot, row: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for x in 0..<int(s.columns) {
		c := term.snapshot_cell(s, x, row)
		if c.width == .Spacer_Tail || c.width == .Spacer_Head || c.text == "" { continue }
		strings.write_byte(&b, '[')
		for r, i in c.text {
			if i > 0 { strings.write_byte(&b, ' ') }
			fmt.sbprintf(&b, "%X", r)
		}
		fmt.sbprintf(&b, "]w%d ", c.width == .Wide ? 2 : 1)
	}
	return strings.to_string(b)
}

// Every fixture case lays out as the table expects: cluster boundaries, cell spans, stored
// codepoints, and cursor advance. A failure names the case id and the observed layout.
@(test)
unicode_fixture_layout :: proc(t: ^testing.T) {
	cases, err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, err, "") { return }
	for c in cases {
		g, ok := unicode_grid(t, c.input)
		if !ok { return }
		defer unicode_grid_destroy(&g)
		observed := describe_row(&g.snapshot, 0)
		testing.expectf(t, cursor_x(&g) == fixtures.columns(c),
			"%s: cursor at %d, expected %d; layout %s", c.id, cursor_x(&g), fixtures.columns(c), observed)
		stored: [dynamic]rune
		defer delete(stored)
		x, cluster := 0, 0
		for x < int(g.snapshot.columns) {
			cell := term.snapshot_cell(&g.snapshot, x, 0)
			if cell.text == "" { break }
			width := 1
			if cell.width == .Wide {
				width = 2
				tail := term.snapshot_cell(&g.snapshot, x + 1, 0)
				testing.expectf(t, tail != nil && tail.width == .Spacer_Tail, "%s: wide cell %d has no spacer", c.id, x)
			} else if !testing.expectf(t, cell.width == .Narrow, "%s: unexpected %v at %d", c.id, cell.width, x) {
				break
			}
			if cluster < len(c.widths) {
				testing.expectf(t, c.widths[cluster] == width,
					"%s: cluster %d spans %d cells, expected %d; layout %s", c.id, cluster, width, c.widths[cluster], observed)
			}
			for r in cell.text { append(&stored, r) }
			cluster += 1
			x += width
		}
		testing.expectf(t, cluster == len(c.widths),
			"%s: %d clusters, expected %d; layout %s", c.id, cluster, len(c.widths), observed)
		testing.expectf(t, slice_equal(stored[:], c.stored), "%s: stored %X, expected %X", c.id, stored[:], c.stored)
	}
}

// The width API that overlays such as IME preedit use agrees with the grid for every case (D-042).
@(test)
unicode_width_api_matches_grid :: proc(t: ^testing.T) {
	cases, err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, err, "") { return }
	for c in cases {
		cps := make([]u32, len(c.stored))
		defer delete(cps)
		for r, i in c.stored { cps[i] = u32(r) }
		widths: [dynamic]int
		defer delete(widths)
		for i := 0; i < len(cps); {
			w: u8
			remaining := cps[i:]
			i += int(ghostty.unicode_grapheme_width(raw_data(remaining), uint(len(remaining)), &w))
			append(&widths, int(w))
		}
		testing.expectf(t, slice_equal(widths[:], c.widths), "%s: width API %v, grid table %v", c.id, widths[:], c.widths)
	}
}

// Copying a row returns exactly the stored codepoints, with no normalization or spacer text.
@(test)
unicode_row_text_round_trips :: proc(t: ^testing.T) {
	cases, err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, err, "") { return }
	for c in cases {
		g, ok := unicode_grid(t, c.input)
		if !ok { return }
		defer unicode_grid_destroy(&g)
		text, text_err := term.row_text(&g.snapshot, 0)
		defer delete(text)
		testing.expect_value(t, text_err, term.Error.None)
		expected := utf8.runes_to_string(c.stored)
		defer delete(expected)
		testing.expectf(t, text == expected, "%s: copied %q, expected %q", c.id, text, expected)
	}
}

// Applications may turn grapheme clustering off; a full reset restores the default.
@(test)
unicode_grapheme_mode_is_default :: proc(t: ^testing.T) {
	family :: "\U0001F468\U0000200d\U0001F469\U0000200d\U0001F467"
	g, ok := unicode_grid(t, transmute([]u8)string(family))
	if !ok { return }
	defer unicode_grid_destroy(&g)
	testing.expect_value(t, cursor_x(&g), 2)
	vt_write(g.source.terminal, "\x1b[?2027l\r\n" + family)
	testing.expect_value(t, cursor_x(&g), 6)
	vt_write(g.source.terminal, "\x1bc" + family)
	testing.expect_value(t, cursor_x(&g), 2)
}

// A wide cluster that does not fit at the right edge moves to the next row whole.
@(test)
unicode_wide_wraps_at_edge :: proc(t: ^testing.T) {
	input := "abcd\U0000754c\U0001F469\U0000200d\U0001F4BB"
	g, ok := unicode_grid(t, transmute([]u8)input, 5)
	if !ok { return }
	defer unicode_grid_destroy(&g)
	testing.expect_value(t, term.snapshot_cell(&g.snapshot, 4, 0).width, ghostty.Cell_Wide.Spacer_Head)
	testing.expect_value(t, term.snapshot_cell(&g.snapshot, 0, 1).text, "\U0000754c")
	testing.expect_value(t, term.snapshot_cell(&g.snapshot, 0, 1).width, ghostty.Cell_Wide.Wide)
	testing.expect_value(t, term.snapshot_cell(&g.snapshot, 2, 1).text, "\U0001F469\U0000200d\U0001F4BB")
	testing.expect_value(t, term.snapshot_cell(&g.snapshot, 2, 1).width, ghostty.Cell_Wide.Wide)
}

// Writing every case on one line and resizing through each width never leaves a wide cell
// without its spacer, a spacer without its wide cell, or a lost codepoint.
@(test)
unicode_resize_keeps_clusters_whole :: proc(t: ^testing.T) {
	cases, err := fixtures.unicode_cases()
	defer fixtures.unicode_cases_destroy(cases)
	if !testing.expect_value(t, err, "") { return }
	line: [dynamic]u8
	defer delete(line)
	expected: [dynamic]rune
	defer delete(expected)
	for c in cases {
		append(&line, ..c.input)
		append(&line, ' ')
		append(&expected, ..c.stored)
	}
	g, ok := unicode_grid(t, line[:], 80, 300)
	if !ok { return }
	defer unicode_grid_destroy(&g)
	for columns in ([]u16{80, 7, 3, 2, 13, 41, 120}) {
		testing.expect_value(t, ghostty.terminal_resize(g.source.terminal, columns, 300, 8, 16), ghostty.Result.Success)
		if !unicode_grid_refresh(t, &g) { return }
		stored: [dynamic]rune
		defer delete(stored)
		s := &g.snapshot
		for row in 0..<int(s.rows) {
			for x in 0..<int(s.columns) {
				c := term.snapshot_cell(s, x, row)
				switch c.width {
				case .Wide:
					next := term.snapshot_cell(s, x + 1, row)
					testing.expectf(t, next != nil && next.width == .Spacer_Tail, "%d columns: wide at %d,%d lacks a spacer", columns, x, row)
				case .Spacer_Tail:
					previous := term.snapshot_cell(s, x - 1, row)
					testing.expectf(t, previous != nil && previous.width == .Wide, "%d columns: orphan spacer at %d,%d", columns, x, row)
				case .Spacer_Head:
					testing.expectf(t, x == int(s.columns) - 1, "%d columns: spacer head at %d,%d", columns, x, row)
				case .Narrow:
				}
				for r in c.text {
					if r != ' ' { append(&stored, r) }
				}
			}
		}
		without_spaces: [dynamic]rune
		defer delete(without_spaces)
		for r in expected {
			if r != ' ' { append(&without_spaces, r) }
		}
		testing.expectf(t, slice_equal(stored[:], without_spaces[:]), "%d columns: codepoints lost or reordered", columns)
	}
}

slice_equal :: proc(a, b: []$T) -> bool {
	if len(a) != len(b) { return false }
	for v, i in a {
		if v != b[i] { return false }
	}
	return true
}

vt_write :: proc(terminal: ghostty.Terminal, s: string) {
	ghostty.terminal_vt_write(terminal, raw_data(s), uint(len(s)))
}
