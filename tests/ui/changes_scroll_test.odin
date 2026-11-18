package ui_test

import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:turns"
import "aio:ui"
import "core:math"
import "core:strings"
import "core:testing"

@(private = "file")
Scroll_Fixture :: struct {
	device:           ^render.Device,
	fonts:            ^font.System,
	cache:            glyphs.Cache,
	text, mono:       ui.Text,
	short, long:      [3]turns.Diff_Line,
	hunks:            [2]turns.Hunk,
	files:            [2]turns.Diff_File,
	removed, added:   string,
	theme:            ui.Theme,
}

// Two files. a.odin has short lines only. b.odin has a context line, a removed line of 250 columns and the
// added line that replaces it, 300 columns of digits, and a long function name after its hunk's @@.
@(private = "file")
scroll_make :: proc(t: ^testing.T, f: ^Scroll_Fixture, view: ^ui.Changes_View) -> bool {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return false}
	f.device = device
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		render.device_destroy(device)
		return false
	}
	glyphs.init(&f.cache, f.fonts, device)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &f.cache, 13)) {
		glyphs.destroy(&f.cache)
		font.system_destroy(f.fonts)
		render.device_destroy(device)
		return false
	}
	f.mono = ui.text_mono(&f.text, f.text.family)
	f.removed = strings.repeat("0", 250, context.temp_allocator)
	f.added = strings.repeat("0", 300, context.temp_allocator)
	f.short = {
		{kind = .Context, old_line = 1, new_line = 1, text = "short"},
		{kind = .Added, new_line = 2, text = "tiny"},
		{},
	}
	f.long = {
		{kind = .Context, old_line = 1, new_line = 1, text = "short"},
		{kind = .Removed, old_line = 2, text = f.removed},
		{kind = .Added, new_line = 2, text = f.added},
	}
	f.hunks = {
		{old_start = 1, old_count = 1, new_start = 1, new_count = 2, lines = f.short[:2]},
		{
			old_start = 1,
			old_count = 2,
			new_start = 1,
			new_count = 2,
			section = strings.repeat("section_", 25, context.temp_allocator),
			lines = f.long[:],
		},
	}
	f.files = {
		{old_path = "a.odin", new_path = "a.odin", status = .Modified, added = 1, hunks = f.hunks[:1]},
		{old_path = "b.odin", new_path = "b.odin", status = .Modified, added = 1, removed = 1, hunks = f.hunks[1:]},
	}
	view^ = {
		scope    = .Uncommitted,
		first    = -1,
		last     = -1,
		files    = f.files[:],
		editing  = -1,
		revision = 1,
	}
	f.theme.text = {1, 1, 1, 1}
	return true
}

@(private = "file")
scroll_destroy :: proc(f: ^Scroll_Fixture) {
	glyphs.destroy(&f.cache)
	font.system_destroy(f.fonts)
	render.device_destroy(f.device)
}

@(private = "file")
scroll_lay_out :: proc(
	f: ^Scroll_Fixture, view: ^ui.Changes_View, state: ^ui.Changes_State, width: f32 = 900,
) -> ui.Changes_Geometry {
	g := ui.changes_geometry({0, 0, width, 600}, 1, view, &f.text, state)
	ui.changes_layout(state, view, &f.text, &f.mono, g.diff.width, 1)
	return g
}

@(private = "file")
scroll_draw :: proc(
	t: ^testing.T, f: ^Scroll_Fixture, view: ^ui.Changes_View, state: ^ui.Changes_State, g: ui.Changes_Geometry,
	list: ^render.Draw_List,
) {
	render.draw_list_reset(list)
	testing.expect_value(t, render.push_layer(list, g.area), render.Error.None)
	status, _ := ui.changes_draw(list, &f.text, &f.mono, &f.theme, g, view, state, 1, {-1, -1}, 0)
	testing.expect_value(t, status, render.Build_Status.Ok)
}

// The glyphs drawn inside row `row`'s height, at or right of `from`: where the first starts and the last
// ends, and how many.
@(private = "file")
scroll_row_glyphs :: proc(
	list: ^render.Draw_List, row: render.Rect, from: f32,
) -> (
	first, last: f32,
	count: int,
) {
	first = max(f32)
	for glyph in list.glyphs {
		if glyph.rect.y < row.y || glyph.rect.y >= row.y + row.height || glyph.rect.x < from {continue}
		first, last = min(first, glyph.rect.x), max(last, glyph.rect.x + glyph.rect.width)
		count += 1
	}
	return
}

