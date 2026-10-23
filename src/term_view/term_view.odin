package term_view

import "aio:colour"
import "aio:font"
import "aio:ghostty"
import "aio:glyphs"
import "aio:render"
import "aio:term"
import "core:log"
import "core:math"

Metrics :: struct {
	size_px:                                       f32,
	cell_width, cell_height:                       f32,
	baseline:                                      f32,
	// Whole pixels from the baseline to a line's top edge: down for the underline, up for the strikethrough.
	underline_offset, underline_thickness:         f32,
	strikethrough_offset, strikethrough_thickness: f32,
}

Style :: struct {
	family:                                                           font.Family,
	selection_background:                                             render.Color,
	selection_foreground:                                             Maybe(render.Color),
	search_foreground, search_background, search_selected_background: render.Color,
	cursor_text:                                                      render.Color,
	minimum_contrast:                                                 f32,
	focused:                                                          bool,
	cursor_phase_visible:                                             bool,
}

Frame :: struct {
	background:      render.Color,
	cursor_blinking: bool,
}

View :: struct {
	state:      ghostty.Render_State,
	rows:       ghostty.Render_State_Row_Iterator,
	cells:      ghostty.Render_State_Row_Cells,
	codepoints: [dynamic]u32,
	highlights: [dynamic]term.Highlight,
	// Search state of each cell in the row being built.
	marks:      [dynamic]Search_Mark,
	paints:     [dynamic]Cell_Paint,
	runes:      [dynamic]rune,
	columns:    [dynamic]int,
	shaped:     [dynamic]font.Shaped_Glyph,
	contrast:   Contrast_Cache,
}

@(require_results)
create :: proc(v: ^View, allocator := context.allocator) -> bool {
	v.codepoints = make([dynamic]u32, allocator)
	v.highlights = make([dynamic]term.Highlight, allocator)
	v.marks = make([dynamic]Search_Mark, allocator)
	v.paints = make([dynamic]Cell_Paint, allocator)
	v.runes = make([dynamic]rune, allocator)
	v.columns = make([dynamic]int, allocator)
	v.shaped = make([dynamic]font.Shaped_Glyph, allocator)
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
	delete(v.highlights)
	delete(v.marks)
	delete(v.paints)
	delete(v.runes)
	delete(v.columns)
	delete(v.shaped)
	v^ = {}
}

// Cell size comes from the regular face's advance and line metrics, rounded to whole pixels so
// glyphs stay on the pixel grid; the extra line height is split evenly above and below the text.
compute_metrics :: proc(
	fonts: ^font.System,
	family: font.Family,
	size_px, line_height: f32,
) -> Metrics {
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
		underline_offset = math.round(-face.underline_position),
		underline_thickness = underline,
		strikethrough_offset = math.round(face.strikethrough_position),
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
	return colour.rgba(term.color_from_ghostty(c), alpha)
}

@(private)
style_color :: proc(
	c: ghostty.Style_Color,
	palette: ^[256]ghostty.Color_Rgb,
	fallback: render.Color,
) -> render.Color {
	switch c.tag {
	case .Palette:
		return color(palette[c.value.palette])
	case .Rgb:
		return color(c.value.rgb)
	case .None:
	}
	return fallback
}

