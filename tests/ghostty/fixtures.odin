package ghostty_test

import "core:testing"
import "aio:ghostty"

SUCCESS :: ghostty.Result.Success
INVALID :: ghostty.Result.Invalid_Value
SPACE :: ghostty.Result.Out_Of_Space
NONE :: ghostty.Result.No_Value

write :: proc(terminal: ghostty.Terminal, s: string) {
	ghostty.terminal_vt_write(terminal, raw_data(s), uint(len(s)))
}

point :: proc(x: u16, y: u32, tag := ghostty.Point_Tag.Active) -> ghostty.Point {
	return {tag = tag, value = {coordinate = {x = x, y = y}}}
}

expect_cursor :: proc(t: ^testing.T, terminal: ghostty.Terminal, x, y: u16) {
	actual_x, actual_y: u16
	testing.expect_value(t, ghostty.terminal_get(terminal, .Cursor_X, &actual_x), SUCCESS)
	testing.expect_value(t, ghostty.terminal_get(terminal, .Cursor_Y, &actual_y), SUCCESS)
	testing.expect_value(t, actual_x, x)
	testing.expect_value(t, actual_y, y)
}

@(test)
terminal_lifecycle :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	result := ghostty.terminal_new(nil, &terminal, 10, 4)
	if !testing.expect_value(t, result, ghostty.Result.Success) {
		return
	}
	defer ghostty.terminal_free(terminal)
	cols: u16
	testing.expect_value(t, ghostty.terminal_get(terminal, .Cols, &cols), ghostty.Result.Success)
	testing.expect_value(t, cols, 10)
}

@(test)
cursor_and_grid :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 12, 4), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	write(terminal, "abc\x1b[3;5HZ\x1b[1A\x1b[2D")
	expect_cursor(t, terminal, 3, 1)
	ref := ghostty.sized(ghostty.Grid_Ref)
	testing.expect_value(t, ghostty.terminal_grid_ref(terminal, point(4, 2), &ref), SUCCESS)
	cell: ghostty.Cell
	testing.expect_value(t, ghostty.grid_ref_cell(&ref, &cell), SUCCESS)
	cp: u32
	testing.expect_value(t, ghostty.cell_get(cell, .Codepoint, &cp), SUCCESS)
	testing.expect_value(t, cp, u32('Z'))
	coordinate: ghostty.Point_Coordinate
	testing.expect_value(t, ghostty.terminal_point_from_grid_ref(terminal, &ref, .Active, &coordinate), SUCCESS)
	testing.expect_value(t, coordinate.x, 4)
	testing.expect_value(t, coordinate.y, 2)
	testing.expect_value(t, ghostty.terminal_grid_ref(terminal, point(12, 0), &ref), INVALID)
	ghostty.terminal_reset(terminal)
	expect_cursor(t, terminal, 0, 0)
}