@(test)
a_long_line_scrolls_to_its_end_and_nothing_fades :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := scroll_lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	digit := ui.text_width(&f.mono, "0")

	// The added line of b.odin is flat line 2 of file 1.
	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 2)
	row := ui.changes_line_rect(g, &view, &state, 1, 2)
	right := column.text_x + column.width
	scroll_draw(t, &f, &view, &state, g, &list)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}
	first, last, count := scroll_row_glyphs(&list, row, column.text_x - 1)
	testing.expect(t, count > 0)
	testing.expect(t, last <= right + 1.5, "the text stays inside its cell")
	from, to, _ := ui.changes_line_visible(g, &view, &state, &f.mono, 1, 2)
	testing.expect_value(t, from, 0)
	testing.expect(t, to < len(f.added), "the end of the line is out of reach before scrolling")

	// Scrolling stops at the widest line: the last column is the line's last character.
	limit, shown := ui.changes_h_extent(g, &view, &state)
	wanted := int(math.ceil((300 * digit - column.width) / digit - 0.01))
	testing.expect_value(t, limit, wanted)
	testing.expect(t, shown > 0)
	testing.expect(t, ui.changes_scroll_columns(&state, g, &view, 100_000))
	testing.expect_value(t, state.h_scroll, limit)
	testing.expect(t, !ui.changes_scroll_columns(&state, g, &view, 1))
	from, to, _ = ui.changes_line_visible(g, &view, &state, &f.mono, 1, 2)
	testing.expect_value(t, from, limit)
	testing.expect_value(t, to, len(f.added))
	scroll_draw(t, &f, &view, &state, g, &list)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}
	first, last, count = scroll_row_glyphs(&list, row, column.text_x - 1)
	testing.expect_value(t, count, 300 - limit)
	testing.expect(t, abs(first - column.text_x) <= 1.5, "the first column shown starts at the text")
	testing.expect(t, last <= right + 1.5 && last >= right - 2 * digit, "the end of the line is in view")

	// The short file has nothing to scroll and stays put, with its numbers and sign where they were.
	_, short, _ := ui.changes_line_code(g, &view, &state, &f.mono, 0, 1)
	testing.expect_value(t, short.scroll, 0)
	_, scrolled, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 2)
	testing.expect_value(t, scrolled.scroll, f32(limit) * digit)
	testing.expect_value(t, scrolled.text_x, column.text_x)
	testing.expect_value(t, scrolled.sign_x, column.sign_x)

	// A narrower pane needs more columns; the same offset serves both layouts of a file.
	narrow := scroll_lay_out(&f, &view, &state, 500)
	more, _ := ui.changes_h_extent(narrow, &view, &state)
	testing.expect(t, more > limit)
	_ = ui.changes_scroll_columns(&state, narrow, &view, 0)
	testing.expect(t, state.h_scroll <= more)
}

@(test)
a_press_in_a_scrolled_line_lands_on_the_character_under_it :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := scroll_lay_out(&f, &view, &state)
	digit := ui.text_width(&f.mono, "0")
	testing.expect(t, ui.changes_scroll_columns(&state, g, &view, 50))
	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 2)

	// Column 50 of the line is at the text's left edge, and each digit is a column to the right.
	at, _, ok := ui.changes_text_point(g, &view, &state, &f.mono, 1, 2, column.text_x + 3.4 * digit)
	testing.expect(t, ok)
	testing.expect_value(t, at, 53)
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 1, 2, column.text_x + 3.6 * digit)
	testing.expect_value(t, at, 54)
	// Left of the text, over the numbers, is the first column shown; past the room, the last.
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 1, 2, column.text_x - 20)
	testing.expect_value(t, at, 50)
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 1, 2, column.text_x + column.width + 40)
	_, to, _ := ui.changes_line_visible(g, &view, &state, &f.mono, 1, 2)
	testing.expect_value(t, at, to)
	testing.expect(t, at > 50)

	// A byte maps to x and back the same way, and one scrolled out of sight sits at an edge.
	testing.expect(t, abs(ui.code_x_of(&f.mono, f.added, column.width, 53, column.scroll) - 3 * digit) < 0.01)
	testing.expect_value(t, ui.code_x_of(&f.mono, f.added, column.width, 10, column.scroll), 0)
	testing.expect_value(t, ui.code_x_of(&f.mono, f.added, column.width, 299, column.scroll), column.width)
	testing.expect_value(t, ui.code_offset_at(&f.mono, f.added, column.width, 3 * digit, column.scroll), 53)
}

