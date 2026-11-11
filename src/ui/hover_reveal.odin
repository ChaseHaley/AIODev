package ui

import "aio:render"
import "core:time"

// A surface that a hover on its trigger shows, such as a map under a header glyph or a submenu beside its
// row. It shows while the pointer is on the trigger or the surface, and also while the pointer has left
// the trigger and is still heading for the surface: "menu aim", as Amazon's mega dropdown and Ben Kamens's
// jQuery-menu-aim do it, also called a safe triangle (Floating UI's safePolygon, Radix UI's pointer grace).
//
// Where something else wants the hover, such as the other rows of the menu a submenu hangs from, the rule
// is Radix UI's submenu grace: the pointer must stay inside the polygon from the point where it left the
// trigger, pulled HOVER_AIM_BLEED back, to the whole surface, keep moving toward the surface, and arrive
// within HOVER_AIM_GRACE of leaving. Anything else, such as a move down to the next row or a pause on it
// past the grace, gives that row the hover.
//
// With nothing else wanting the hover the area is wider: the convex hull of the trigger and the surface,
// each grown by a slack for a wavering hand. A triangle from the point where the pointer left proved too
// thin when a small trigger sits just above a wide surface: a hand heading for the far side leaves almost
// level and curves down. There the surface stays while every HOVER_AIM_PATIENCE the pointer gets closer.
//
// The owner reports every pointer move with hover_reveal_move, schedules a wake for hover_reveal_deadline
// and passes it to hover_reveal_tick, and calls hover_reveal_close when its surface must go regardless.
Hover_Reveal :: struct {
	open:     bool,
	// Off both trigger and surface, heading for the surface, until `deadline`. `closest` is the distance at
	// the last step closer, where nothing else wants the hover.
	aiming:   bool,
	closest:  f32,
	deadline: time.Tick,
	// The pointer's last position while the surface showed, and whether its latest move along the axis
	// toward the surface went that way; a move across the axis keeps the previous answer, as in Radix.
	last:     [2]f32,
	seen:     bool,
	toward:   bool,
	// Where and when the pointer left the trigger; set from leaving until it returns.
	exit:     [2]f32,
	left:     time.Tick,
	exited:   bool,
}

// Kamens's delay for a pointer that has stopped short of its surface with nothing else wanting the hover.
HOVER_AIM_PATIENCE :: 300 * time.Millisecond
// Radix UI's pointer grace: how long after leaving the trigger the pointer may cross something else that
// wants the hover on its way to the surface.
HOVER_AIM_GRACE :: 300 * time.Millisecond
// How far, in DIPs, the safe area reaches past the trigger and the surface.
HOVER_AIM_SLACK :: f32(16)
// How far, in DIPs, the grace polygon's apex sits behind the point where the pointer left the trigger,
// Radix UI's bleed, so the pointer's next position is inside it.
HOVER_AIM_BLEED :: f32(5)

// Which side of its trigger a surface shows on.
@(private = "file")
Hover_Side :: enum {Right, Left, Below, Above}

// Follows one pointer move: `on_trigger` and `on_surface` say whether the pointer is over either, and
// `on_other` whether it is over something else that would take the hover, such as another row of the menu.
// `trigger` and `surface` are where they are, the surface where it is or would show. `slack` is
// HOVER_AIM_SLACK in the caller's pixels. True when `open` changed.
hover_reveal_move :: proc(
	r: ^Hover_Reveal,
	pointer: [2]f32,
	on_trigger, on_surface, on_other: bool,
	trigger, surface: render.Rect,
	slack: f32,
	now: time.Tick,
) -> bool {
	was := r.open
	side := hover_side(trigger, surface)
	if r.open && r.seen {
		along := hover_along(side, pointer - r.last)
		if along != 0 {r.toward = along > 0}
	}
	if r.open && r.seen && !on_trigger && !r.exited {
		bleed := HOVER_AIM_BLEED * slack / HOVER_AIM_SLACK
		r.exit, r.left, r.exited = r.last - hover_axis(side) * bleed, now, true
	}
	switch {
	case on_trigger:
		r.open, r.aiming, r.exited = true, false, false
	case !r.open:
	case on_surface:
		r.aiming = false
	case on_other:
		grace := time.tick_add(r.left, HOVER_AIM_GRACE)
		inside := hover_grace_contains(side, r.exit, surface, pointer)
		if !r.toward || !inside || time.tick_diff(grace, now) >= 0 {
			hover_reveal_close(r)
			break
		}
		r.aiming, r.closest, r.deadline = true, rect_distance(surface, pointer), grace
	case !hover_aim_safe(rect_grown(trigger, slack), rect_grown(surface, slack), pointer):
		hover_reveal_close(r)
	case:
		distance := rect_distance(surface, pointer)
		if !r.aiming || distance < r.closest {
			r.aiming, r.closest, r.deadline = true, distance, time.tick_add(now, HOVER_AIM_PATIENCE)
		} else if time.tick_diff(r.deadline, now) >= 0 {
			hover_reveal_close(r)
		}
	}
	if r.open {r.last, r.seen = pointer, true}
	return r.open != was
}

