package term_view

import "aio:ghostty"
import "aio:colour"
import "aio:render"
import "core:math"
import "core:time"

Cursor_Preset :: enum u8 {
	Off,
	// The cursor glides to its new cell.
	Smooth,
	// The cursor stretches from where it was to where it goes and contracts behind its leading edge.
	Smear,
	// A fading, tapering trail follows the cursor to its new cell.
	Trail,
}

// How the cursor moves when the terminal puts it in another cell. Off, the zero value, draws it only
// where the terminal puts it. `strength`, 0..1, is how far a smear or trail lags behind the cursor;
// without `movement` the cursor lands at once and only the smear or trail shows the move.
Cursor_Effects :: struct {
	preset:   Cursor_Preset,
	duration: time.Duration,
	strength: f32,
	movement: bool,
}

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
	motion: Cursor_Motion,
	paint: Cursor_Paint,
	text_color: render.Color,
	staged: Maybe(Cursor_Transition_Pose),
}

// Start from the pose actually drawn, never a scheduler sample. Starting does not read a clock.
cursor_transition_start :: proc(t: ^Cursor_Transition, from, to: Cursor_Paint, effects: Cursor_Effects) {
	t^ = {
		paint = to,
		text_color = to.text_color,
		motion = {
			key = {effects = effects},
			target = to.target,
			head_from = from.head, tail_from = from.tail,
			head = from.head, tail = from.tail,
			drawn_head = from.head, drawn_tail = from.tail,
			active = cursor_effects_active(effects) && (from.head != to.target || from.tail != to.target),
			present = true,
		},
	}
	if !t.motion.active {cursor_place(&t.motion, 1)}
	if to.minimum_contrast > 1 {
		t.text_color = colour.minimum_contrast(to.text_color, to.color, to.minimum_contrast)
	}
}