@(test)
side_by_side_pairs_scroll_together :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	view.side_by_side = true
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := scroll_lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	digit := ui.text_width(&f.mono, "0")

	// The removed line and the added line that replaces it share a row.
	removed := ui.changes_line_rect(g, &view, &state, 1, 1)
	added := ui.changes_line_rect(g, &view, &state, 1, 2)
	testing.expect_value(t, removed.y, added.y)
	testing.expect(t, removed.x < added.x)

	limit, _ := ui.changes_h_extent(g, &view, &state)
	testing.expect(t, limit > 0)
	testing.expect(t, ui.changes_scroll_columns(&state, g, &view, 7))
	_, left, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 1)
	_, right, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 2)
	testing.expect_value(t, left.scroll, 7 * digit)
	testing.expect_value(t, right.scroll, left.scroll)

	// Nothing is drawn between the end of the left half's text and the start of the right half's numbers.
	scroll_draw(t, &f, &view, &state, g, &list)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}
	gap_start, gap_end := left.text_x + left.width + 1.5, right.old_x
	count := 0
	for glyph in list.glyphs {
		if glyph.rect.y < removed.y || glyph.rect.y >= removed.y + removed.height {continue}
		count += 1
		spills := glyph.rect.x < gap_end && glyph.rect.x + glyph.rect.width > gap_start
		testing.expect(t, !spills, "no code glyph crosses into the other half")
	}
	testing.expect(t, count > 0)

	// To the end of the longer line, both halves reach it.
	testing.expect(t, ui.changes_scroll_columns(&state, g, &view, 100_000))
	_, removed_to, _ := ui.changes_line_visible(g, &view, &state, &f.mono, 1, 1)
	_, added_to, _ := ui.changes_line_visible(g, &view, &state, &f.mono, 1, 2)
	testing.expect_value(t, added_to, len(f.added))
	testing.expect_value(t, removed_to, len(f.removed))
}

@(test)
a_hunk_header_scrolls_with_its_code_and_keeps_inside_its_room :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := scroll_lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	line := ui.changes_line_rect(g, &view, &state, 1, 0)
	header := render.Rect{line.x, line.y - f32(state.rows.hunk), line.width, f32(state.rows.hunk)}
	left := header.x + 8
	right := header.x + header.width - 8 - f32(state.rows.hunk) - 4

	scroll_draw(t, &f, &view, &state, g, &list)
	first, last, count := scroll_row_glyphs(&list, header, header.x)
	testing.expect(t, count > 0)
	testing.expect(t, abs(first - left) <= 1.5)
	testing.expect(t, last <= right + 1.5)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}

	// Scrolled past the "@@ -1,2 +1,2 @@ " label, only the section is left, and it still starts at the edge.
	testing.expect(t, ui.changes_scroll_columns(&state, g, &view, 20))
	scroll_draw(t, &f, &view, &state, g, &list)
	first, last, count = scroll_row_glyphs(&list, header, header.x)
	testing.expect(t, count > 0)
	testing.expect(t, first >= left - 1.5 && first - left <= 2 * ui.text_width(&f.mono, "0"))
	testing.expect(t, last <= right + 1.5)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}
}

// In a monospace font printable ASCII is counted by byte, so a line of a million columns is exact and fast.
// Without one installed the lookups run rune by rune, and the line is short enough for float sums to hold.
@(test)
a_line_of_a_million_columns_is_walked_by_bytes_not_runes :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	size, scroll := 2000, 1000
	if family, err := font.family_load(f.fonts, "Cascadia Mono"); err == .None {
		f.mono = ui.text_mono(&f.text, family)
		size, scroll = 1 << 20, 500_000
	}
	digit := ui.text_width(&f.mono, "0")
	line := strings.repeat("0", size, context.temp_allocator)
	testing.expect(t, abs(ui.code_width(&f.mono, ui.code_font(&f.mono), line) - f32(size) * digit) < 0.5)
	at := ui.code_offset_at(&f.mono, line, 400, 2 * digit + 1, f32(scroll) * digit)
	testing.expect_value(t, at, scroll + 2)
	x := ui.code_x_of(&f.mono, line, 400, scroll + 3, f32(scroll) * digit)
	testing.expect(t, abs(x - 3 * digit) < 0.5)
}

// How many columns of `digit` fit `room`, as a wrapped row holds them.
@(private = "file")
wrap_columns :: proc(room, digit: f32) -> int {
	return max(1, int((room + 0.01) / digit))
}

@(private = "file")
wrap_rows_of :: proc(length, columns: int) -> int {return (length + columns - 1) / columns}

