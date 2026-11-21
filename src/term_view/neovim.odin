package term_view

import "aio:caret"
import "aio:colour"
import "aio:font"
import "aio:glyphs"
import "aio:neovim"
import "aio:render"
import "core:log"
import "core:math"
import "core:unicode/utf8"

// Draws a Neovim screen (WORK-542) with the terminal's fonts, glyph cache and cluster fitting. The
// scratch is reused across builds, so a build allocates only while a row is longer than any before.
Neovim_View :: struct {
	paints:   [dynamic]Neovim_Paint,
	runes:    [dynamic]rune,
	columns:  [dynamic]int,
	shaped:   [dynamic]font.Shaped_Glyph,
	cursor:   Neovim_Cursor,
	contrast: Contrast_Cache,
}

// AIODev's cursor, not Neovim's: Neovim decides only where it is and its shape in each mode. Its
// colours, text colour and Cursor Animation effects are the ones a terminal pane's cursor has.
Neovim_Style :: struct {
	family:           font.Family,
	// The pane has the keyboard: a solid cursor in the mode's shape rather than a hollow block.
	focused:          bool,
	// The window's blink phase shows a blinking cursor.
	cursor_visible:   bool,
	// A flight carries the cursor, or another surface has it: draw none, but still report where it is.
	cursor_hidden:    bool,
	cursor_color:     render.Color,
	cursor_text:      render.Color,
	minimum_contrast: f32,
	cursor_effects:   caret.Effects,
}

Neovim_Frame :: struct {
	background:      render.Color,
	cursor:          Maybe(Cursor_Paint),
	cursor_blinking: bool,
}

// Changing the cursor's shape or the grid's geometry puts the cursor where it is at once, as a
// terminal's does.
@(private)
Neovim_Cursor_Key :: struct {
	shape:   caret.Shape,
	metrics: Metrics,
	origin:  [2]f32,
	grid:    [2]int,
}

@(private)
Neovim_Cursor :: struct {
	key:          Neovim_Cursor_Key,
	cell:         [2]int,
	using motion: caret.Motion,
	// The focused cursor's pose survives idle blinking, so the next move can start from it.
	present:      bool,
}

@(private)
Neovim_Paint :: struct {
	foreground, background, special: render.Color,
	attributes:                      bit_set[neovim.Attribute; u16],
	glyph:                           u32,
	// The cell holds the left half of a double-width character.
	wide:                            bool,
}

neovim_view_destroy :: proc(v: ^Neovim_View) {
	delete(v.paints)
	delete(v.runes)
	delete(v.columns)
	delete(v.shaped)
	v^ = {}
}

// Advances the cursor's motion to `frame`; true when the cursor's pose changed.
neovim_cursor_animate :: proc(v: ^Neovim_View, frame: render.Frame_Time, enabled: bool) -> bool {
	return caret.motion_animate(&v.cursor.motion, frame, enabled)
}

neovim_cursor_animating :: proc(v: ^Neovim_View) -> bool {
	return v.cursor.active
}

// Forgets where the cursor was drawn, so the next build puts it where Neovim has it, with no motion.
neovim_cursor_reset :: proc(v: ^Neovim_View) {
	if v.cursor.present {v.cursor = {}}
}

@(private)
neovim_color :: proc(value: neovim.Color) -> render.Color {
	return colour.rgba({u8(value >> 16), u8(value >> 8), u8(value)})
}

@(private)
neovim_highlight :: proc(s: ^neovim.Screen, id: u32) -> neovim.Highlight {
	if id == 0 || int(id) >= len(s.highlights) {return {}}
	return s.highlights[id]
}