@(private)
Builder :: struct {
	list:        ^render.Draw_List,
	cache:       ^glyphs.Cache,
	fonts:       ^font.System,
	metrics:     Metrics,
	style:       Style,
	colors:      ghostty.Render_State_Colors,
	cursor:      ghostty.Render_State_Cursor,
	origin:      [2]f32,
	columns:     int,
	// The cursor sits on a wide cluster, so it covers two cells.
	cursor_wide: bool,
	ok:          bool,
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
	at := render.Rect {
		math.round(pen.x + entry.offset.x),
		math.round(pen.y + entry.offset.y),
		entry.size.x,
		entry.size.y,
	}
	flags := entry.color ? render.GLYPH_COLOR : 0
	if render.push_glyph(b.list, {rect = at, atlas = entry.atlas, color = c, flags = flags}) !=
	   .None {
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
) -> (
	Frame,
	glyphs.Result,
) {
	term.capture(session, v.state, &v.highlights)
	b := Builder {
		list    = list,
		cache   = cache,
		fonts   = fonts,
		metrics = metrics,
		style   = style,
		colors  = ghostty.sized(ghostty.Render_State_Colors),
		cursor  = ghostty.sized(ghostty.Render_State_Cursor),
		origin  = origin,
		ok      = true,
	}
	columns: u16
	ok := ghostty.render_state_get(v.state, .Cols, &columns) == .Success
	ok &&= ghostty.render_state_get(v.state, .Colors, &b.colors) == .Success
	ok &&= ghostty.render_state_get(v.state, .Cursor, &b.cursor) == .Success
	ok &&= ghostty.render_state_get(v.state, .Row_Iterator, &v.rows) == .Success
	if !ok {
		log.error("term_view: reading the render state failed")
		return {}, .Ok
	}
	b.columns = int(columns)
	frame := Frame {
		background      = color(b.colors.background),
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
Search_Mark :: enum u8 {
	None,
	Match,
	Selected,
}

// Fills v.marks with the search state of each of the row's `columns` cells; the selected match wins.
@(private)
mark_row :: proc(v: ^View, y, columns: int) -> bool {
	if resize(&v.marks, columns) != nil {
		return false
	}
	for &mark in v.marks {
		mark = .None
	}
	for h in v.highlights {
		if h.row != y {continue}
		mark: Search_Mark = h.selected ? .Selected : .Match
		for x in max(h.first, 0) ..= min(h.last, columns - 1) {
			v.marks[x] = max(v.marks[x], mark)
		}
	}
	return true
}

@(private)
Cell_Paint :: struct {
	foreground, background: render.Color,
	has_background:         bool,
	style:                  ghostty.Style,
	// The cell holds a wide cluster and its spacer follows.
	wide:                   bool,
}

@(private)
paint_cell :: proc(
	v: ^View,
	b: ^Builder,
	x, y: int,
	selection: ghostty.Render_State_Row_Selection,
	selected: bool,
	mark: Search_Mark,
) -> Cell_Paint {
	p := Cell_Paint {
		foreground = color(b.colors.foreground),
		style      = ghostty.sized(ghostty.Style),
	}
	styled: bool
	if ghostty.render_state_row_cells_get(v.cells, .Has_Styling, &styled) == .Success && styled {
		if ghostty.render_state_row_cells_get(v.cells, .Style, &p.style) != .Success {
			p.style = ghostty.sized(ghostty.Style)
		}
	}
	raw: ghostty.Cell
	if ghostty.render_state_row_cells_get(v.cells, .Raw, &raw) == .Success {
		width: ghostty.Cell_Wide
		p.wide = ghostty.cell_get(raw, .Wide, &width) == .Success && width == .Wide
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
	if mark != .None {
		p.foreground, p.has_background = b.style.search_foreground, true
		p.background =
			mark == .Selected ? b.style.search_selected_background : b.style.search_background
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
	if b.style.minimum_contrast > 1 && !p.style.invisible {
		background := p.has_background ? p.background : color(b.colors.background)
		if block_cursor_at(b, x, y) {
			background =
				b.colors.cursor_has_value ? color(b.colors.cursor) : color(b.colors.foreground)
		}
		p.foreground = minimum_contrast_cached(
			&v.contrast,
			p.foreground,
			background,
			b.style.minimum_contrast,
		)
	}
	return p
}

@(private)
block_cursor_at :: proc(b: ^Builder, x, y: int) -> bool {
	c := b.cursor
	return(
		c.visible &&
		c.viewport_has_value &&
		b.style.focused &&
		b.style.cursor_phase_visible &&
		c.visual_style == .Block &&
		int(c.viewport_x) - (c.wide_tail ? 1 : 0) == x &&
		int(c.viewport_y) == y \
	)
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
	if !mark_row(v, y, b.columns) {
		b.ok = false
		return .Ok
	}
	clear(&v.paints)
	for x := 0; ghostty.render_state_row_cells_next(v.cells); x += 1 {
		mark := x < len(v.marks) ? v.marks[x] : .None
		p := paint_cell(v, b, x, y, selection, selected, mark)
		if _, err := append(&v.paints, p); err != nil {
			b.ok = false
			return .Ok
		}
	}
	c := b.cursor
	if c.viewport_has_value && int(c.viewport_y) == y {
		x := int(c.viewport_x) - (c.wide_tail ? 1 : 0)
		b.cursor_wide = c.wide_tail || (x >= 0 && x < len(v.paints) && v.paints[x].wide)
	}
	run_start, run_color, run_active := 0, render.Color{}, false
	flush :: proc(b: ^Builder, start, end: int, top: f32, c: render.Color) {
		m := b.metrics
		rect(
			b,
			{
				b.origin.x + f32(start) * m.cell_width,
				top,
				f32(end - start) * m.cell_width,
				m.cell_height,
			},
			c,
		)
	}
	for p, x in v.paints {
		if run_active && (!p.has_background || p.background != run_color) {
			flush(b, run_start, x, top, run_color)
			run_active = false
		}
		if p.has_background && !run_active {
			run_start, run_color, run_active = x, p.background, true
		}
	}
	if run_active {
		flush(b, run_start, len(v.paints), top, run_color)
	}
	for p, x in v.paints {
		if result := decorate(b, p, b.origin.x + f32(x) * m.cell_width, top); result != .Ok {
			return result
		}
	}
	clear(&v.runes)
	clear(&v.columns)
	face: font.Style
	previous := -2
	cursor := b.cursor
	cursor_x := -1
	if cursor.visible && cursor.viewport_has_value && int(cursor.viewport_y) == y {
		cursor_x = int(cursor.viewport_x)
	}
	for p, x in v.paints {
		count: u32
		if ghostty.render_state_row_cells_select(v.cells, u16(x)) != .Success ||
		   ghostty.render_state_row_cells_get(v.cells, .Graphemes_Len, &count) != .Success {
			log.error("term_view: reading row cell failed")
			count = 0
		}
		next_face := cell_face(p)
		if p.style.invisible ||
		   count == 0 ||
		   previous != x - 1 ||
		   next_face != face ||
		   x == cursor_x ||
		   previous == cursor_x {
			if result := draw_run(v, b, face, top); result != .Ok {return result}
			clear(&v.runes)
			clear(&v.columns)
		}
		if p.style.invisible || count == 0 {continue}
		if resize(&v.codepoints, int(count)) != nil ||
		   reserve(&v.runes, len(v.runes) + int(count)) != nil ||
		   reserve(&v.columns, len(v.columns) + int(count)) != nil {
			b.ok = false
			return .Ok
		}
		if ghostty.render_state_row_cells_get(v.cells, .Graphemes_Buf, raw_data(v.codepoints)) !=
		   .Success {
			log.error("term_view: reading cell graphemes failed")
			continue
		}
		for codepoint in v.codepoints {
			_, rune_err := append(&v.runes, rune(codepoint))
			_, column_err := append(&v.columns, x)
			if rune_err != nil || column_err != nil {
				b.ok = false
				return .Ok
			}
		}
		face, previous = next_face, x
	}
	return draw_run(v, b, face, top)
}

@(private)
cell_face :: proc(p: Cell_Paint) -> font.Style {
	if p.style.bold && p.style.italic {return .Bold_Italic}
	if p.style.bold {return .Bold}
	if p.style.italic {return .Italic}
	return .Regular
}

@(private, require_results)
draw_run :: proc(v: ^View, b: ^Builder, face: font.Style, top: f32) -> glyphs.Result {
	if len(v.runes) == 0 {return .Ok}
	clear(&v.shaped)
	if err := font.shape(
		b.fonts,
		b.style.family,
		face,
		v.runes[:],
		b.metrics.size_px,
		&v.shaped,
		v.columns[:],
	); err != .None {
		log.errorf("term_view: shaping failed: %v", err)
		return draw_codepoints(v, b, face, top)
	}
	m := b.metrics
	for start := 0; start < len(v.shaped); {
		cluster := v.shaped[start].cluster
		end := start + 1
		advance := v.shaped[start].advance
		for end < len(v.shaped) && v.shaped[end].cluster == cluster {
			advance += v.shaped[end].advance
			end += 1
		}
		// The glyphs cover the runes up to the next glyph's cluster, which may span several cells
		// for a programming ligature.
		// Right-to-left runs arrive in visual order, so the next cluster can lie before this one.
		last := max(cluster, (end < len(v.shaped) ? v.shaped[end].cluster : len(v.runes)) - 1)
		x := v.columns[cluster]
		p := v.paints[x]
		span := f32(v.columns[last] - x + (v.paints[v.columns[last]].wide ? 2 : 1)) * m.cell_width
		// D-042: a cluster wider than its cells shrinks to fit around the cell center, so it never
		// covers a neighbor; a wide cluster is centered in its two cells. Wide clusters draw in
		// color when the font defines color glyphs, so emoji presentation shows as emoji.
		scale: f32 = 1
		if advance > span + 0.5 {
			scale = span / advance
		}
		left := b.origin.x + f32(x) * m.cell_width
		if scale < 1 || p.wide {
			left += (span - advance * scale) / 2
		}
		baseline := top + m.cell_height / 2 + (m.baseline - m.cell_height / 2) * scale
		pen: f32
		for g in v.shaped[start:end] {
			entry, result := glyphs.glyph(b.cache, g.glyph, m.size_px * scale, p.wide)
			if result != .Ok {return result}
			place(
				b,
				entry,
				{left + pen + g.offset.x * scale, baseline - g.offset.y * scale},
				p.foreground,
			)
			pen += g.advance * scale
		}
		start = end
	}
	return .Ok
}

@(private, require_results)
draw_codepoints :: proc(v: ^View, b: ^Builder, face: font.Style, top: f32) -> glyphs.Result {
	for r, i in v.runes {
		g, found := font.glyph_lookup(b.fonts, b.style.family, face, r)
		if !found {continue}
		entry, result := glyphs.glyph(b.cache, g, b.metrics.size_px)
		if result != .Ok {return result}
		x := v.columns[i]
		place(
			b,
			entry,
			{b.origin.x + f32(x) * b.metrics.cell_width, top + b.metrics.baseline},
			v.paints[x].foreground,
		)
	}
	return .Ok
}

@(private)
decorate :: proc(b: ^Builder, p: Cell_Paint, left, top: f32) -> glyphs.Result {
	m := b.metrics
	baseline := top + m.baseline
	if p.style.strikethrough {
		rect(
			b,
			{left, baseline - m.strikethrough_offset, m.cell_width, m.strikethrough_thickness},
			p.foreground,
		)
	}
	underline := ghostty.Sgr_Underline(p.style.underline)
	if underline == .None {
		return .Ok
	}
	c := style_color(p.style.underline_color, &b.colors.palette, p.foreground)
	t := m.underline_thickness
	line := baseline + m.underline_offset
	#partial switch underline {
	case .Single:
		rect(b, {left, line, m.cell_width, t}, c)
	case .Double:
		rect(b, {left, line - t, m.cell_width, t}, c)
		rect(b, {left, line + t, m.cell_width, t}, c)
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
		place(b, entry, {left, line + t / 2}, c)
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
	// On a wide cluster the cursor covers both of its cells, from the head even if it reports the tail.
	column := int(c.viewport_x) - (c.wide_tail ? 1 : 0)
	cell := render.Rect {
		b.origin.x + f32(column) * m.cell_width,
		b.origin.y + f32(c.viewport_y) * m.cell_height,
		m.cell_width * (b.cursor_wide ? 2 : 1),
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