// The side of `trigger` that `surface` shows on: the one with the widest gap between them.
@(private = "file")
hover_side :: proc(trigger, surface: render.Rect) -> Hover_Side {
	gaps := [Hover_Side]f32 {
		.Right = surface.x - (trigger.x + trigger.width),
		.Left  = trigger.x - (surface.x + surface.width),
		.Below = surface.y - (trigger.y + trigger.height),
		.Above = trigger.y - (surface.y + surface.height),
	}
	best := Hover_Side.Right
	for gap, side in gaps {if gap > gaps[best] {best = side}}
	return best
}

// The unit step from the trigger toward a surface on `side`.
@(private = "file")
hover_axis :: proc(side: Hover_Side) -> [2]f32 {
	switch side {
	case .Right: return {1, 0}
	case .Left:  return {-1, 0}
	case .Below: return {0, 1}
	case .Above: return {0, -1}
	}
	return {}
}

// How far `delta` goes toward a surface on `side`; negative is away.
@(private = "file")
hover_along :: proc(side: Hover_Side, delta: [2]f32) -> f32 {
	axis := hover_axis(side)
	return delta.x * axis.x + delta.y * axis.y
}

// Whether `point` is in Radix UI's grace polygon: the surface and the triangle from `exit` to the
// surface's near edge.
@(private = "file")
hover_grace_contains :: proc(side: Hover_Side, exit: [2]f32, surface: render.Rect, point: [2]f32) -> bool {
	if render.rect_contains(surface, point.x, point.y) {return true}
	left, right := surface.x, surface.x + surface.width
	top, bottom := surface.y, surface.y + surface.height
	a, b: [2]f32
	switch side {
	case .Right: a, b = {left, top}, {left, bottom}
	case .Left:  a, b = {right, top}, {right, bottom}
	case .Below: a, b = {left, top}, {right, top}
	case .Above: a, b = {left, bottom}, {right, bottom}
	}
	return triangle_contains(exit, a, b, point)
}

// Hides the surface once an aim has lapsed. True when `open` changed.
hover_reveal_tick :: proc(r: ^Hover_Reveal, now: time.Tick) -> bool {
	if !r.aiming || time.tick_diff(r.deadline, now) < 0 {return false}
	hover_reveal_close(r)
	return true
}

// When the surface hides unless the pointer gets closer first.
hover_reveal_deadline :: proc(r: Hover_Reveal) -> (time.Tick, bool) {
	return r.deadline, r.open && r.aiming
}

hover_reveal_close :: proc(r: ^Hover_Reveal) {
	r^ = {}
}

// Whether `point` lies in the convex hull of `trigger` and `surface`: in some triangle of their corners.
// Eight corners make 56 triangles, cheap for one pointer move and needing no hull built first.
hover_aim_safe :: proc(trigger, surface: render.Rect, point: [2]f32) -> bool {
	if render.rect_contains(surface, point.x, point.y) || render.rect_contains(trigger, point.x, point.y) {
		return true
	}
	corners := [8][2]f32 {
		{trigger.x, trigger.y},
		{trigger.x + trigger.width, trigger.y},
		{trigger.x + trigger.width, trigger.y + trigger.height},
		{trigger.x, trigger.y + trigger.height},
		{surface.x, surface.y},
		{surface.x + surface.width, surface.y},
		{surface.x + surface.width, surface.y + surface.height},
		{surface.x, surface.y + surface.height},
	}
	for a in 0 ..< len(corners) {
		for b in a + 1 ..< len(corners) {
			for c in b + 1 ..< len(corners) {
				if triangle_contains(corners[a], corners[b], corners[c], point) {return true}
			}
		}
	}
	return false
}

// Whether `p` lies in the triangle abc, edges included; a triangle with no area holds nothing.
@(private = "file")
triangle_contains :: proc(a, b, c, p: [2]f32) -> bool {
	side :: proc(a, b, p: [2]f32) -> f32 {return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)}
	if side(a, b, c) == 0 {return false}
	d1, d2, d3 := side(a, b, p), side(b, c, p), side(c, a, p)
	negative := d1 < 0 || d2 < 0 || d3 < 0
	positive := d1 > 0 || d2 > 0 || d3 > 0
	return !(negative && positive)
}

// The squared distance from `point` to the nearest point of `r`, zero inside it; only ever compared.
@(private = "file")
rect_distance :: proc(r: render.Rect, point: [2]f32) -> f32 {
	dx := max(r.x - point.x, 0, point.x - (r.x + r.width))
	dy := max(r.y - point.y, 0, point.y - (r.y + r.height))
	return dx * dx + dy * dy
}

@(private = "file")
rect_grown :: proc(r: render.Rect, by: f32) -> render.Rect {
	return {r.x - by, r.y - by, r.width + 2 * by, r.height + 2 * by}
}
