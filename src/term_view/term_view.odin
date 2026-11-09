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
	// Capture the cursor for a window-level transition without painting or animating it locally.
	cursor_suppressed:                                                bool,
	// The link under the pointer is view state, not cell style: it only adds an underline overlay.
	hover:                                                            Maybe(term.Link_Range),
	// The zero value draws the cursor only where the terminal puts it.
	cursor_effects:                                                   Cursor_Effects,
}

Frame :: struct {
	background:      render.Color,
	cursor_blinking: bool,
	cursor:          Maybe(Cursor_Paint),
	// What reading the session did for this build. Anything but Updated drew the previously
	// captured screen (a synchronized-output hold or a failed read), so the frame must not be
	// cached as any generation; a hold also says when to draw again.
	capture:         term.Capture_Result,
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
	images:     term.Image_Capture,
	cursor:     Cursor_Motion,
	cursor_rows: [dynamic]ghostty.Render_State_Row_Id,
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
	v.cursor_rows = make([dynamic]ghostty.Render_State_Row_Id, allocator)
	ok := ghostty.render_state_new(nil, &v.state) == .Success
	ok &&= ghostty.render_state_row_iterator_new(nil, &v.rows) == .Success
	ok &&= ghostty.render_state_row_cells_new(nil, &v.cells) == .Success
	ok &&= term.image_capture_create(&v.images, allocator)
	if !ok {
		destroy(v)
	}
	return ok
}

destroy :: proc(v: ^View) {
	ghostty.render_state_row_cells_free(v.cells)
	ghostty.render_state_row_iterator_free(v.rows)
	ghostty.render_state_free(v.state)
	term.image_capture_destroy(&v.images)
	delete(v.codepoints)
	delete(v.highlights)
	delete(v.marks)
	delete(v.paints)
	delete(v.runes)
	delete(v.columns)
	delete(v.shaped)
	delete(v.cursor_rows)
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
	list:              ^render.Draw_List,
	cache:             ^glyphs.Cache,
	fonts:             ^font.System,
	metrics:           Metrics,
	style:             Style,
	colors:            ghostty.Render_State_Colors,
	cursor:            ghostty.Render_State_Cursor,
	origin:            [2]f32,
	columns:           int,
	// Images clip to the grid, and a cursor motion does not survive a change to it.
	rows:              int,
	// The cursor sits on a wide cluster, so it covers two cells.
	cursor_wide:       bool,
	// The cell the cursor draws from: on a wide cluster the head, even if it reports the tail.
	cursor_column:     int,
	cursor_color:      render.Color,
	// Below-text images took a pass of their own for the backgrounds that go under them.
	backgrounds_drawn: bool,
	frame_time:        render.Frame_Time,
	// The cursor is between cells at progress `cursor_t`; its head covers rows `cursor_row` and the
	// one below, whose text glyphs `cursor_text` holds.
	cursor_moving:     bool,
	cursor_t:          f32,
	cursor_row:        int,
	cursor_text:       [2]Glyph_Span,
}

@(private)
rect :: proc(b: ^Builder, r: render.Rect, c: render.Color) {
	_ = render.push_rect(b.list, {rect = r, color = c})
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
	_ = render.push_glyph(b.list, {rect = at, atlas = entry.atlas, color = c, flags = flags})
}

