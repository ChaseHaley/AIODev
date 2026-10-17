package term_view

import "core:log"
import "core:math"
import "aio:font"
import "aio:ghostty"
import "aio:glyphs"
import "aio:render"
import "aio:term"

Metrics :: struct {
	size_px: f32,
	cell_width, cell_height: f32,
	baseline: f32,
	underline_offset, underline_thickness: f32,
	strikethrough_offset, strikethrough_thickness: f32,
}

Style :: struct {
	family: font.Family,
	selection_background: render.Color,
	selection_foreground: Maybe(render.Color),
	cursor_text: render.Color,
	focused: bool,
	cursor_phase_visible: bool,
}

Frame :: struct {
	background: render.Color,
	cursor_blinking: bool,
}

View :: struct {
	state: ghostty.Render_State,
	rows: ghostty.Render_State_Row_Iterator,
	cells: ghostty.Render_State_Row_Cells,
	codepoints: [dynamic]u32,
}

@(require_results)
create :: proc(v: ^View, allocator := context.allocator) -> bool {
	v.codepoints = make([dynamic]u32, allocator)
	ok := ghostty.render_state_new(nil, &v.state) == .Success
	ok &&= ghostty.render_state_row_iterator_new(nil, &v.rows) == .Success
	ok &&= ghostty.render_state_row_cells_new(nil, &v.cells) == .Success
	if !ok {
		destroy(v)
	}
	return ok
}

destroy :: proc(v: ^View) {
	ghostty.render_state_row_cells_free(v.cells)
	ghostty.render_state_row_iterator_free(v.rows)
	ghostty.render_state_free(v.state)
	delete(v.codepoints)
	v^ = {}
}

// Cell size comes from the regular face's advance and line metrics, rounded to whole pixels so
// glyphs stay on the pixel grid; the extra line height is split evenly above and below the text.
compute_metrics :: proc(fonts: ^font.System, family: font.Family, size_px, line_height: f32) -> Metrics {
	face := font.face_metrics(fonts, family.faces[.Regular], size_px)
	advance := size_px * 0.6
	if zero, found := font.glyph_lookup(fonts, family, .Regular, '0'); found {
		advance = font.glyph_advance(fonts, zero, size_px)
	}
	natural := face.ascent + face.descent + face.line_gap
	cell_height := max(1, math.round(natural * line_height))
	underline := max(1, math.round(face.underline_thickness))
	strikethrough := max(1, math.round(face.strikethrough_thickness))
	return {
		size_px = size_px,
		cell_width = max(1, math.round(advance)),
		cell_height = cell_height,
		baseline = math.round(face.ascent + face.line_gap / 2 + (cell_height - natural) / 2),
		underline_offset = math.round(-face.underline_position + underline / 2),
		underline_thickness = underline,
		strikethrough_offset = math.round(face.strikethrough_position - strikethrough / 2),
		strikethrough_thickness = strikethrough,
	}
}

grid_size :: proc(m: Metrics, width, height, padding: f32) -> (columns, rows: u16) {
	usable_width := max(0, width - 2 * padding)
	usable_height := max(0, height - 2 * padding)
	columns = u16(clamp(usable_width / m.cell_width, 1, f32(max(i16))))
	rows = u16(clamp(usable_height / m.cell_height, 1, f32(max(i16))))
	return
}

@(private)
color :: proc(c: ghostty.Color_Rgb, alpha: f32 = 1) -> render.Color {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, alpha}
}

@(private)
style_color :: proc(
	c: ghostty.Style_Color,
	palette: ^[256]ghostty.Color_Rgb,
	fallback: render.Color,
) -> render.Color {
	switch c.tag {
	case .Palette: return color(palette[c.value.palette])
	case .Rgb: return color(c.value.rgb)
	case .None:
	}
	return fallback
}

@(private)
Builder :: struct {
	list: ^render.Draw_List,
	cache: ^glyphs.Cache,
	fonts: ^font.System,
	metrics: Metrics,
	style: Style,
	colors: ghostty.Render_State_Colors,
	cursor: ghostty.Render_State_Cursor,
	origin: [2]f32,
	ok: bool,
}

@(private)
rect :: proc(b: ^Builder, r: render.Rect, c: render.Color) {
	if render.push_rect(b.list, {rect = r, color = c}) != .None {
		b.ok = false
	}
}

@(private)
place :: proc(b: ^Builder, entry: glyphs.Entry, pen: [2]f32, c: render.Color) {
	if entry.size.x == 0 {
		return
	}
	at := render.Rect{
		math.round(pen.x + entry.offset.x),
		math.round(pen.y + entry.offset.y),
		entry.size.x,
		entry.size.y,
	}
	if render.push_glyph(b.list, {rect = at, atlas = entry.atlas, color = c}) != .None {
		b.ok = false
	}
}

