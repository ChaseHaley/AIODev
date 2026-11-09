package term_view

import "aio:ghostty"
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
	// A focused cursor was drawn by the last build, so the next move can start from it.
	present:                                 bool,
	active:                                  bool,
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
	c := &v.cursor
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
	if !cursor_effects_move(b.style.cursor_effects) || !b.style.focused ||
	   !b.style.cursor_phase_visible || !b.cursor.visible ||
	   !b.cursor.viewport_has_value || b.frame_time.display == {} {return true}
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

@(private)
cursor_effects_move :: proc(e: Cursor_Effects) -> bool {
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
	   !b.style.cursor_phase_visible ||
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
	if !c.present || c.key != key || !cursor_effects_move(e) || b.frame_time.display == {} {
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
cursor_box :: proc(b: ^Builder, cell: render.Rect) -> render.Rect {
	stroke := max(1, b.metrics.underline_thickness)
	#partial switch b.cursor.visual_style {
	case .Bar:
		return {cell.x, cell.y, stroke * 2, cell.height}
	case .Underline:
		return {cell.x, cell.y + cell.height - stroke * 2, cell.width, stroke * 2}
	}
	return cell
}

@(private)
cursor_outline :: proc(b: ^Builder, cell: render.Rect, fill: render.Color) {
	stroke := max(1, b.metrics.underline_thickness)
	style := b.cursor.visual_style
	switch {
	case !b.style.focused || style == .Block_Hollow:
		rect(b, {cell.x, cell.y, cell.width, stroke}, fill)
		rect(b, {cell.x, cell.y + cell.height - stroke, cell.width, stroke}, fill)
		rect(b, {cell.x, cell.y, stroke, cell.height}, fill)
		rect(b, {cell.x + cell.width - stroke, cell.y, stroke, cell.height}, fill)
	case style == .Bar:
		rect(b, {cell.x, cell.y, stroke * 2, cell.height}, fill)
	case style == .Underline:
		rect(b, {cell.x, cell.y + cell.height - stroke * 2, cell.width, stroke * 2}, fill)
	}
}

// Draws the cursor partway along its motion: the smear or trail under the text, then the head above
// it. A block head draws the text it covers again in the cursor text colour, clipped to itself, so the
// text stays legible wherever the head is.
@(private)
cursor_draw_moving :: proc(v: ^View, b: ^Builder) {
	c := &v.cursor
	e := b.style.cursor_effects
	fill := b.cursor_color
	if e.strength > 0 && (e.preset == .Smear || e.preset == .Trail) && c.tail != c.head {
		tail := cursor_box(b, c.tail)
		if e.preset == .Trail {
			shrink_x := tail.width * (1 - CURSOR_TRAIL_TAIL_SCALE) / 2
			shrink_y := tail.height * (1 - CURSOR_TRAIL_TAIL_SCALE) / 2
			tail = {
				tail.x + shrink_x, tail.y + shrink_y,
				tail.width - 2 * shrink_x, tail.height - 2 * shrink_y,
			}
		}
		cursor_body(b, tail, cursor_box(b, c.head), e.preset == .Trail, fill)
	}
	layer := b.list.layers[len(b.list.layers) - 1]
	clip := layer.clip
	head := c.head
	if b.cursor.visual_style != .Block {
		if render.push_layer(b.list, clip, layer.radius) != .None {return}
		cursor_outline(b, head, fill)
		return
	}
	left, top := max(head.x, clip.x), max(head.y, clip.y)
	right := min(head.x + head.width, clip.x + clip.width)
	bottom := min(head.y + head.height, clip.y + clip.height)
	if right <= left || bottom <= top {return}
	if render.push_layer(b.list, clip, layer.radius) != .None {return}
	bounds := render.Rect{left, top, right - left, bottom - top}
	rect(b, head, fill)
	text := b.style.cursor_text
	if b.style.minimum_contrast > 1 {
		text = minimum_contrast_cached(&v.contrast, text, fill, b.style.minimum_contrast)
	}
	for span in b.cursor_text {
		for i in span.start ..< span.end {
			g := b.list.glyphs[i]
			placed, atlas, visible := quad_clipped(g.rect, g.atlas, bounds)
			if !visible {continue}
			g.rect, g.atlas = placed, atlas
			g.color = text
			if render.push_glyph(b.list, g) != .None {return}
		}
	}
}

// Fills the convex hull of `tail` and `head` with slices across the direction of the move, each
// covering the hull where it lies. A trail fades from the head to nothing at the tail.
@(private)
cursor_body :: proc(b: ^Builder, tail, head: render.Rect, trail: bool, fill: render.Color) {
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
				alpha = CURSOR_TRAIL_OPACITY * q * (1 - b.cursor_t)
			}
			if end > start && alpha > 0 {
				tinted := fill
				tinted.a *= alpha
				piece := render.Rect{near, start, far - near, end - start}
				if axis == 1 {piece = {start, near, end - start, far - near}}
				rect(b, piece, tinted)
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
