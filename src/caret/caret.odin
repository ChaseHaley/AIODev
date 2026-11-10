package caret

import "aio:render"
import "core:math"
import "core:time"

// How a text cursor moves when it goes somewhere else. A terminal's cell cursor and every interface
// text field's caret share it, so the Cursor Animation settings look the same everywhere.
Preset :: enum u8 {
	Off,
	// The cursor glides to its new place.
	Smooth,
	// The cursor stretches from where it was to where it goes and contracts behind its leading edge.
	Smear,
	// A fading, tapering trail follows the cursor to its new place.
	Trail,
}

// Off, the zero value, draws the cursor only where it is. `strength`, 0..1, is how far a smear or
// trail lags behind the cursor; without `movement` the cursor lands at once and only the smear or
// trail shows the move.
Effects :: struct {
	preset:   Preset,
	duration: time.Duration,
	strength: f32,
	movement: bool,
}

effects_active :: proc(e: Effects) -> bool {
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

// `head` is the cursor, `tail` the far end of its smear or trail. A scheduler may sample them before a
// build discovers the cursor's next destination, so retarget from `drawn_head`/`drawn_tail`, the
// positions the preceding build actually drew. Motions start one refresh before the first
// non-resuming frame, like ui.Motion.
Motion :: struct {
	effects:                                  Effects,
	target, head_from, tail_from, head, tail: render.Rect,
	drawn_head, drawn_tail:                   render.Rect,
	started:                                  time.Tick,
	active:                                   bool,
	progress:                                 f32,
}

// Sends the cursor toward `target` from the pose last drawn; the motion starts with the next frame
// that samples it.
motion_retarget :: proc(m: ^Motion, target: render.Rect) {
	m.head_from, m.tail_from = m.drawn_head, m.drawn_tail
	m.target, m.started, m.active = target, {}, true
}

// Advances the motion to `frame`; true when the cursor's pose changed. Without `enabled` a motion
// lands at once. Settling reports a change once, and a cursor at rest reports none.
motion_animate :: proc(m: ^Motion, frame: render.Frame_Time, enabled: bool) -> bool {
	if !m.active {return false}
	if !enabled || frame.display == {} {
		m.active = false
		motion_place(m, 1)
		return true
	}
	head, tail := m.head, m.tail
	t := motion_progress(m, frame)
	if t >= 1 {m.active = false}
	motion_place(m, t)
	return !m.active || m.head != head || m.tail != tail
}

// How far along the motion is at `frame`, 0..1. The first non-resuming frame starts it.
motion_progress :: proc(m: ^Motion, frame: render.Frame_Time) -> f32 {
	if m.started == {} {
		if frame.resuming {return 0}
		m.started = time.tick_add(frame.display, -frame.period)
	}
	return clamp(f32(time.tick_diff(m.started, frame.display)) / f32(m.effects.duration), 0, 1)
}

// Places the head and the tail at progress `t`; a settled cursor sits on its target. The head lands on
// whole pixels, like the cells or glyphs it passes, so its text clip and its rect agree.
motion_place :: proc(m: ^Motion, t: f32) {
	m.progress = t
	if !m.active {
		m.head, m.tail = m.target, m.target
		return
	}
	head, tail := curves(m.effects, t)
	h := lerp(m.head_from, m.target, head)
	left, top := math.round(h.x), math.round(h.y)
	m.head = {left, top, math.round(h.x + h.width) - left, math.round(h.y + h.height) - top}
	m.tail = lerp(m.tail_from, m.target, tail)
}

// A smear's body and a trail where it meets the cursor show the cursor colour at these opacities.
@(private)
SMEAR_OPACITY :: f32(0.8)
@(private)
TRAIL_OPACITY :: f32(0.7)
// A trail's far end, as a fraction of the cursor's size.
@(private)
TRAIL_TAIL_SCALE :: f32(0.3)
// A smear or trail draws as slices of at least SLICE_PX across the direction of the move, at most
// SLICES_MAX of them, so a move of any length costs a bounded number of rects.
@(private)
SLICE_PX :: f32(2)
@(private)
SLICES_MAX :: 32

// Draws the smear or trail between the boxes the cursor's shape fills at its tail and its head, if
// the effects have one. Callers draw the head themselves, over it.
body_draw :: proc(
	list: ^render.Draw_List, tail, head: render.Rect, e: Effects, fill: render.Color, progress: f32,
) {
	if e.strength <= 0 || (e.preset != .Smear && e.preset != .Trail) || tail == head {return}
	far := tail
	if e.preset == .Trail {
		shrink_x := far.width * (1 - TRAIL_TAIL_SCALE) / 2
		shrink_y := far.height * (1 - TRAIL_TAIL_SCALE) / 2
		far = {far.x + shrink_x, far.y + shrink_y, far.width - 2 * shrink_x, far.height - 2 * shrink_y}
	}
	body(list, far, head, e.preset == .Trail, fill, progress)
}

// How far along their paths the head and the tail are at progress `t`. Both settle exactly at 1. The
// head decelerates; a smear's tail eases in and out behind it, so the cursor stretches and then
// contracts, and a trail's tail lingers longer still.
@(private)
curves :: proc(e: Effects, t: f32) -> (head, tail: f32) {
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
lerp :: proc(a, b: render.Rect, t: f32) -> render.Rect {
	return {
		a.x + (b.x - a.x) * t,
		a.y + (b.y - a.y) * t,
		a.width + (b.width - a.width) * t,
		a.height + (b.height - a.height) * t,
	}
}

// Fills the convex hull of `tail` and `head` with slices across the direction of the move, each
// covering the hull where it lies. A trail fades from the head to nothing at the tail.
@(private)
body :: proc(
	list: ^render.Draw_List, tail, head: render.Rect, trail: bool, fill: render.Color, progress: f32,
) {
	// The hull is the union of the boxes between the two at every s in 0..1. Each slice keeps the s
	// whose box reaches into it, and covers what those boxes cover across it.
	moved := [2]f32 {
		head.x + head.width / 2 - tail.x - tail.width / 2,
		head.y + head.height / 2 - tail.y - tail.height / 2,
	}
	axis := abs(moved.x) >= abs(moved.y) ? 0 : 1
	from, to := span(tail, axis), span(head, axis)
	from_across, to_across := span(tail, 1 - axis), span(head, 1 - axis)
	lo, hi := min(from[0], to[0]), max(from[1], to[1])
	if hi <= lo {return}
	uniform := !trail && from_across == to_across
	count := uniform ? 1 : clamp(int(math.ceil((hi - lo) / SLICE_PX)), 1, SLICES_MAX)
	from_center, to_center := (from[0] + from[1]) / 2, (to[0] + to[1]) / 2
	near := lo
	for i in 1 ..= count {
		// Inner edges on whole pixels, so neighbouring slices never blend twice over one pixel.
		far := i == count ? hi : math.round(lo + (hi - lo) * f32(i) / f32(count))
		if far <= near {continue}
		s := [2]f32{0, 1}
		s_limit(&s, from[0], to[0], far, true)
		s_limit(&s, from[1], to[1], near, false)
		if s[0] <= s[1] {
			start := min(
				from_across[0] + (to_across[0] - from_across[0]) * s[0],
				from_across[0] + (to_across[0] - from_across[0]) * s[1],
			)
			end := max(
				from_across[1] + (to_across[1] - from_across[1]) * s[0],
				from_across[1] + (to_across[1] - from_across[1]) * s[1],
			)
			alpha := SMEAR_OPACITY
			if trail {
				q := f32(1)
				if to_center != from_center {
					q = clamp(((near + far) / 2 - from_center) / (to_center - from_center), 0, 1)
				}
				alpha = TRAIL_OPACITY * q * (1 - progress)
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
span :: proc(r: render.Rect, axis: int) -> [2]f32 {
	if axis == 0 {return {r.x, r.x + r.width}}
	return {r.y, r.y + r.height}
}

// Narrows `s` to where `from + (to - from) * s` is at most `limit`, or at least it.
@(private)
s_limit :: proc(s: ^[2]f32, from, to, limit: f32, at_most: bool) {
	sign := at_most ? f32(1) : f32(-1)
	start, slope, edge := from * sign, (to - from) * sign, limit * sign
	if slope == 0 {
		if start > edge {s^ = {1, 0}}
		return
	}
	at := (edge - start) / slope
	if slope > 0 {s[1] = min(s[1], at)} else {s[0] = max(s[0], at)}
}