cursor_transition_animate :: proc(t: ^Cursor_Transition, frame: render.Frame_Time, enabled: bool) -> bool {
	return cursor_motion_animate(&t.motion, frame, enabled)
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
	cursor_draw_body(list, p, t.motion.key.effects, t.motion.progress)
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

// A smear's body and a trail where it meets the cursor show the cursor colour at these opacities.
@(private)
CURSOR_SMEAR_OPACITY :: f32(0.8)
@(private)
CURSOR_TRAIL_OPACITY :: f32(0.7)
// A trail's far end, as a fraction of the cursor's size.
@(private)
CURSOR_TRAIL_TAIL_SCALE :: f32(0.3)
// A smear or trail draws as slices of at least CURSOR_SLICE_PX across the direction of the move, at
// most CURSOR_SLICES_MAX of them, so a move of any length costs a bounded number of rects.
@(private)
CURSOR_SLICE_PX :: f32(2)
@(private)
CURSOR_SLICES_MAX :: 32

// Geometry and configuration changes put the cursor where it is at once. Row identities are
// checked separately across the entire viewport, including scrolling regions below the first row.
@(private)
Cursor_Key :: struct {
	style:     ghostty.Render_State_Cursor_Visual_Style,
	metrics:   Metrics,
	origin:    [2]f32,
	grid:      [2]int,
	effects:   Cursor_Effects,
}

// `head` is the cursor cell, `tail` the far end of its smear or trail. The scheduler samples them
// before a build discovers the terminal's next destination. Retarget from `drawn_head`/`drawn_tail`,
// not that speculative sample: these are the positions actually drawn by the preceding build.
// Motions start one refresh before the first non-resuming frame, like ui.Motion.
@(private)
Cursor_Motion :: struct {
	key:                                     Cursor_Key,
	cell:                                    [2]int,
	target, head_from, tail_from, head, tail: render.Rect,
	drawn_head, drawn_tail:                   render.Rect,
	started:                                 time.Tick,
	// The focused cursor's pose survives idle blinking, so the next move can start from it.
	present:                                 bool,
	active:                                  bool,
	progress:                                f32,
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
	return cursor_motion_animate(&v.cursor, frame, enabled)
}

@(private)
cursor_motion_animate :: proc(c: ^Cursor_Motion, frame: render.Frame_Time, enabled: bool) -> bool {
	if !c.active {return false}
	if !enabled || frame.display == {} {
		c.active = false
		cursor_place(c, 1)
		return true
	}
	head, tail := c.head, c.tail
	t := cursor_progress(c, frame)
	if t >= 1 {c.active = false}
	cursor_place(c, t)
	return !c.active || c.head != head || c.tail != tail
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
	if !cursor_effects_active(b.style.cursor_effects) || !b.style.focused || b.style.cursor_suppressed ||
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

cursor_effects_active :: proc(e: Cursor_Effects) -> bool {
	if e.duration <= 0 {return false}
	switch e.preset {
	case .Off:
		return false
	case .Smooth:
		return e.movement
	case .Smear, .Trail:
		return e.movement || e.strength > 0
	}
	return false
}

@(private)
cursor_progress :: proc(c: ^Cursor_Motion, frame: render.Frame_Time) -> f32 {
	if c.started == {} {
		if frame.resuming {return 0}
		c.started = time.tick_add(frame.display, -frame.period)
	}
	return clamp(f32(time.tick_diff(c.started, frame.display)) / f32(c.key.effects.duration), 0, 1)
}

// How far along their paths the head and the tail are at progress `t`. Both settle exactly at 1. The
// head decelerates; a smear's tail eases in and out behind it, so the cursor stretches and then
// contracts, and a trail's tail lingers longer still.
@(private)
cursor_curves :: proc(e: Cursor_Effects, t: f32) -> (head, tail: f32) {
	u := 1 - t
	head = e.movement ? 1 - u * u * u : 1
	lag: f32
	switch e.preset {
	case .Off, .Smooth:
		return head, head
	case .Smear:
		lag = t * t * (3 - 2 * t)
	case .Trail:
		lag = t * t
	}
	return head, head + (lag - head) * clamp(e.strength, 0, 1)
}

@(private)
cursor_lerp :: proc(a, b: render.Rect, t: f32) -> render.Rect {
	return {
		a.x + (b.x - a.x) * t,
		a.y + (b.y - a.y) * t,
		a.width + (b.width - a.width) * t,
		a.height + (b.height - a.height) * t,
	}
}

// Places the head and the tail at progress `t`; a settled cursor sits on its target. The head lands on
// whole pixels, like the cells it passes, so its text clip and its rect agree.
@(private)
cursor_place :: proc(c: ^Cursor_Motion, t: f32) {
	c.progress = t
	if !c.active {
		c.head, c.tail = c.target, c.target
		return
	}
	head, tail := cursor_curves(c.key.effects, t)
	h := cursor_lerp(c.head_from, c.target, head)
	left, top := math.round(h.x), math.round(h.y)
	c.head = {left, top, math.round(h.x + h.width) - left, math.round(h.y + h.height) - top}
	c.tail = cursor_lerp(c.tail_from, c.target, tail)
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
	key := Cursor_Key{cursor.visual_style, m, b.origin, {b.columns, b.rows}, e}
	cell := [2]int{b.cursor_column, int(cursor.viewport_y)}
	target := render.Rect {
		b.origin.x + f32(cell.x) * m.cell_width,
		b.origin.y + f32(cell.y) * m.cell_height,
		m.cell_width * (cursor.wide_tail ? 2 : 1),
		m.cell_height,
	}
	if !c.present || c.key != key || !cursor_effects_active(e) || b.frame_time.display == {} {
		c^ = {key = key, cell = cell, target = target, head = target, tail = target, present = true}
		return
	}
	if cell != c.cell {
		c.head_from, c.tail_from = c.drawn_head, c.drawn_tail
		c.cell, c.started, c.active = cell, {}, true
	}
	if !c.active {return}
	c.target = target
	b.cursor_t = cursor_progress(c, b.frame_time)
	if b.cursor_t >= 1 {
		c.active = false
		return
	}
	b.cursor_moving = true
	cursor_place(c, b.cursor_t)
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
	cursor_draw_body(b.list, paint, b.style.cursor_effects, b.cursor_t)
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
cursor_draw_body :: proc(list: ^render.Draw_List, p: Cursor_Paint, e: Cursor_Effects, progress: f32) {
	if e.strength <= 0 || (e.preset != .Smear && e.preset != .Trail) || p.tail == p.head {return}
	tail := cursor_box(p, p.tail)
	if e.preset == .Trail {
		shrink_x := tail.width * (1 - CURSOR_TRAIL_TAIL_SCALE) / 2
		shrink_y := tail.height * (1 - CURSOR_TRAIL_TAIL_SCALE) / 2
		tail = {
			tail.x + shrink_x, tail.y + shrink_y,
			tail.width - 2 * shrink_x, tail.height - 2 * shrink_y,
		}
	}
	cursor_body(list, tail, cursor_box(p, p.head), e.preset == .Trail, p.color, progress)
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

// Fills the convex hull of `tail` and `head` with slices across the direction of the move, each
// covering the hull where it lies. A trail fades from the head to nothing at the tail.
@(private)
cursor_body :: proc(
	list: ^render.Draw_List, tail, head: render.Rect, trail: bool, fill: render.Color, progress: f32,
) {
	// The hull is the union of the boxes between the two at every s in 0..1. Each slice keeps the s
	// whose box reaches into it, and covers what those boxes cover across it.
	moved := [2]f32 {
		head.x + head.width / 2 - tail.x - tail.width / 2,
		head.y + head.height / 2 - tail.y - tail.height / 2,
	}
	axis := abs(moved.x) >= abs(moved.y) ? 0 : 1
	from, to := cursor_span(tail, axis), cursor_span(head, axis)
	from_across, to_across := cursor_span(tail, 1 - axis), cursor_span(head, 1 - axis)
	lo, hi := min(from[0], to[0]), max(from[1], to[1])
	if hi <= lo {return}
	uniform := !trail && from_across == to_across
	count := uniform ? 1 : clamp(int(math.ceil((hi - lo) / CURSOR_SLICE_PX)), 1, CURSOR_SLICES_MAX)
	from_center, to_center := (from[0] + from[1]) / 2, (to[0] + to[1]) / 2
	near := lo
	for i in 1 ..= count {
		// Inner edges on whole pixels, so neighbouring slices never blend twice over one pixel.
		far := i == count ? hi : math.round(lo + (hi - lo) * f32(i) / f32(count))
		if far <= near {continue}
		s := [2]f32{0, 1}
		cursor_s_limit(&s, from[0], to[0], far, true)
		cursor_s_limit(&s, from[1], to[1], near, false)
		if s[0] <= s[1] {
			start := min(
				from_across[0] + (to_across[0] - from_across[0]) * s[0],
				from_across[0] + (to_across[0] - from_across[0]) * s[1],
			)
			end := max(
				from_across[1] + (to_across[1] - from_across[1]) * s[0],
				from_across[1] + (to_across[1] - from_across[1]) * s[1],
			)
			alpha := CURSOR_SMEAR_OPACITY
			if trail {
				q := f32(1)
				if to_center != from_center {
					q = clamp(((near + far) / 2 - from_center) / (to_center - from_center), 0, 1)
				}
				alpha = CURSOR_TRAIL_OPACITY * q * (1 - progress)
			}
			if end > start && alpha > 0 {
				tinted := fill
				tinted.a *= alpha
				piece := render.Rect{near, start, far - near, end - start}
				if axis == 1 {piece = {start, near, end - start, far - near}}
				_ = render.push_rect(list, {rect = piece, color = tinted})
			}
		}
		near = far
	}
}

@(private)
cursor_span :: proc(r: render.Rect, axis: int) -> [2]f32 {
	if axis == 0 {return {r.x, r.x + r.width}}
	return {r.y, r.y + r.height}
}

// Narrows `s` to where `from + (to - from) * s` is at most `limit`, or at least it.
@(private)
cursor_s_limit :: proc(s: ^[2]f32, from, to, limit: f32, at_most: bool) {
	sign := at_most ? f32(1) : f32(-1)
	start, slope, edge := from * sign, (to - from) * sign, limit * sign
	if slope == 0 {
		if start > edge {s^ = {1, 0}}
		return
	}
	at := (edge - start) / slope
	if slope > 0 {s[1] = min(s[1], at)} else {s[0] = max(s[0], at)}
}