// Renders the session's current screen into the draw list's current layer, origin at the top-left cell.
// .Atlas_Reset means the glyph atlas overflowed mid-frame: reset the draw list and build again.
build :: proc(
	v: ^View,
	session: ^term.Session,
	fonts: ^font.System,
	cache: ^glyphs.Cache,
	list: ^render.Draw_List,
	origin: [2]f32,
	metrics: Metrics,
	style: Style,
) -> (Frame, glyphs.Result) {
	term.capture(session, v.state)
	b := Builder{
		list = list,
		cache = cache,
		fonts = fonts,
		metrics = metrics,
		style = style,
		colors = ghostty.sized(ghostty.Render_State_Colors),
		cursor = ghostty.sized(ghostty.Render_State_Cursor),
		origin = origin,
		ok = true,
	}
	ok := ghostty.render_state_get(v.state, .Colors, &b.colors) == .Success
	ok &&= ghostty.render_state_get(v.state, .Cursor, &b.cursor) == .Success
	ok &&= ghostty.render_state_get(v.state, .Row_Iterator, &v.rows) == .Success
	if !ok {
		log.error("term_view: reading the render state failed")
		return {}, .Ok
	}
	frame := Frame{
		background = color(b.colors.background),
		cursor_blinking = b.cursor.visible && b.cursor.blinking,
	}
	for y := 0; ghostty.render_state_row_iterator_next(v.rows); y += 1 {
		if result := build_row(v, &b, y); result != .Ok {
			return frame, result
		}
	}
	build_cursor(&b)
	if !b.ok {
		log.error("term_view: the draw list ran out of memory")
	}
	if result := ghostty.render_state_clean(v.state); result != .Success {
		log.errorf("term_view: cleaning the render state failed: %v", result)
	}
	return frame, .Ok
}

@(private)
Cell_Paint :: struct {
	foreground, background: render.Color,
	has_background: bool,
	style: ghostty.Style,
}

@(private)
paint_cell :: proc(
	v: ^View,
	b: ^Builder,
	x, y: int,
	selection: ghostty.Render_State_Row_Selection,
	selected: bool,
) -> Cell_Paint {
	p := Cell_Paint{foreground = color(b.colors.foreground), style = ghostty.sized(ghostty.Style)}
	styled: bool
	if ghostty.render_state_row_cells_get(v.cells, .Has_Styling, &styled) == .Success && styled {
		if ghostty.render_state_row_cells_get(v.cells, .Style, &p.style) != .Success {
			p.style = ghostty.sized(ghostty.Style)
		}
	}
	rgb: ghostty.Color_Rgb
	if ghostty.render_state_row_cells_get(v.cells, .Fg_Color, &rgb) == .Success {
		p.foreground = color(rgb)
	}
	if ghostty.render_state_row_cells_get(v.cells, .Bg_Color, &rgb) == .Success {
		p.background, p.has_background = color(rgb), true
	}
	if p.style.inverse {
		background := p.has_background ? p.background : color(b.colors.background)
		p.foreground, p.background, p.has_background = background, p.foreground, true
	}
	if selected && x >= int(selection.start_x) && x <= int(selection.end_x) {
		p.background, p.has_background = b.style.selection_background, true
		if fg, ok := b.style.selection_foreground.?; ok {
			p.foreground = fg
		}
	}
	if p.style.faint {
		p.foreground.a *= 0.5
	}
	if block_cursor_at(b, x, y) {
		p.foreground = b.style.cursor_text
	}
	return p
}

@(private)
block_cursor_at :: proc(b: ^Builder, x, y: int) -> bool {
	c := b.cursor
	return c.visible && c.viewport_has_value && b.style.focused && b.style.cursor_phase_visible &&
		c.visual_style == .Block && int(c.viewport_x) == x && int(c.viewport_y) == y
}

@(private)
build_row :: proc(v: ^View, b: ^Builder, y: int) -> glyphs.Result {
	m := b.metrics
	top := b.origin.y + f32(y) * m.cell_height
	selection := ghostty.sized(ghostty.Render_State_Row_Selection)
	selected := ghostty.render_state_row_get(v.rows, .Selection, &selection) == .Success
	if ghostty.render_state_row_get(v.rows, .Cells, &v.cells) != .Success {
		return .Ok
	}
	run_start, run_color, run_active := 0, render.Color{}, false
	flush :: proc(b: ^Builder, start, end: int, top: f32, c: render.Color) {
		m := b.metrics
		rect(b, {b.origin.x + f32(start) * m.cell_width, top, f32(end - start) * m.cell_width, m.cell_height}, c)
	}
	x := 0
	for ghostty.render_state_row_cells_next(v.cells) {
		defer x += 1
		p := paint_cell(v, b, x, y, selection, selected)
		if run_active && (!p.has_background || p.background != run_color) {
			flush(b, run_start, x, top, run_color)
			run_active = false
		}
		if p.has_background && !run_active {
			run_start, run_color, run_active = x, p.background, true
		}
		left := b.origin.x + f32(x) * m.cell_width
		if result := decorate(b, p, left, top); result != .Ok {
			return result
		}
		if !p.style.invisible {
			if result := draw_text(v, b, p, left, top); result != .Ok {
				return result
			}
		}
	}
	if run_active {
		flush(b, run_start, x, top, run_color)
	}
	return .Ok
}

