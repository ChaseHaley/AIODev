package term_view

import "cosmos:caret"
import "aio:ghostty"
import "cosmos:colour"
import "cosmos:render"
import "core:math"

// Cell geometry, not just the filled bar/underline. Head and tail describe the last healthy draw;
// target is the terminal's current logical destination, including a wide character's full width.
Cursor_Paint :: caret.Paint

// The shape the terminal's render state reports, as the caret package names it.
@(private)
cursor_shape :: proc(style: ghostty.Cursor_Style) -> caret.Shape {
	switch style {
	case .Bar:          return .Bar
	case .Block:        return .Block
	case .Underline:    return .Underline
	case .Block_Hollow: return .Block_Hollow
	}
	return .Block
}

@(private)
Cursor_Transition_Pose :: struct {
	head, tail: render.Rect,
}

// Fixed, resource-free motion owned by the window. It uses exactly the local cursor's engine. The head
// turns from the colour and shape it left to those of the surface it is going to as it travels.
Cursor_Transition :: struct {
	motion: caret.Motion,
	paint: Cursor_Paint,
	text_color: render.Color,
	staged: Maybe(Cursor_Transition_Pose),
	color_from: render.Color,
	shape_from: caret.Shape,
	stroke_from: f32,
}

// Start from the pose actually drawn, never a scheduler sample. Starting does not read a clock.
cursor_transition_start :: proc(t: ^Cursor_Transition, from, to: Cursor_Paint, effects: caret.Effects) {
	t^ = {
		paint = to,
		text_color = to.text_color,
		color_from = from.color,
		shape_from = from.shape,
		stroke_from = from.stroke,
		motion = {
			effects = effects,
			target = to.target,
			head_from = from.head, tail_from = from.tail,
			head = from.head, tail = from.tail,
			drawn_head = from.head, drawn_tail = from.tail,
			active = caret.effects_active(effects) && (from.head != to.target || from.tail != to.target),
		},
	}
	if !t.motion.active {caret.motion_place(&t.motion, 1)}
	if to.minimum_contrast > 1 {
		t.text_color = colour.minimum_contrast(to.text_color, to.color, to.minimum_contrast)
	}
}

cursor_transition_animate :: proc(t: ^Cursor_Transition, frame: render.Frame_Time, enabled: bool) -> bool {
	return caret.motion_animate(&t.motion, frame, enabled)
}

cursor_transition_active :: proc(t: ^Cursor_Transition) -> bool {
	return t.motion.active
}

cursor_transition_paint :: proc(t: ^Cursor_Transition) -> Cursor_Paint {
	p := t.paint
	p.head, p.tail = t.motion.drawn_head, t.motion.drawn_tail
	return p
}

// The enclosing frame owns acceptance: later overlay construction can still reject this draw.
cursor_transition_commit :: proc(t: ^Cursor_Transition) {
	if pose, ok := t.staged.?; ok {
		t.motion.drawn_head, t.motion.drawn_tail = pose.head, pose.tail
		t.staged = nil
	}
}

// The window's content clip, deliberately not the destination pane's clip.
cursor_transition_draw :: proc(t: ^Cursor_Transition, list: ^render.Draw_List, clip: render.Rect) {
	if render.push_layer(list, clip) != .None {return}
	p := t.paint
	p.head, p.tail = t.motion.head, t.motion.tail
	turn := t.motion.active ? caret.smooth(t.motion.progress) : 1
	p.color = caret.mix_colors(t.color_from, p.color, turn)
	cursor_draw_body(list, p, nil, t.motion.effects, t.motion.progress)
	if p.shape == .Block_Hollow {
		cursor_outline(list, p)
	} else {
		from := caret.shape_box(t.shape_from, t.stroke_from, p.head)
		to := caret.shape_box(p.shape, p.stroke, p.head)
		_ = render.push_rect(list, {rect = caret.mix_rects(from, to, turn), color = p.color})
	}
	if list.error == .None {
		t.staged = Cursor_Transition_Pose{p.head, p.tail}
	}
}