@(test)
render_styles_and_wide_characters :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 12, 3), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), SUCCESS) {
		return
	}
	defer ghostty.render_state_free(state)
	rows: ghostty.Render_State_Row_Iterator
	if !testing.expect_value(t, ghostty.render_state_row_iterator_new(nil, &rows), SUCCESS) {
		return
	}
	defer ghostty.render_state_row_iterator_free(rows)
	cells: ghostty.Render_State_Row_Cells
	if !testing.expect_value(t, ghostty.render_state_row_cells_new(nil, &cells), SUCCESS) {
		return
	}
	defer ghostty.render_state_row_cells_free(cells)
	write(terminal, "\x1b[1;3;4:3;38;2;12;34;56;48;5;196mA\x1b[0m\u754c" + "e\u0301")
	expect_cursor(t, terminal, 4, 0)
	testing.expect_value(t, ghostty.render_state_begin_update(state, terminal), SUCCESS)
	write(terminal, "!")
	testing.expect_value(t, ghostty.render_state_end_update(state), SUCCESS)
	cursor := ghostty.sized(ghostty.Render_State_Cursor)
	testing.expect_value(t, ghostty.render_state_get(state, .Cursor, &cursor), SUCCESS)
	testing.expect_value(t, cursor.viewport_x, 4)
	testing.expect_value(t, cursor.viewport_y, 0)
	testing.expect(t, cursor.visible && cursor.viewport_has_value)
	testing.expect_value(t, ghostty.render_state_get(state, .Row_Iterator, &rows), SUCCESS)
	if !testing.expect(t, ghostty.render_state_row_iterator_next(rows)) {
		return
	}
	testing.expect_value(t, ghostty.render_state_row_get(rows, .Cells, &cells), SUCCESS)
	testing.expect_value(t, ghostty.render_state_row_cells_select(cells, 0), SUCCESS)
	style := ghostty.sized(ghostty.Style)
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Style, &style), SUCCESS)
	testing.expect(t, style.bold && style.italic)
	testing.expect_value(t, style.underline, i32(ghostty.Sgr_Underline.Curly))
	testing.expect(t, !style.faint && !style.blink && !style.inverse && !style.invisible)
	testing.expect(t, !style.strikethrough && !style.overline)
	testing.expect_value(t, style.fg_color.tag, ghostty.Style_Color_Tag.Rgb)
	testing.expect_value(t, style.fg_color.value.rgb, ghostty.Color_Rgb{12, 34, 56})
	testing.expect_value(t, style.bg_color.tag, ghostty.Style_Color_Tag.Palette)
	testing.expect_value(t, style.bg_color.value.palette, 196)
	fg, bg: ghostty.Color_Rgb
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Fg_Color, &fg), SUCCESS)
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Bg_Color, &bg), SUCCESS)
	testing.expect_value(t, fg, ghostty.Color_Rgb{12, 34, 56})
	testing.expect_value(t, bg, ghostty.Color_Rgb{255, 0, 0})
	items := []struct {
		x: u16,
		cp: u32,
		wide: ghostty.Cell_Wide,
	}{
		{0, 'A', .Narrow},
		{1, 0x754c, .Wide},
		{2, 0, .Spacer_Tail},
		{3, 'e', .Narrow},
		{4, 0, .Narrow},
	}
	for item in items {
		testing.expect_value(t, ghostty.render_state_row_cells_select(cells, item.x), SUCCESS)
		cell: ghostty.Cell
		testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Raw, &cell), SUCCESS)
		cp: u32
		wide: ghostty.Cell_Wide
		testing.expect_value(t, ghostty.cell_get(cell, .Codepoint, &cp), SUCCESS)
		testing.expect_value(t, ghostty.cell_get(cell, .Wide, &wide), SUCCESS)
		testing.expect_value(t, cp, item.cp)
		testing.expect_value(t, wide, item.wide)
	}
	testing.expect_value(t, ghostty.render_state_row_cells_select(cells, 3), SUCCESS)
	count: u32
	graphemes: [2]u32
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Graphemes_Len, &count), SUCCESS)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Graphemes_Buf, &graphemes), SUCCESS)
	testing.expect_value(t, graphemes, [2]u32{'e', 0x301})
	buffer: ghostty.Buffer
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &buffer), SPACE)
	testing.expect_value(t, buffer.len, 3)
	utf8: [3]u8
	buffer.ptr = &utf8[0]
	buffer.cap = len(utf8)
	testing.expect_value(t, ghostty.render_state_row_cells_get(cells, .Graphemes_Utf8, &buffer), SUCCESS)
	testing.expect_value(t, string(utf8[:]), "e\u0301")
	testing.expect_value(t, ghostty.render_state_row_cells_select(cells, 12), INVALID)
	row_count := 1
	for ghostty.render_state_row_iterator_next(rows) {
		row_count += 1
	}
	testing.expect_value(t, row_count, 3)
	testing.expect_value(t, ghostty.render_state_clean(state), SUCCESS)
	dirty: ghostty.Render_State_Dirty
	testing.expect_value(t, ghostty.render_state_get(state, .Dirty, &dirty), SUCCESS)
	testing.expect_value(t, dirty, ghostty.Render_State_Dirty.False)
	testing.expect_value(t, ghostty.render_state_update(state, terminal), SUCCESS)
	testing.expect_value(t, ghostty.render_state_get(state, .Cursor, &cursor), SUCCESS)
	testing.expect_value(t, cursor.viewport_x, 5)
}

@(test)
resize_and_scrollback :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 8, 3), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	write(terminal, "one\r\ntwo\r\nthree\r\nfour\r\nfive")
	total, history: uint
	testing.expect_value(t, ghostty.terminal_get(terminal, .Total_Rows, &total), SUCCESS)
	testing.expect_value(t, ghostty.terminal_get(terminal, .Scrollback_Rows, &history), SUCCESS)
	testing.expect_value(t, total, 5)
	testing.expect_value(t, history, 2)
	ghostty.terminal_scroll_viewport(terminal, {tag = .Top})
	scrollbar: ghostty.Terminal_Scrollbar
	testing.expect_value(t, ghostty.terminal_get(terminal, .Scrollbar, &scrollbar), SUCCESS)
	testing.expect_value(t, scrollbar, ghostty.Terminal_Scrollbar{total = 5, offset = 0, len = 3})
	ghostty.terminal_scroll_viewport(terminal, {tag = .Delta, value = {delta = 1}})
	testing.expect_value(t, ghostty.terminal_get(terminal, .Scrollbar, &scrollbar), SUCCESS)
	testing.expect_value(t, scrollbar.offset, 1)
	ghostty.terminal_scroll_viewport(terminal, {tag = .Bottom})
	testing.expect_value(t, ghostty.terminal_resize(terminal, 8, 4, 9, 18), SUCCESS)
	testing.expect_value(t, ghostty.terminal_get(terminal, .Total_Rows, &total), SUCCESS)
	testing.expect_value(t, ghostty.terminal_get(terminal, .Scrollback_Rows, &history), SUCCESS)
	testing.expect_value(t, total, 5)
	testing.expect_value(t, history, 1)
	width, height: u32
	testing.expect_value(t, ghostty.terminal_get(terminal, .Width_Px, &width), SUCCESS)
	testing.expect_value(t, ghostty.terminal_get(terminal, .Height_Px, &height), SUCCESS)
	testing.expect_value(t, width, 72)
	testing.expect_value(t, height, 72)
	testing.expect_value(t, ghostty.terminal_resize(terminal, 0, 4, 9, 18), INVALID)
}