// Builds the screen at `origin`, the grid's top-left cell, into the list's current layer. `frame_time`
// is when the frame will be on screen, which a moving cursor is drawn for.
neovim_build :: proc(
	v: ^Neovim_View,
	client: ^neovim.Client,
	fonts: ^font.System,
	cache: ^glyphs.Cache,
	list: ^render.Draw_List,
	origin: [2]f32,
	metrics: Metrics,
	style: Neovim_Style,
	frame_time: render.Frame_Time,
) -> (
	Neovim_Frame,
	render.Build_Status,
) {
	s := &client.screen
	frame := Neovim_Frame{background = neovim_color(s.default_background)}
	if list.error != .None || s.columns <= 0 || s.rows <= 0 || len(s.cells) < s.columns * s.rows {
		return frame, .Ok
	}
	if reserve(&v.paints, s.columns) != nil {
		list.error = .Out_Of_Memory
		return frame, .Ok
	}
	b := Builder{list = list, cache = cache, fonts = fonts, metrics = metrics, origin = origin}
	row, column := s.cursor_row, s.cursor_column
	has_cursor := !s.busy && row >= 0 && row < s.rows && column >= 0 && column < s.columns
	paint: Cursor_Paint
	moving := false
	if has_cursor {
		paint, moving = neovim_cursor_begin(v, s, style, metrics, origin, frame_time)
	} else {
		neovim_cursor_reset(v)
	}
	blinking := has_cursor && s.mode.blink_on > 0 && s.mode.blink_off > 0
	frame.cursor_blinking = blinking && style.focused
	shown := has_cursor && !style.cursor_hidden && (!style.focused || !blinking || style.cursor_visible)
	solid_block := shown && style.focused && paint.shape == .Block && !moving
	text_start := len(list.glyphs)
	for y in 0 ..< s.rows {
		top := origin.y + f32(y) * metrics.cell_height
		neovim_row_paints(v, s, y)
		block_column := -1
		if solid_block && y == row {
			block_column = column
			v.paints[column].background = paint.color
			v.paints[column].foreground = neovim_cursor_text(v, paint)
		}
		neovim_row_backgrounds(v, &b, frame.background, top)
		for p, x in v.paints {
			if result := neovim_decorate(&b, p, origin.x + f32(x) * metrics.cell_width, top); result != .Ok {
				return frame, result
			}
		}
		if result := neovim_row_text(v, &b, client, style.family, top, block_column); result != .Ok {
			return frame, result
		}
		if list.error != .None {return frame, .Ok}
	}
	if !has_cursor {return frame, .Ok}
	frame.cursor = paint
	defer if v.cursor.present && list.error == .None {caret.motion_drawn(&v.cursor.motion)}
	if style.cursor_hidden || (!moving && (!shown || solid_block)) {return frame, .Ok}
	if moving {
		caret.paint_body_draw(list, paint, caret.motion_corners(&v.cursor.motion), style.cursor_effects,
			v.cursor.progress)
	}
	layer := list.layers[len(list.layers) - 1]
	if render.push_layer(list, layer.clip, layer.radius) != .None {return frame, .Ok}
	if !moving || paint.shape != .Block {
		cursor_outline(list, paint, !style.focused)
		return frame, .Ok
	}
	// A moving block draws the text it covers again in the cursor text colour, clipped to itself. Each
	// replay appends a glyph, so the range ends where the screen's text did.
	_ = render.push_rect(list, {rect = paint.head, color = paint.color})
	text := neovim_cursor_text(v, paint)
	text_end := len(list.glyphs)
	for i in text_start ..< text_end {
		cursor_replay_glyph(list, list.glyphs[i], {}, paint.head, text)
		if list.error != .None {break}
	}
	return frame, .Ok
}

// Where the cursor is, in its mode's shape and AIODev's colours, and whether it is moving there: with
// Cursor Animation on, a focused cursor glides, smears or trails to each new cell.
@(private)
neovim_cursor_begin :: proc(
	v: ^Neovim_View,
	s: ^neovim.Screen,
	style: Neovim_Style,
	metrics: Metrics,
	origin: [2]f32,
	frame_time: render.Frame_Time,
) -> (
	paint: Cursor_Paint,
	moving: bool,
) {
	row, column := s.cursor_row, s.cursor_column
	wide := column + 1 < s.columns && s.cells[row * s.columns + column + 1].glyph == 0
	cell := render.Rect {
		origin.x + f32(column) * metrics.cell_width,
		origin.y + f32(row) * metrics.cell_height,
		metrics.cell_width * (wide ? 2 : 1),
		metrics.cell_height,
	}
	paint = {
		head = cell, tail = cell, target = cell, shape = .Block,
		stroke = max(1, metrics.underline_thickness), color = style.cursor_color,
		text_color = style.cursor_text, minimum_contrast = style.minimum_contrast,
	}
	share := f32(s.mode.percentage > 0 ? s.mode.percentage : 25) / 100
	#partial switch s.mode.shape {
	case .Vertical:
		paint.shape, paint.stroke = .Bar, max(1, math.round(cell.width * share / 2))
	case .Horizontal:
		paint.shape, paint.stroke = .Underline, max(1, math.round(cell.height * share / 2))
	}
	e := style.cursor_effects
	if !style.focused || style.cursor_hidden || e.preset == .Off {
		neovim_cursor_reset(v)
		return
	}
	c := &v.cursor
	key := Neovim_Cursor_Key{paint.shape, metrics, origin, {s.columns, s.rows}}
	at := [2]int{column, row}
	if !c.present || c.key != key || c.effects != e || !caret.effects_active(e) || frame_time.display == {} {
		c^ = {key = key, cell = at, present = true}
		c.motion = {effects = e, target = cell, head = cell, tail = cell}
		return
	}
	if at != c.cell {
		c.cell = at
		caret.motion_retarget(&c.motion, cell)
	}
	paint.head, paint.tail = c.head, c.tail
	if !c.active {return}
	c.target = cell
	t := caret.motion_progress(&c.motion, frame_time)
	if t >= 1 {
		c.active = false
		caret.motion_place(&c.motion, 1)
	} else {
		moving = true
		caret.motion_place(&c.motion, t)
	}
	paint.head, paint.tail = c.head, c.tail
	return
}