@(test)
wrapped_lines_take_more_rows_and_nothing_scrolls_or_fades :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	state, scrolled: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	defer ui.changes_state_destroy(&scrolled)
	_ = scroll_lay_out(&f, &view, &scrolled)
	view.wrap = true
	g := scroll_lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	digit := ui.text_width(&f.mono, "0")
	line := f32(state.rows.line)

	_, column, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 2)
	columns := wrap_columns(column.width, digit)
	added := ui.changes_line_rect(g, &view, &state, 1, 2)
	removed := ui.changes_line_rect(g, &view, &state, 1, 1)
	testing.expect_value(t, added.height, f32(wrap_rows_of(300, columns)) * line)
	testing.expect_value(t, removed.height, f32(wrap_rows_of(250, columns)) * line)
	testing.expect(t, state.rows.total > scrolled.rows.total, "wrapped lines make the diff taller")
	testing.expect_value(t, column.scroll, 0)

	// Nothing scrolls sideways: no extent, no scrollbar, and the wheel does nothing.
	limit, _ := ui.changes_h_extent(g, &view, &state)
	testing.expect_value(t, limit, 0)
	_, bar := ui.changes_h_scrollbar(g, &view, &state)
	testing.expect(t, !bar)
	testing.expect(t, !ui.changes_scroll_columns(&state, g, &view, 10))

	// Every character is drawn, inside the cell, none faded; the number and sign only once.
	scroll_draw(t, &f, &view, &state, g, &list)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}
	_, last, count := scroll_row_glyphs(&list, added, column.text_x - 1)
	testing.expect_value(t, count, 300)
	testing.expect(t, last <= column.text_x + column.width + 1.5)
	_, _, with_gutter := scroll_row_glyphs(&list, added, 0)
	testing.expect_value(t, with_gutter, 302)

	// A press on the second line of the text is the second slice of the line.
	at, _, ok := ui.changes_text_point(g, &view, &state, &f.mono, 1, 2, column.text_x + 5.4 * digit, added.y + line + 2)
	testing.expect(t, ok)
	testing.expect_value(t, at, columns + 5)
	at, _, _ = ui.changes_text_point(g, &view, &state, &f.mono, 1, 2, column.text_x + 5.4 * digit, added.y + 2)
	testing.expect_value(t, at, 5)

	// The hunk header's long section wraps too, so the first line of b.odin sits lower than when scrolling.
	scrolled_first := ui.changes_line_rect(g, &view, &scrolled, 1, 0)
	first := ui.changes_line_rect(g, &view, &state, 1, 0)
	testing.expect(t, first.y - scrolled_first.y >= line)
}

@(test)
side_by_side_wrapped_pairs_take_the_taller_side :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	view.wrap, view.side_by_side = true, true
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := scroll_lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	digit := ui.text_width(&f.mono, "0")
	line := f32(state.rows.line)
	_, left, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 1)
	_, right, _ := ui.changes_line_code(g, &view, &state, &f.mono, 1, 2)
	columns := wrap_columns(min(left.width, right.width), digit)
	removed := ui.changes_line_rect(g, &view, &state, 1, 1)
	added := ui.changes_line_rect(g, &view, &state, 1, 2)
	testing.expect_value(t, removed.y, added.y)
	testing.expect_value(t, removed.height, added.height)
	testing.expect_value(t, added.height, f32(wrap_rows_of(300, columns)) * line)

	// Each half draws all of its own text, inside its own cell.
	scroll_draw(t, &f, &view, &state, g, &list)
	for glyph in list.glyphs {testing.expect(t, glyph.flags & render.GLYPH_FADE == 0)}
	in_left, in_right := 0, 0
	for glyph in list.glyphs {
		if glyph.rect.y < added.y || glyph.rect.y >= added.y + added.height {continue}
		if glyph.rect.x >= left.text_x - 1 && glyph.rect.x + glyph.rect.width <= left.text_x + left.width + 1.5 {
			in_left += 1
		} else if glyph.rect.x >= right.text_x - 1 {
			in_right += 1
		}
	}
	testing.expect_value(t, in_left, 250)
	testing.expect_value(t, in_right, 300)
}

@(test)
a_resize_keeps_the_row_at_the_top_of_a_wrapped_diff :: proc(t: ^testing.T) {
	f: Scroll_Fixture
	view: ui.Changes_View
	if !scroll_make(t, &f, &view) {return}
	defer scroll_destroy(&f)
	view.wrap = true
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := scroll_lay_out(&f, &view, &state, 900)
	// Scroll until the added line of b.odin is at the top of the diff.
	row := ui.changes_line_rect(g, &view, &state, 1, 2)
	state.diff_scroll += int(row.y - g.diff.y)
	g = scroll_lay_out(&f, &view, &state, 900)
	testing.expect_value(t, ui.changes_line_rect(g, &view, &state, 1, 2).y, g.diff.y)
	scrolled := state.diff_scroll

	narrow := scroll_lay_out(&f, &view, &state, 400)
	testing.expect(t, state.diff_scroll != scrolled, "the rows wrap to more lines, so the scroll moved with them")
	testing.expect_value(t, ui.changes_line_rect(narrow, &view, &state, 1, 2).y, narrow.diff.y)
	wide := scroll_lay_out(&f, &view, &state, 900)
	testing.expect_value(t, ui.changes_line_rect(wide, &view, &state, 1, 2).y, wide.diff.y)
}