// Every pane masks lower cursor-text replay, including nonterminal floats. A terminal supplies its
// cached glyphs; nil is an opaque pane without terminal text. Keep the original rounded pane mask
// and crop glyph geometry/UVs to the sampled head and source clip.
cursor_transition_pane :: proc(
	t: ^Cursor_Transition, list, source: ^render.Draw_List, offset: [2]f32,
	clip: render.Rect, radius: f32,
) {
	p := t.paint
	p.head, p.tail = t.motion.head, t.motion.tail
	if p.shape != .Block || list.error != .None {return}
	if source != nil && source.error != .None {return}
	bounds, _, visible := quad_clipped(p.head, p.head, clip)
	if !visible {return}
	if render.push_layer(list, clip, radius) != .None {return}
	_ = render.push_rect(list, {rect = bounds, color = p.color})
	if source == nil {return}
	for layer in source.layers {
		source_clip := layer.clip
		source_clip.x += offset.x
		source_clip.y += offset.y
		glyph_bounds, _, intersects := quad_clipped(bounds, bounds, source_clip)
		if !intersects {continue}
		for i in layer.glyph_start ..< layer.glyph_start + layer.glyph_count {
			cursor_replay_glyph(list, source.glyphs[i], offset, glyph_bounds, t.text_color)
			if list.error != .None {return}
		}
	}
}

// Geometry and configuration changes put the cursor where it is at once. Row identities are
// checked separately across the entire viewport, including scrolling regions below the first row.
@(private)
Cursor_Key :: struct {
	style:     ghostty.Cursor_Style,
	metrics:   Metrics,
	origin:    [2]f32,
	grid:      [2]int,
}

// The motion's effects are part of its key too: changing them puts the cursor where it is at once.
@(private)
Cursor_Motion :: struct {
	key:          Cursor_Key,
	cell:         [2]int,
	using motion: caret.Motion,
	// The focused cursor's pose survives idle blinking, so the next move can start from it.
	present:      bool,
}

// Glyphs a row drew for its text, which a moving block cursor draws again over itself.
@(private)
Glyph_Span :: struct {
	start, end: int,
}

// Advances the cursor's motion to `frame`; true when what the cursor looks like changed, so a cached
// drawing of the view is stale. Without `enabled` a motion lands at once. Settling reports a change
// once, and a cursor at rest reports none.
cursor_animate :: proc(v: ^View, frame: render.Frame_Time, enabled: bool) -> bool {
	return caret.motion_animate(&v.cursor.motion, frame, enabled)
}

cursor_animating :: proc(v: ^View) -> bool {
	return v.cursor.active
}

// Forgets where the cursor was drawn, so the next build draws it where the terminal puts it, with no
// motion. Call it when the view is hidden, scrolled or loses the keyboard.
cursor_reset :: proc(v: ^View) {
	if v.cursor.present {v.cursor = {}}
}

@(private, require_results)
cursor_viewport_capture :: proc(v: ^View, b: ^Builder) -> bool {
	if !caret.effects_active(b.style.cursor_effects) || !b.style.focused || b.style.cursor_suppressed ||
	   !b.cursor.visible || !b.cursor.viewport_has_value || b.frame_time.display == {} {return true}
	if len(v.cursor_rows) != b.rows {cursor_reset(v)}
	if resize(&v.cursor_rows, b.rows) != nil {
		b.list.error = .Out_Of_Memory
		return false
	}
	for y in 0 ..< b.rows {
		id: ghostty.Render_State_Row_Id
		if !ghostty.render_state_row_iterator_next(v.rows) ||
		   ghostty.render_state_row_get(v.rows, .Id, &id) != .Success {
			b.list.error = .Construction_Failed
			return false
		}
		if v.cursor_rows[y] != id {cursor_reset(v)}
		v.cursor_rows[y] = id
	}
	if ghostty.render_state_get(v.state, .Row_Iterator, &v.rows) != .Success {
		b.list.error = .Construction_Failed
		return false
	}
	return true
}

