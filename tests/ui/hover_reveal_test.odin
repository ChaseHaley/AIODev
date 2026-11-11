package ui_test

import "aio:render"
import "aio:ui"
import "core:testing"
import "core:time"

// A trigger at the top left and its surface below and to the right, with a gap between them.
@(private = "file")
TRIGGER :: render.Rect{0, 0, 20, 20}
@(private = "file")
SURFACE :: render.Rect{0, 40, 200, 100}

@(private = "file")
at :: proc(start: time.Tick, ms: int) -> time.Tick {
	return time.tick_add(start, time.Duration(ms) * time.Millisecond)
}

@(private = "file")
move :: proc(r: ^ui.Hover_Reveal, p: [2]f32, now: time.Tick) {
	on_trigger := render.rect_contains(TRIGGER, p.x, p.y)
	on_surface := r.open && render.rect_contains(SURFACE, p.x, p.y)
	_ = ui.hover_reveal_move(r, p, on_trigger, on_surface, false, TRIGGER, SURFACE, 0, now)
}

// Leaving the trigger toward the surface keeps it, across the gap and diagonally over whatever lies between;
// reaching the surface ends the aim.
@(test)
hover_reveal_keeps_the_surface_while_the_pointer_heads_for_it :: proc(t: ^testing.T) {
	start := time.tick_now()
	r: ui.Hover_Reveal
	move(&r, {10, 10}, start)
	testing.expect(t, r.open, "the trigger shows the surface")
	move(&r, {40, 25}, at(start, 50))
	testing.expect(t, r.open && r.aiming, "heading for the far corner keeps it")
	move(&r, {70, 34}, at(start, 100))
	testing.expect(t, r.open, "still closer, still kept")
	move(&r, {100, 60}, at(start, 150))
	testing.expect(t, r.open && !r.aiming, "on the surface the aim ends")
	_, waiting := ui.hover_reveal_deadline(r)
	testing.expect(t, !waiting, "nothing to time while on the surface")
}

// The hidden panes map's shape: a small glyph with a wide map just below it. A hand heading for a far card
// leaves the glyph almost level, even a pixel upward, wobbles above the line from glyph to map and curves
// down; the trigger's whole box and the slack keep the map.
@(test)
hover_reveal_keeps_a_wide_surface_for_a_level_start :: proc(t: ^testing.T) {
	glyph := render.Rect{41, 46, 28, 24}
	surface := render.Rect{37, 74, 340, 196}
	start := time.tick_now()
	r: ui.Hover_Reveal
	path := [?][2]f32{{55, 58}, {75, 57}, {120, 62}, {200, 50}, {260, 76}, {300, 120}}
	for p, i in path {
		on_trigger := render.rect_contains(glyph, p.x, p.y)
		on_surface := render.rect_contains(surface, p.x, p.y)
		slack := ui.HOVER_AIM_SLACK
		_ = ui.hover_reveal_move(&r, p, on_trigger, on_surface, false, glyph, surface, slack, at(start, 16 * i))
		testing.expectf(t, r.open, "kept at %v", p)
	}
	testing.expect(t, !ui.hover_aim_safe(glyph, surface, {200, 50}), "the wobble is outside the bare hull")
}

// A move outside the safe area, here back past the trigger's side, hides the surface at once.
@(test)
hover_reveal_hides_the_surface_when_the_pointer_turns_away :: proc(t: ^testing.T) {
	start := time.tick_now()
	r: ui.Hover_Reveal
	move(&r, {10, 10}, start)
	move(&r, {60, 5}, at(start, 20))
	testing.expect(t, !r.open, "heading right, away from the surface below, hides it")
	move(&r, {100, 60}, at(start, 40))
	testing.expect(t, !r.open, "reaching the surface afterwards does not bring it back")
}

// Stopping short of the surface inside the safe area hides it after the patience, whether the next event is
// a move that gets no closer or the timer; every step closer restarts the patience.
@(test)
hover_reveal_hides_the_surface_when_the_pointer_stops_short :: proc(t: ^testing.T) {
	start := time.tick_now()
	patience := int(time.duration_milliseconds(ui.HOVER_AIM_PATIENCE))
	r: ui.Hover_Reveal
	move(&r, {10, 10}, start)
	move(&r, {12, 24}, at(start, 10))
	deadline, waiting := ui.hover_reveal_deadline(r)
	testing.expect(t, waiting && deadline == at(start, 10 + patience))
	move(&r, {12, 30}, at(start, 10 + patience - 1))
	testing.expect(t, r.open, "a step closer just in time")
	testing.expect(t, !ui.hover_reveal_tick(&r, at(start, 10 + patience)), "and the patience restarted")
	move(&r, {13, 30}, at(start, 20 + 2 * patience))
	testing.expect(t, !r.open, "a move that gets no closer after the patience hides it")

	move(&r, {10, 10}, start)
	move(&r, {12, 24}, at(start, 10))
	testing.expect(t, !ui.hover_reveal_tick(&r, at(start, 10 + patience - 1)))
	testing.expect(t, ui.hover_reveal_tick(&r, at(start, 10 + patience)), "the timer hides it")
	testing.expect(t, !r.open)
}

