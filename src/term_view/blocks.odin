package term_view

import "aio:ghostty"
import "aio:render"
import "aio:term"
import "core:log"

// A miniature of a session's screen as cell blocks, the way a code editor's minimap draws its text: each run
// of written cells is a bar in its foreground colour, over the background colours its cells carry. No glyph
// is drawn, so the miniature stays legible as shape and colour at any scale.

// The share of a cell's height a text bar takes, centred in the cell.
@(private = "file")
BLOCK_BAR :: f32(0.5)

// Draws the session's current screen as cell blocks into the list's current layer, as large as fits `area`
// with the grid's own shape, centred. `cell` is the size of one cell on the session's real surface. Returns
// where the grid landed; empty when nothing was drawn. Draw-list failures stay on the list.
blocks_build :: proc(
	v: ^View,
	session: ^term.Session,
	list: ^render.Draw_List,
	area: render.Rect,
	cell: [2]f32,
) -> render.Rect {
	if list.error != .None || area.width <= 0 || area.height <= 0 || cell.x <= 0 || cell.y <= 0 {return {}}
	// A synchronized-output hold or a failed read keeps the previous screen, which is what a miniature shows.
	_ = term.capture(session, v.state)
	columns, rows: u16
	colors := ghostty.sized(ghostty.Render_State_Colors)
	ok := ghostty.render_state_get(v.state, .Cols, &columns) == .Success
	ok &&= ghostty.render_state_get(v.state, .Rows, &rows) == .Success
	ok &&= ghostty.render_state_get(v.state, .Colors, &colors) == .Success
	ok &&= ghostty.render_state_get(v.state, .Row_Iterator, &v.rows) == .Success
	if !ok {
		list.error = .Construction_Failed
		return {}
	}
	if columns == 0 || rows == 0 {return {}}
	k := min(area.width / (f32(columns) * cell.x), area.height / (f32(rows) * cell.y))
	size := [2]f32{f32(columns) * cell.x * k, f32(rows) * cell.y * k}
	grid := render.Rect{area.x + (area.width - size.x) / 2, area.y + (area.height - size.y) / 2, size.x, size.y}
	step := [2]f32{size.x / f32(columns), size.y / f32(rows)}
	background := color(colors.background)
	foreground := color(colors.foreground)
	_ = render.push_rect(list, {rect = grid, color = background})
	for y := 0; ghostty.render_state_row_iterator_next(v.rows); y += 1 {
		top := grid.y + f32(y) * step.y
		// Backgrounds first, so a background run that ends after a text run cannot cover it.
		for text in ([2]bool{false, true}) {
			if ghostty.render_state_row_get(v.rows, .Cells, &v.cells) != .Success {
				list.error = .Construction_Failed
				return grid
			}
			blocks_row(v.cells, list, text, grid.x, top, step, background, foreground)
		}
		if list.error != .None {return grid}
	}
	if result := ghostty.render_state_clean(v.state); result != .Success {
		log.errorf("term_view: cleaning the render state failed: %v", result)
	}
	return grid
}

// One row's runs: with `text`, a bar where written cells share a foreground colour, ending at a change of
// colour or a blank cell; without it, a full-height run where cells carry their own background.
@(private = "file")
blocks_row :: proc(
	cells: ghostty.Render_State_Row_Cells,
	list: ^render.Draw_List,
	text: bool,
	left, top: f32,
	step: [2]f32,
	background, foreground: render.Color,
) {
	start, x := 0, 0
	run: Maybe(render.Color)
	height := text ? max(step.y * BLOCK_BAR, 1) : step.y
	y := top + (step.y - height) / 2
	for ; ghostty.render_state_row_cells_next(cells); x += 1 {
		c := term.read_render_cell(cells)
		fg, bg := foreground, background
		has_bg := false
		if rgb, ok := c.foreground.?; ok {fg = color(rgb)}
		if rgb, ok := c.background.?; ok {bg, has_bg = color(rgb), true}
		if c.style.inverse {fg, bg, has_bg = bg, fg, true}
		if c.style.faint {fg.a *= 0.5}
		// The trailing half of a wide character continues whatever its lead began.
		if c.width == .Spacer_Tail {continue}
		want: Maybe(render.Color)
		if text {
			if blocks_written(c) {want = fg}
		} else if has_bg {want = bg}
		if want == run {continue}
		if current, ok := run.?; ok {
			r := render.Rect{left + f32(start) * step.x, y, f32(x - start) * step.x, height}
			_ = render.push_rect(list, {rect = r, color = current})
		}
		start, run = x, want
	}
	if current, ok := run.?; ok {
		r := render.Rect{left + f32(start) * step.x, y, f32(x - start) * step.x, height}
		_ = render.push_rect(list, {rect = r, color = current})
	}
}

// Whether a cell shows a character: written, not a space, and not hidden.
@(private = "file")
blocks_written :: proc(c: term.Render_Cell) -> bool {
	if c.style.invisible || c.width == .Spacer_Head {return false}
	has_text: bool
	if ghostty.cell_get(c.raw, .Has_Text, &has_text) != .Success || !has_text {return false}
	codepoint: u32
	return ghostty.cell_get(c.raw, .Codepoint, &codepoint) != .Success || codepoint != ' '
}