// Decides, before the first cell is painted, whether this build draws the cursor in motion: a moving
// cursor leaves its destination's text alone and draws its own over the cells it passes instead.
@(private)
cursor_begin :: proc(v: ^View, b: ^Builder) {
	c := &v.cursor
	cursor := b.cursor
	if !cursor.visible ||
	   !cursor.viewport_has_value ||
	   !b.style.focused ||
	   b.style.cursor_suppressed ||
	   b.style.cursor_effects.preset == .Off {
		cursor_reset(v)
		return
	}
	e := b.style.cursor_effects
	m := b.metrics
	key := Cursor_Key{cursor.visual_style, m, b.origin, {b.columns, b.rows}}
	cell := [2]int{b.cursor_column, int(cursor.viewport_y)}
	target := render.Rect {
		b.origin.x + f32(cell.x) * m.cell_width,
		b.origin.y + f32(cell.y) * m.cell_height,
		m.cell_width * (cursor.wide_tail ? 2 : 1),
		m.cell_height,
	}
	if !c.present || c.key != key || c.effects != e || !caret.effects_active(e) || b.frame_time.display == {} {
		c^ = {
			key = key, cell = cell, present = true,
			motion = {effects = e, target = target, head = target, tail = target},
		}
		return
	}
	if cell != c.cell {
		c.cell = cell
		caret.motion_retarget(&c.motion, target)
	}
	if !c.active {return}
	c.target = target
	b.cursor_t = caret.motion_progress(&c.motion, b.frame_time)
	if b.cursor_t >= 1 {
		c.active = false
		return
	}
	b.cursor_moving = true
	caret.motion_place(&c.motion, b.cursor_t)
	b.cursor_row = int(math.floor((c.head.y - b.origin.y) / m.cell_height))
}

// Remembers the glyphs row `y` drew for its text from glyph `start` on, when the moving head covers it.
@(private)
cursor_note_row :: proc(b: ^Builder, y, start: int) {
	if !b.cursor_moving {return}
	i := y - b.cursor_row
	if i >= 0 && i < len(b.cursor_text) {b.cursor_text[i] = {start, len(b.list.glyphs)}}
}

@(private)
cursor_outline :: proc(list: ^render.Draw_List, p: Cursor_Paint, hollow := false) {
	// A block rests between a cell's background and its glyph, so only the hollow outline draws here.
	if p.shape == .Block && !hollow {return}
	caret.shape_draw(list, p.shape, p.stroke, p.head, p.color, hollow)
}

// Draws the cursor partway along its motion: the smear or trail under the text, then the head above
// it. A block head draws the text it covers again in the cursor text colour, clipped to itself, so the
// text stays legible wherever the head is.
@(private)
cursor_draw_moving :: proc(v: ^View, b: ^Builder, paint: Cursor_Paint) {
	corners := caret.motion_corners(&v.cursor.motion)
	cursor_draw_body(b.list, paint, corners, b.style.cursor_effects, b.cursor_t)
	layer := b.list.layers[len(b.list.layers) - 1]
	if render.push_layer(b.list, layer.clip, layer.radius) != .None {return}
	if paint.shape != .Block {
		cursor_outline(b.list, paint)
		return
	}
	rect(b, paint.head, paint.color)
	text := paint.text_color
	if paint.minimum_contrast > 1 {
		text = minimum_contrast_cached(&v.contrast, text, paint.color, paint.minimum_contrast)
	}
	for span in b.cursor_text {
		for i in span.start ..< span.end {
			cursor_replay_glyph(b.list, b.list.glyphs[i], {}, paint.head, text)
			if b.list.error != .None {return}
		}
	}
}

@(private)
cursor_draw_body :: proc(
	list: ^render.Draw_List, p: Cursor_Paint, corners: []render.Rect, e: caret.Effects, progress: f32,
) {
	caret.paint_body_draw(list, p, corners, e, progress)
}

@(private)
cursor_replay_glyph :: proc(
	list: ^render.Draw_List, glyph: render.Glyph_Instance, offset: [2]f32,
	bounds: render.Rect, text: render.Color,
) {
	g := glyph
	g.rect.x += offset.x
	g.rect.y += offset.y
	if g.flags & render.GLYPH_FADE != 0 {
		g.fade_start += offset.x
		g.fade_end += offset.x
	}
	placed, atlas, visible := quad_clipped(g.rect, g.atlas, bounds)
	if !visible {return}
	g.rect, g.atlas, g.color = placed, atlas, text
	_ = render.push_glyph(list, g)
}
