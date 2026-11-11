package ui

import "aio:render"
import "core:time"

// A surface that a hover on its trigger shows, such as a map under a header glyph or a submenu beside its
// row. It shows while the pointer is on the trigger or the surface, and also while the pointer has left
// the trigger and is still heading for the surface: "menu aim", as Amazon's mega dropdown and Ben Kamens's
// jQuery-menu-aim do it, also called a safe triangle (Floating UI's safePolygon). The safe area is the
// convex hull of the trigger and the surface, each grown by a slack for a wavering hand. A triangle from the
// point where the pointer left proved too thin when a small trigger sits just above a wide surface: a hand
// heading for the far side leaves almost level and curves down. Inside the safe area the surface stays while
// every HOVER_AIM_PATIENCE the pointer gets closer to the surface; leaving the safe area, or pausing in it,
// hides it.
//
// The safe area spans whatever lies between, such as the rows of the menu a submenu hangs from. Over one of
// those, something else wants the hover, so the aim must look deliberate, as in jQuery-menu-aim and Floating
// UI's safePolygon: the pointer is closer to the surface than HOVER_AIM_TRAIL moves ago, at no less than
// HOVER_AIM_MIN_SPEED, and moves again within HOVER_AIM_CONTESTED. A move straight down to the next row, a
// slow drift while settling on it, or a pause there gives that row the hover.
//
// The owner reports every pointer move with hover_reveal_move, schedules a wake for hover_reveal_deadline
// and passes it to hover_reveal_tick, and calls hover_reveal_close when its surface must go regardless.
Hover_Reveal :: struct {
	open:     bool,
	// Off both trigger and surface, heading for the surface: its distance at the last step closer, and when
	// the aim lapses without another.
	aiming:   bool,
	closest:  f32,
	deadline: time.Tick,
	// The latest pointer positions and when they came, oldest first, which tell where and how fast it is
	// heading over a competitor.
	trail:    [HOVER_AIM_TRAIL][2]f32,
	times:    [HOVER_AIM_TRAIL]time.Tick,
	trailed:  int,
}

// How many recent positions a heading is measured over, as in jQuery-menu-aim, so one jittery step of a
// diagonal move does not read as a turn.
HOVER_AIM_TRAIL :: 3

// Kamens's delay for a pointer that has stopped short of its surface with nothing else wanting the hover.
HOVER_AIM_PATIENCE :: 300 * time.Millisecond
// How long an aim over a competitor lasts without another move: Floating UI's 40 ms, plus room for a
// pointer that reports every 16 ms frame.
HOVER_AIM_CONTESTED :: 50 * time.Millisecond
// Floating UI's resting speed, in DIPs per millisecond: slower than this over a competitor is settling there.
HOVER_AIM_MIN_SPEED :: f32(0.1)
// How far, in DIPs, the safe area reaches past the trigger and the surface.
HOVER_AIM_SLACK :: f32(16)

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
	switch {
	case on_trigger:
		r.open, r.aiming = true, false
	case !r.open:
	case on_surface:
		r.aiming = false
	case !hover_aim_safe(rect_grown(trigger, slack), rect_grown(surface, slack), pointer):
		hover_reveal_close(r)
	case on_other:
		if !hover_aim_heading(r, pointer, surface, slack / HOVER_AIM_SLACK, now) {
			hover_reveal_close(r)
			break
		}
		distance := rect_distance(surface, pointer)
		if !r.aiming || distance < r.closest {r.closest = distance}
		r.aiming, r.deadline = true, time.tick_add(now, HOVER_AIM_CONTESTED)
	case:
		distance := rect_distance(surface, pointer)
		if !r.aiming || distance < r.closest {
			r.aiming, r.closest, r.deadline = true, distance, time.tick_add(now, HOVER_AIM_PATIENCE)
		} else if time.tick_diff(r.deadline, now) >= 0 {
			hover_reveal_close(r)
		}
	}
	if r.open {hover_trail_push(r, pointer, now)}
	return r.open != was
}

// Whether the pointer is heading for `surface` since the oldest trail position: closer to it, and moving at
// least HOVER_AIM_MIN_SPEED DIPs per millisecond at `scale` pixels per DIP.
@(private = "file")
hover_aim_heading :: proc(
	r: ^Hover_Reveal,
	pointer: [2]f32,
	surface: render.Rect,
	scale: f32,
	now: time.Tick,
) -> bool {
	if r.trailed == 0 {return false}
	from := r.trail[0]
	if rect_distance(surface, pointer) >= rect_distance(surface, from) {return false}
	elapsed := f32(time.duration_milliseconds(time.tick_diff(r.times[0], now)))
	if elapsed <= 0 {return true}
	delta := pointer - from
	least := HOVER_AIM_MIN_SPEED * scale * elapsed
	return delta.x * delta.x + delta.y * delta.y >= least * least
}

@(private = "file")
hover_trail_push :: proc(r: ^Hover_Reveal, pointer: [2]f32, now: time.Tick) {
	if r.trailed == HOVER_AIM_TRAIL {
		copy(r.trail[:], r.trail[1:])
		copy(r.times[:], r.times[1:])
		r.trailed -= 1
	}
	r.trail[r.trailed], r.times[r.trailed] = pointer, now
	r.trailed += 1
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