// A submenu beside its row, with the menu's next rows below the row. Over one of them the submenu stays only
// while the pointer heads for it, measured over the last few moves so one jittery step does not count.
@(test)
hover_reveal_gives_way_to_a_competitor_unless_heading_for_the_surface :: proc(t: ^testing.T) {
	row := render.Rect{0, 0, 200, 30}
	submenu := render.Rect{200, 0, 160, 150}
	start := time.tick_now()
	step :: proc(r: ^ui.Hover_Reveal, row, submenu: render.Rect, p: [2]f32, now: time.Tick) {
		on_row, on_submenu := render.rect_contains(row, p.x, p.y), render.rect_contains(submenu, p.x, p.y)
		_ = ui.hover_reveal_move(r, p, on_row, on_submenu, !on_row && !on_submenu, row, submenu, 16, now)
	}
	r: ui.Hover_Reveal
	step(&r, row, submenu, {40, 15}, start)
	step(&r, row, submenu, {40, 45}, at(start, 16))
	testing.expect(t, !r.open, "straight down to the next row hides it at once")

	r = {}
	step(&r, row, submenu, {120, 15}, start)
	step(&r, row, submenu, {140, 35}, at(start, 16))
	step(&r, row, submenu, {140, 36}, at(start, 32))
	testing.expect(t, r.open, "a jittery step while crossing diagonally keeps it")
	step(&r, row, submenu, {165, 50}, at(start, 48))
	testing.expect(t, r.open && r.aiming, "still heading for it")
	step(&r, row, submenu, {165, 70}, at(start, 64))
	step(&r, row, submenu, {165, 90}, at(start, 80))
	step(&r, row, submenu, {165, 110}, at(start, 96))
	testing.expect(t, !r.open, "turning down the menu hides it")
}

// Over a competitor the aim must keep moving: a pause gives the competitor the hover after
// HOVER_AIM_CONTESTED, and a hand drifting slowly toward the submenu while settling on the next row does not
// count as heading for it.
@(test)
hover_reveal_gives_way_quickly_to_a_competitor_when_the_pointer_settles :: proc(t: ^testing.T) {
	row := render.Rect{0, 0, 200, 30}
	submenu := render.Rect{200, 0, 160, 150}
	contested := int(time.duration_milliseconds(ui.HOVER_AIM_CONTESTED))
	start := time.tick_now()
	step :: proc(r: ^ui.Hover_Reveal, row, submenu: render.Rect, p: [2]f32, now: time.Tick) {
		on_row, on_submenu := render.rect_contains(row, p.x, p.y), render.rect_contains(submenu, p.x, p.y)
		_ = ui.hover_reveal_move(r, p, on_row, on_submenu, !on_row && !on_submenu, row, submenu, 16, now)
	}
	r: ui.Hover_Reveal
	step(&r, row, submenu, {120, 15}, start)
	step(&r, row, submenu, {140, 35}, at(start, 16))
	testing.expect(t, r.open, "heading for it")
	testing.expect(t, !ui.hover_reveal_tick(&r, at(start, 16 + contested - 1)))
	testing.expect(t, ui.hover_reveal_tick(&r, at(start, 16 + contested)), "a pause on the row gives it the hover")

	r = {}
	step(&r, row, submenu, {120, 15}, start)
	step(&r, row, submenu, {121, 32}, at(start, 40))
	step(&r, row, submenu, {122, 34}, at(start, 80))
	step(&r, row, submenu, {123, 35}, at(start, 120))
	testing.expect(t, r.open, "still coming down off the row")
	step(&r, row, submenu, {124, 36}, at(start, 160))
	testing.expect(t, !r.open, "a slow drift closer is settling, not aiming")
}

// The safe area is the hull of the trigger and the surface: it reaches past the trigger's whole box, not
// just from one point of it, and no further.
@(test)
hover_aim_safe_area_is_the_hull_of_trigger_and_surface :: proc(t: ^testing.T) {
	trigger := render.Rect{280, 0, 40, 20}
	surface := render.Rect{0, 100, 100, 100}
	testing.expect(t, ui.hover_aim_safe(trigger, surface, {150, 100}), "between them")
	testing.expect(t, ui.hover_aim_safe(trigger, surface, {300, 30}), "just under the trigger's far side")
	testing.expect(t, ui.hover_aim_safe(trigger, surface, {50, 150}), "on the surface")
	testing.expect(t, !ui.hover_aim_safe(trigger, surface, {150, 10}), "above the hull")
	testing.expect(t, !ui.hover_aim_safe(trigger, surface, {250, 150}), "below the hull")
	testing.expect(t, !ui.hover_aim_safe({300, 0, 0, 0}, surface, {150, 10}), "a point trigger is no wider")
}
