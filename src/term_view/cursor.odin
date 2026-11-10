package term_view

import "aio:caret"
import "aio:ghostty"
import "aio:colour"
import "aio:render"
import "core:math"

// Cell geometry, not just the filled bar/underline. Head and tail describe the last healthy draw;
// target is the terminal's current logical destination, including a wide character's full width.
Cursor_Paint :: struct {
	head, tail, target:    render.Rect,
	shape:                 ghostty.Render_State_Cursor_Visual_Style,
	color, text_color:    render.Color,
	stroke, minimum_contrast: f32,
}

@(private)
Cursor_Transition_Pose :: struct {
	head, tail: render.Rect,
}

// Fixed, resource-free motion owned by the window. It uses exactly the local cursor's engine.
Cursor_Transition :: struct {
	motion: caret.Motion,
	paint: Cursor_Paint,
	text_color: render.Color,
	staged: Maybe(Cursor_Transition_Pose),
}

// Start from the pose actually drawn, never a scheduler sample. Starting does not read a clock.
cursor_transition_start :: proc(t: ^Cursor_Transition, from, to: Cursor_Paint, effects: caret.Effects) {
	t^ = {
		paint = to,
		text_color = to.text_color,
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
	cursor_draw_body(list, p, nil, t.motion.effects, t.motion.progress)
	if p.shape == .Block {
		_ = render.push_rect(list, {rect = p.head, color = p.color})
	} else {
		cursor_outline(list, p)
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
	style:     ghostty.Render_State_Cursor_Visual_Style,
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

// What of a cursor cell the cursor's shape fills, which is what a smear or trail stretches.
@(private)
cursor_box :: proc(p: Cursor_Paint, cell: render.Rect) -> render.Rect {
	stroke := p.stroke
	#partial switch p.shape {
	case .Bar:
		return {cell.x, cell.y, stroke * 2, cell.height}
	case .Underline:
		return {cell.x, cell.y + cell.height - stroke * 2, cell.width, stroke * 2}
	}
	return cell
}

@(private)
cursor_outline :: proc(list: ^render.Draw_List, p: Cursor_Paint, hollow := false) {
	cell, stroke, fill := p.head, p.stroke, p.color
	b := Builder{list = list}
	switch {
	case hollow || p.shape == .Block_Hollow:
		rect(&b, {cell.x, cell.y, cell.width, stroke}, fill)
		rect(&b, {cell.x, cell.y + cell.height - stroke, cell.width, stroke}, fill)
		rect(&b, {cell.x, cell.y, stroke, cell.height}, fill)
		rect(&b, {cell.x + cell.width - stroke, cell.y, stroke, cell.height}, fill)
	case p.shape == .Bar:
		rect(&b, {cell.x, cell.y, stroke * 2, cell.height}, fill)
	case p.shape == .Underline:
		rect(&b, {cell.x, cell.y + cell.height - stroke * 2, cell.width, stroke * 2}, fill)
	}
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

// The smear or trail from the paint's tail through `corners` to its head, as the cursor's shape fills
// each of their cells.
@(private)
cursor_draw_body :: proc(
	list: ^render.Draw_List, p: Cursor_Paint, corners: []render.Rect, e: caret.Effects, progress: f32,
) {
	boxes: [caret.CORNERS_MAX]render.Rect
	n := min(len(corners), caret.CORNERS_MAX)
	for cell, i in corners[:n] {boxes[i] = cursor_box(p, cell)}
	caret.body_draw(list, cursor_box(p, p.tail), boxes[:n], cursor_box(p, p.head), e, p.color, progress)
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