// Renders the session's current screen into the draw list's current layer, origin at the top-left cell.
// The result only short-circuits atlas resets. Draw-list failures stay on the list for frame completion.
// `frame_time` is when the frame will be on screen, which a moving cursor (Style.cursor_effects) is
// drawn for; without it the cursor sits where the terminal puts it.
build :: proc(
	v: ^View,
	session: ^term.Session,
	fonts: ^font.System,
	cache: ^glyphs.Cache,
	list: ^render.Draw_List,
	origin: [2]f32,
	metrics: Metrics,
	style: Style,
	frame_time := render.Frame_Time{},
) -> (
	Frame,
	render.Build_Status,
) {
	if list.error != .None {return {}, .Ok}
	capture := term.capture(session, v.state, &v.highlights, &v.images)
	b := Builder {
		list       = list,
		cache      = cache,
		fonts      = fonts,
		metrics    = metrics,
		style      = style,
		colors     = ghostty.sized(ghostty.Render_State_Colors),
		cursor     = ghostty.sized(ghostty.Render_State_Cursor),
		origin     = origin,
		frame_time = frame_time,
	}
	columns, rows: u16
	ok := ghostty.render_state_get(v.state, .Cols, &columns) == .Success
	ok &&= ghostty.render_state_get(v.state, .Rows, &rows) == .Success
	ok &&= ghostty.render_state_get(v.state, .Colors, &b.colors) == .Success
	ok &&= ghostty.render_state_get(v.state, .Cursor, &b.cursor) == .Success
	ok &&= ghostty.render_state_get(v.state, .Row_Iterator, &v.rows) == .Success
	if !ok {
		list.error = .Construction_Failed
		return {}, .Ok
	}
	b.columns, b.rows = int(columns), int(rows)
	b.cursor_column = int(b.cursor.viewport_x) - (b.cursor.wide_tail ? 1 : 0)
	b.cursor_color =
		b.colors.cursor_has_value ? color(b.colors.cursor) : color(b.colors.foreground)
	frame := Frame {
		background      = color(b.colors.background),
		cursor_blinking = b.cursor.visible && b.cursor.blinking,
		capture         = capture,
	}
	if !cursor_viewport_capture(v, &b) {return frame, .Ok}
	cursor_begin(v, &b)
	has_images := len(v.images.placements) > 0
	if has_images {
		images_upload(v, session, cache.device)
		if images_present(v, .Below_Background) {
			images_draw(v, &b, .Below_Background)
			images_next_layer(&b)
		}
		if images_present(v, .Below_Text) {
			images_draw_below_text(v, &b)
			if list.error != .None {return frame, .Ok}
		}
	}
	for y := 0; ghostty.render_state_row_iterator_next(v.rows); y += 1 {
		if result := build_row(v, &b, y); result != .Ok {
			return frame, result
		}
		if list.error != .None {return frame, .Ok}
	}
	if list.error != .None {return frame, .Ok}
	// A moving block clips its text to its head. Above-text images still use the whole pane.
	cell_layer := list.layers[len(list.layers) - 1]
	frame.cursor = build_cursor(v, &b)
	if has_images && images_present(v, .Above_Text) {
		if render.push_layer(list, cell_layer.clip, cell_layer.radius) != .None {return frame, .Ok}
		images_draw(v, &b, .Above_Text)
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
	width:                  ghostty.Cell_Wide,
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
	cell := term.read_render_cell(v.cells)
	p := Cell_Paint {
		foreground = color(b.colors.foreground),
		style      = cell.style,
		width      = cell.width,
	}
	if rgb, ok := cell.foreground.?; ok {
		p.foreground = color(rgb)
	}
	if rgb, ok := cell.background.?; ok {
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
		if block_cursor_at(b, x, y) {background = b.cursor_color}
		p.foreground = minimum_contrast_cached(
			&v.contrast,
			p.foreground,
			background,
			b.style.minimum_contrast,
		)
	}
	return p
}

// The block cursor rests on cell (x, y): its rect goes under that cell's text, which takes the cursor
// text colour. A moving block draws its own text instead (cursor_draw_moving).
@(private)
block_cursor_at :: proc(b: ^Builder, x, y: int) -> bool {
	c := b.cursor
	return(
		c.visible &&
		c.viewport_has_value &&
		b.style.focused &&
		b.style.cursor_phase_visible &&
		c.visual_style == .Block &&
		!b.style.cursor_suppressed &&
		!b.cursor_moving &&
		b.cursor_column == x &&
		int(c.viewport_y) == y \
	)
}

// Fills v.paints from the row iterator's current row. A failure stays on the list.
@(private)
row_paints :: proc(v: ^View, b: ^Builder, y: int) {
	selection := ghostty.sized(ghostty.Render_State_Row_Selection)
	selected := ghostty.render_state_row_get(v.rows, .Selection, &selection) == .Success
	if ghostty.render_state_row_get(v.rows, .Cells, &v.cells) != .Success {
		b.list.error = .Construction_Failed
		return
	}
	if !mark_row(v, y, b.columns) {
		b.list.error = .Out_Of_Memory
		return
	}
	clear(&v.paints)
	for x := 0; ghostty.render_state_row_cells_next(v.cells); x += 1 {
		mark := x < len(v.marks) ? v.marks[x] : .None
		p := paint_cell(v, b, x, y, selection, selected, mark)
		if _, err := append(&v.paints, p); err != nil {
			b.list.error = .Out_Of_Memory
			return
		}
	}
	c := b.cursor
	if c.viewport_has_value && int(c.viewport_y) == y {
		x := b.cursor_column
		b.cursor_wide = c.wide_tail || (x >= 0 && x < len(v.paints) && v.paints[x].width == .Wide)
	}
}

@(private)
row_backgrounds :: proc(v: ^View, b: ^Builder, top: f32) {
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
}

@(private)
build_row :: proc(v: ^View, b: ^Builder, y: int) -> render.Build_Status {
	m := b.metrics
	top := b.origin.y + f32(y) * m.cell_height
	row_paints(v, b, y)
	if b.list.error != .None {return .Ok}
	if !b.backgrounds_drawn {row_backgrounds(v, b, top)}
	for p, x in v.paints {
		if result := decorate(b, p, b.origin.x + f32(x) * m.cell_width, top); result != .Ok {
			return result
		}
	}
	if hover, has := b.style.hover.?; has {
		first, last, _ := term.link_range_columns(hover, y, b.columns)
		x := max(first, 0)
		for x <= last && x < len(v.paints) {
			p := v.paints[x]
			if p.width == .Spacer_Tail || p.width == .Spacer_Head {
				x += 1
				continue
			}
			if ghostty.Sgr_Underline(p.style.underline) != .None {
				x += 1
				continue
			}
			start := x
			width := m.cell_width * (p.width == .Wide ? 2 : 1)
			x += 1
			if p.width == .Narrow {
				for x <= last && x < len(v.paints) {
					next := v.paints[x]
					if next.width != .Narrow ||
					   next.foreground != p.foreground ||
					   ghostty.Sgr_Underline(next.style.underline) != .None {
						break
					}
					width += m.cell_width
					x += 1
				}
			}
			rect(
				b,
				{
					b.origin.x + f32(start) * m.cell_width,
					top + m.baseline + m.underline_offset,
					width,
					m.underline_thickness,
				},
				p.foreground,
			)
		}
	}
	clear(&v.runes)
	clear(&v.columns)
	face: font.Style
	previous := -2
	text_start := len(b.list.glyphs)
	cursor := b.cursor
	cursor_x := -1
	if cursor.visible && cursor.viewport_has_value && int(cursor.viewport_y) == y {
		cursor_x = int(cursor.viewport_x)
	}
	for p, x in v.paints {
		span: []u32
		if !p.style.invisible {
			if ghostty.render_state_row_cells_select(v.cells, u16(x)) != .Success {
				b.list.error = .Construction_Failed
				return .Ok
			}
			clear(&v.codepoints)
			text, err := term.render_cell_graphemes(v.cells, p.width, &v.codepoints)
			if err != .None {
				b.list.error = err == .Out_Of_Memory ? .Out_Of_Memory : .Construction_Failed
				return .Ok
			}
			span = text
		}
		next_face := cell_face(p)
		if p.style.invisible ||
		   len(span) == 0 ||
		   previous != x - 1 ||
		   next_face != face ||
		   x == cursor_x ||
		   previous == cursor_x {
			if result := draw_run(v, b, face, top); result != .Ok {return result}
			clear(&v.runes)
			clear(&v.columns)
		}
		if p.style.invisible || len(span) == 0 {continue}
		if reserve(&v.runes, len(v.runes) + len(span)) != nil ||
		   reserve(&v.columns, len(v.columns) + len(span)) != nil {
			b.list.error = .Out_Of_Memory
			return .Ok
		}
		for codepoint in span {
			_, rune_err := append(&v.runes, rune(codepoint))
			_, column_err := append(&v.columns, x)
			if rune_err != nil || column_err != nil {
				b.list.error = .Out_Of_Memory
				return .Ok
			}
		}
		face, previous = next_face, x
	}
	result := draw_run(v, b, face, top)
	cursor_note_row(b, y, text_start)
	return result
}

@(private)
cell_face :: proc(p: Cell_Paint) -> font.Style {
	if p.style.bold && p.style.italic {return .Bold_Italic}
	if p.style.bold {return .Bold}
	if p.style.italic {return .Italic}
	return .Regular
}

@(private, require_results)
draw_run :: proc(v: ^View, b: ^Builder, face: font.Style, top: f32) -> render.Build_Status {
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
		span :=
			f32(v.columns[last] - x + (v.paints[v.columns[last]].width == .Wide ? 2 : 1)) *
			m.cell_width
		// D-042: a cluster wider than its cells shrinks to fit around the cell center, so it never
		// covers a neighbor; a wide cluster is centered in its two cells. Wide clusters draw in
		// color when the font defines color glyphs, so emoji presentation shows as emoji.
		scale: f32 = 1
		if advance > span + 0.5 {
			scale = span / advance
		}
		left := b.origin.x + f32(x) * m.cell_width
		if scale < 1 || p.width == .Wide {
			left += (span - advance * scale) / 2
		}
		baseline := top + m.cell_height / 2 + (m.baseline - m.cell_height / 2) * scale
		pen: f32
		for g in v.shaped[start:end] {
			entry, result := glyphs.glyph(b.cache, g.glyph, m.size_px * scale, p.width == .Wide)
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
draw_codepoints :: proc(v: ^View, b: ^Builder, face: font.Style, top: f32) -> render.Build_Status {
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
decorate :: proc(b: ^Builder, p: Cell_Paint, left, top: f32) -> render.Build_Status {
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
build_cursor :: proc(v: ^View, b: ^Builder) -> Maybe(Cursor_Paint) {
	if b.list.error != .None {return nil}
	c := b.cursor
	if !c.visible || !c.viewport_has_value || !b.style.cursor_phase_visible {
		return nil
	}
	m := b.metrics
	cell := render.Rect {
		b.origin.x + f32(b.cursor_column) * m.cell_width,
		b.origin.y + f32(c.viewport_y) * m.cell_height,
		m.cell_width * (b.cursor_wide ? 2 : 1),
		m.cell_height,
	}
	paint := Cursor_Paint {
		head = cell, tail = cell, target = cell,
		shape = c.visual_style, color = b.cursor_color, text_color = b.style.cursor_text,
		stroke = max(1, m.underline_thickness), minimum_contrast = b.style.minimum_contrast,
	}
	if b.style.cursor_suppressed {return paint}
	if v.cursor.present {
		v.cursor.target = cell
		cursor_place(&v.cursor, b.cursor_t)
		paint.head, paint.tail = v.cursor.head, v.cursor.tail
	}
	defer {
		if v.cursor.present && b.list.error == .None {
			v.cursor.drawn_head, v.cursor.drawn_tail = v.cursor.head, v.cursor.tail
		}
	}
	if b.cursor_moving {
		cursor_draw_moving(v, b, paint)
		return paint
	}
	// A block cursor sits between the cell background and the glyph: rects in a layer draw before its glyphs.
	if block_cursor_at(b, b.cursor_column, int(c.viewport_y)) {
		rect(b, cell, b.cursor_color)
		return paint
	}
	layer := b.list.layers[len(b.list.layers) - 1]
	if render.push_layer(b.list, layer.clip, layer.radius) != .None {return nil}
	cursor_outline(b.list, paint, !b.style.focused)
	return paint
}
