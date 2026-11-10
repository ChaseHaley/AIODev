package ui

import "aio:render"
import "core:time"

// A surface that a hover on its trigger shows, such as a map under a header glyph or a submenu beside its
// row. It shows while the pointer is on the trigger or the surface, and also while the pointer has left
// the trigger and is still heading for the surface: "menu aim", as Amazon's mega dropdown and Ben Kamens's
// jQuery-menu-aim do it, also called a safe triangle (Floating UI's safePolygon). The safe area is the
// triangle fan from the last point on the trigger to the surface's corners. Inside it the surface stays
// while every HOVER_AIM_PATIENCE the pointer gets closer to the surface; leaving the safe area, or pausing
// in it, hides it.
//
// The owner reports every pointer move with hover_reveal_move, schedules a wake for hover_reveal_deadline
// and passes it to hover_reveal_tick, and calls hover_reveal_close when its surface must go regardless.
Hover_Reveal :: struct {
	open:     bool,
	// The last point on the trigger, where the safe area starts.
	apex:     [2]f32,
	// Off both trigger and surface, heading for the surface: its distance at the last step closer, and when
	// the aim lapses without another.
	aiming:   bool,
	closest:  f32,
	deadline: time.Tick,
}

// Kamens's delay for a pointer that has stopped short of its submenu.
HOVER_AIM_PATIENCE :: 300 * time.Millisecond

// Follows one pointer move: `on_trigger` and `on_surface` say whether the pointer is over either, and
// `surface` is where the surface is or would show. True when `open` changed.
hover_reveal_move :: proc(
	r: ^Hover_Reveal,
	pointer: [2]f32,
	on_trigger, on_surface: bool,
	surface: render.Rect,
	now: time.Tick,
) -> bool {
	was := r.open
	switch {
	case on_trigger:
		r.open, r.apex, r.aiming = true, pointer, false
	case !r.open:
	case on_surface:
		r.aiming = false
	case !hover_aim_safe(r.apex, surface, pointer):
		hover_reveal_close(r)
	case:
		distance := rect_distance(surface, pointer)
		if !r.aiming || distance < r.closest {
			r.aiming, r.closest, r.deadline = true, distance, time.tick_add(now, HOVER_AIM_PATIENCE)
		} else if time.tick_diff(r.deadline, now) >= 0 {
			hover_reveal_close(r)
		}
	}
	return r.open != was
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

// Whether `point` lies in the surface or in the fan of triangles from `apex` to its edges, which together
// are the convex hull of the apex and the surface.
hover_aim_safe :: proc(apex: [2]f32, surface: render.Rect, point: [2]f32) -> bool {
	if render.rect_contains(surface, point.x, point.y) {return true}
	corners := [4][2]f32 {
		{surface.x, surface.y},
		{surface.x + surface.width, surface.y},
		{surface.x + surface.width, surface.y + surface.height},
		{surface.x, surface.y + surface.height},
	}
	for corner, i in corners {
		if triangle_contains(apex, corner, corners[(i + 1) % 4], point) {return true}
	}
	return false
}

@(private = "file")
triangle_contains :: proc(a, b, c, p: [2]f32) -> bool {
	side :: proc(a, b, p: [2]f32) -> f32 {return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)}
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