// The cursor's text colour, lifted to the minimum contrast against the cursor as a terminal's is.
@(private)
neovim_cursor_text :: proc(v: ^Neovim_View, paint: Cursor_Paint) -> render.Color {
	if paint.minimum_contrast <= 1 {return paint.text_color}
	return minimum_contrast_cached(&v.contrast, paint.text_color, paint.color, paint.minimum_contrast)
}

// Fills v.paints, whose capacity holds the row, with row y's colours, attributes and glyphs. An
// underline without a special colour takes the text's.
@(private)
neovim_row_paints :: proc(v: ^Neovim_View, s: ^neovim.Screen, y: int) {
	foreground := neovim_color(s.default_foreground)
	background := neovim_color(s.default_background)
	clear(&v.paints)
	cells := s.cells[y * s.columns:(y + 1) * s.columns]
	for cell, x in cells {
		h := neovim_highlight(s, cell.highlight)
		p := Neovim_Paint {
			foreground = foreground,
			background = background,
			attributes = h.attributes,
			glyph      = cell.glyph,
			wide       = cell.glyph != 0 && x + 1 < len(cells) && cells[x + 1].glyph == 0,
		}
		if fg, ok := h.foreground.?; ok {p.foreground = neovim_color(fg)}
		if bg, ok := h.background.?; ok {p.background = neovim_color(bg)}
		if .Reverse in h.attributes {p.foreground, p.background = p.background, p.foreground}
		p.special = p.foreground
		if sp, ok := h.special.?; ok {p.special = neovim_color(sp)}
		_, _ = append(&v.paints, p)
	}
}

// Fills runs of one background that differs from the pane's own, which the pane card already draws.
@(private)
neovim_row_backgrounds :: proc(v: ^Neovim_View, b: ^Builder, base: render.Color, top: f32) {
	m := b.metrics
	start := 0
	for x in 1 ..= len(v.paints) {
		if x < len(v.paints) && v.paints[x].background == v.paints[start].background {continue}
		if v.paints[start].background != base {
			left := b.origin.x + f32(start) * m.cell_width
			rect(b, {left, top, f32(x - start) * m.cell_width, m.cell_height}, v.paints[start].background)
		}
		start = x
	}
}

@(private)
neovim_decorate :: proc(b: ^Builder, p: Neovim_Paint, left, top: f32) -> render.Build_Status {
	m := b.metrics
	baseline := top + m.baseline
	if .Strikethrough in p.attributes {
		rect(b, {left, baseline - m.strikethrough_offset, m.cell_width, m.strikethrough_thickness}, p.foreground)
	}
	t := m.underline_thickness
	line := baseline + m.underline_offset
	switch {
	case .Underline in p.attributes:
		rect(b, {left, line, m.cell_width, t}, p.special)
	case .Underdouble in p.attributes:
		rect(b, {left, line - t, m.cell_width, t}, p.special)
		rect(b, {left, line + t, m.cell_width, t}, p.special)
	case p.attributes & {.Undercurl, .Underdotted, .Underdashed} != {}:
		sprite: glyphs.Sprite = .Dashed_Underline
		if .Undercurl in p.attributes {
			sprite = .Curly_Underline
		} else if .Underdotted in p.attributes {
			sprite = .Dotted_Underline
		}
		entry, result := glyphs.sprite(b.cache, sprite, m.cell_width, t)
		if result != .Ok {return result}
		place(b, entry, {left, line + t / 2}, p.special)
	}
	return .Ok
}