@(private)
draw_text :: proc(v: ^View, b: ^Builder, p: Cell_Paint, left, top: f32) -> glyphs.Result {
	count: u32
	if ghostty.render_state_row_cells_get(v.cells, .Graphemes_Len, &count) != .Success || count == 0 {
		return .Ok
	}
	resize(&v.codepoints, int(count))
	if ghostty.render_state_row_cells_get(v.cells, .Graphemes_Buf, raw_data(v.codepoints)) != .Success {
		return .Ok
	}
	face: font.Style = .Regular
	if p.style.bold && p.style.italic {
		face = .Bold_Italic
	} else if p.style.bold {
		face = .Bold
	} else if p.style.italic {
		face = .Italic
	}
	pen := [2]f32{left, top + b.metrics.baseline}
	for codepoint in v.codepoints {
		g, found := font.glyph_lookup(b.fonts, b.style.family, face, rune(codepoint))
		if !found {
			continue
		}
		entry, result := glyphs.glyph(b.cache, g, b.metrics.size_px)
		if result != .Ok {
			return result
		}
		place(b, entry, pen, p.foreground)
	}
	return .Ok
}

@(private)
decorate :: proc(b: ^Builder, p: Cell_Paint, left, top: f32) -> glyphs.Result {
	m := b.metrics
	baseline := top + m.baseline
	if p.style.strikethrough {
		t := m.strikethrough_thickness
		rect(b, {left, baseline - m.strikethrough_offset - t / 2, m.cell_width, t}, p.foreground)
	}
	underline := ghostty.Sgr_Underline(p.style.underline)
	if underline == .None {
		return .Ok
	}
	c := style_color(p.style.underline_color, &b.colors.palette, p.foreground)
	t := m.underline_thickness
	center := baseline + m.underline_offset
	#partial switch underline {
	case .Single:
		rect(b, {left, center - t / 2, m.cell_width, t}, c)
	case .Double:
		rect(b, {left, center - t * 1.5, m.cell_width, t}, c)
		rect(b, {left, center + t * 0.5, m.cell_width, t}, c)
	case .Curly, .Dotted, .Dashed:
		sprite: glyphs.Sprite = .Dashed_Underline
		if underline == .Curly {
			sprite = .Curly_Underline
		} else if underline == .Dotted {
			sprite = .Dotted_Underline
		}
		entry, result := glyphs.sprite(b.cache, sprite, m.cell_width, t)
		if result != .Ok {
			return result
		}
		place(b, entry, {left, center}, c)
	}
	return .Ok
}

@(private)
build_cursor :: proc(b: ^Builder) {
	c := b.cursor
	if !c.visible || !c.viewport_has_value || !b.style.cursor_phase_visible {
		return
	}
	m := b.metrics
	cursor_color := b.colors.cursor_has_value ? color(b.colors.cursor) : color(b.colors.foreground)
	cell := render.Rect{
		b.origin.x + f32(c.viewport_x) * m.cell_width,
		b.origin.y + f32(c.viewport_y) * m.cell_height,
		m.cell_width,
		m.cell_height,
	}
	// A block cursor sits between the cell background and the glyph: rects in a layer draw before its glyphs.
	if block_cursor_at(b, int(c.viewport_x), int(c.viewport_y)) {
		rect(b, cell, cursor_color)
		return
	}
	clip := b.list.layers[len(b.list.layers) - 1].clip
	if render.push_layer(b.list, clip) != .None {
		b.ok = false
		return
	}
	stroke := max(1, m.underline_thickness)
	switch {
	case !b.style.focused || c.visual_style == .Block_Hollow:
		rect(b, {cell.x, cell.y, cell.width, stroke}, cursor_color)
		rect(b, {cell.x, cell.y + cell.height - stroke, cell.width, stroke}, cursor_color)
		rect(b, {cell.x, cell.y, stroke, cell.height}, cursor_color)
		rect(b, {cell.x + cell.width - stroke, cell.y, stroke, cell.height}, cursor_color)
	case c.visual_style == .Bar:
		rect(b, {cell.x, cell.y, stroke * 2, cell.height}, cursor_color)
	case c.visual_style == .Underline:
		rect(b, {cell.x, cell.y + cell.height - stroke * 2, cell.width, stroke * 2}, cursor_color)
	}
}