@(private)
neovim_face :: proc(p: Neovim_Paint) -> font.Style {
	bold, italic := .Bold in p.attributes, .Italic in p.attributes
	if bold && italic {return .Bold_Italic}
	if bold {return .Bold}
	if italic {return .Italic}
	return .Regular
}

// Shapes the row's text in runs of one face, so programming ligatures form as they do in a terminal. A
// run breaks around the block cursor's cell, whose glyphs take the cursor text colour. The right half
// of a double-width character holds no glyph and leaves the run whole.
@(private, require_results)
neovim_row_text :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	client: ^neovim.Client,
	family: font.Family,
	top: f32,
	block_column: int,
) -> render.Build_Status {
	clear(&v.runes)
	clear(&v.columns)
	face: font.Style
	previous := -1
	for p, x in v.paints {
		if p.glyph == 0 {continue}
		next_face := neovim_face(p)
		if next_face != face || x == block_column || (previous >= 0 && previous == block_column) {
			if result := neovim_run(v, b, family, face, top); result != .Ok {return result}
		}
		appended := false
		if p.glyph & neovim.GLYPH_CLUSTER == 0 {
			appended = neovim_append_rune(v, rune(p.glyph), x)
		} else {
			appended = neovim_append_cluster(v, neovim.cluster(client, p.glyph), x)
		}
		if !appended {
			b.list.error = .Out_Of_Memory
			return .Ok
		}
		face, previous = next_face, x
	}
	return neovim_run(v, b, family, face, top)
}

@(private, require_results)
neovim_append_rune :: proc(v: ^Neovim_View, r: rune, x: int) -> bool {
	_, rune_error := append(&v.runes, r)
	_, column_error := append(&v.columns, x)
	return rune_error == nil && column_error == nil
}

// The runes of a cluster, each standing in column x.
@(private, require_results)
neovim_append_cluster :: proc(v: ^Neovim_View, text: string, x: int) -> bool {
	for r in text {
		if r == utf8.RUNE_ERROR {continue}
		if !neovim_append_rune(v, r, x) {return false}
	}
	return true
}

// Draws the pending run, then empties it.
@(private, require_results)
neovim_run :: proc(
	v: ^Neovim_View,
	b: ^Builder,
	family: font.Family,
	face: font.Style,
	top: f32,
) -> render.Build_Status {
	defer {
		clear(&v.runes)
		clear(&v.columns)
	}
	if len(v.runes) == 0 {return .Ok}
	clear(&v.shaped)
	m := b.metrics
	if err := font.shape(b.fonts, family, face, v.runes[:], m.size_px, &v.shaped, v.columns[:]); err != .None {
		log.errorf("term_view: shaping Neovim text failed: %v", err)
		for r, i in v.runes {
			g, found := font.glyph_lookup(b.fonts, family, face, r)
			if !found {continue}
			entry, result := glyphs.glyph(b.cache, g, m.size_px)
			if result != .Ok {return result}
			x := v.columns[i]
			place(b, entry, {b.origin.x + f32(x) * m.cell_width, top + m.baseline}, v.paints[x].foreground)
		}
		return .Ok
	}
	for start := 0; start < len(v.shaped); {
		cluster := v.shaped[start].cluster
		end := start + 1
		advance := v.shaped[start].advance
		for end < len(v.shaped) && v.shaped[end].cluster == cluster {
			advance += v.shaped[end].advance
			end += 1
		}
		last := max(cluster, (end < len(v.shaped) ? v.shaped[end].cluster : len(v.runes)) - 1)
		x := v.columns[cluster]
		p := v.paints[x]
		span := f32(v.columns[last] - x + (v.paints[v.columns[last]].wide ? 2 : 1)) * m.cell_width
		// D-042, as term_view draws: a cluster wider than its cells shrinks to fit around their centre.
		scale: f32 = 1
		if advance > span + 0.5 {scale = span / advance}
		left := b.origin.x + f32(x) * m.cell_width
		if scale < 1 || p.wide {left += (span - advance * scale) / 2}
		baseline := top + m.cell_height / 2 + (m.baseline - m.cell_height / 2) * scale
		pen: f32
		for g in v.shaped[start:end] {
			entry, result := glyphs.glyph(b.cache, g.glyph, m.size_px * scale, p.wide)
			if result != .Ok {return result}
			place(b, entry, {left + pen + g.offset.x * scale, baseline - g.offset.y * scale}, p.foreground)
			pen += g.advance * scale
		}
		start = end
	}
	return .Ok
}
