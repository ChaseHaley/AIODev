package ui_test

import "core:math"
import "core:testing"
import "aio:render"
import "aio:ui"

@(private = "file")
whole :: proc(v: f32) -> bool {return abs(v - math.round(v)) < 1e-3}

@(private = "file")
arc_center :: proc(r: render.Rect_Instance) -> [2]f32 {
	return {r.rect.x + r.rect.width / 2, r.rect.y + r.rect.height / 2}
}

// The eye is two arcs about a round pupil on a whole pixel, so it stays symmetric and its pupil and
// the lids' outer edges stay on whole pixels at fractional scales too.
@(test)
eye_icon_is_symmetric_and_lands_on_whole_pixels_at_every_scale :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	for scale in ([?]f32{1, 1.25, 1.5, 1.75, 2}) {
		render.draw_list_reset(&list)
		testing.expect_value(t, render.push_layer(&list, {0, 0, 64, 64}), render.Error.None)
		ui.icon_draw(&list, .Eye, {3, 5, 41, 37}, {1, 1, 1, 1}, ui.ICON_BUTTON, scale)
		arcs: [dynamic]render.Rect_Instance
		defer delete(arcs)
		pupils: [dynamic]render.Rect_Instance
		defer delete(pupils)
		for r in list.rects {
			if r.fill == render.RECT_FILL_ARC {append(&arcs, r)} else {append(&pupils, r)}
		}
		if !testing.expect_value(t, len(arcs), 2) || !testing.expect_value(t, len(pupils), 1) {continue}
		pupil := pupils[0]
		testing.expect(t, pupil.rect.width == pupil.rect.height && pupil.radius == pupil.rect.width / 2,
			"the pupil is a filled circle")
		testing.expect(t, whole(pupil.rect.x) && whole(pupil.rect.y) && whole(pupil.rect.width),
			"the pupil lies on whole pixels")
		centre := [2]f32{pupil.rect.x + pupil.rect.width / 2, pupil.rect.y + pupil.rect.height / 2}
		upper, lower := arcs[0], arcs[1]
		if arc_center(upper).y < arc_center(lower).y {upper, lower = lower, upper}
		testing.expect(t, upper.radius == lower.radius && upper.stroke == lower.stroke)
		up, down := arc_center(upper), arc_center(lower)
		testing.expect(t, abs(up.x - centre.x) < 1e-3 && abs(down.x - centre.x) < 1e-3,
			"the lids are centred over the pupil")
		testing.expect(t, abs((up.y - centre.y) - (centre.y - down.y)) < 1e-3,
			"the lids mirror each other about the pupil")
		testing.expect(t, whole(up.y - upper.radius - upper.stroke / 2), "the upper lid's top is on a pixel")
		testing.expect(t, whole(down.y + lower.radius + lower.stroke / 2),
			"the lower lid's bottom is on a pixel")
	}
}

@(test)
crossed_eye_breaks_its_lids_for_the_slash :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	for scale in ([?]f32{1, 1.5, 2}) {
		render.draw_list_reset(&list)
		testing.expect_value(t, render.push_layer(&list, {0, 0, 64, 64}), render.Error.None)
		ui.icon_draw(&list, .Eye_Off, {0, 0, 40, 40}, {1, 1, 1, 1}, ui.ICON_BUTTON, scale)
		arcs, segments := 0, 0
		for r in list.rects {
			switch r.fill {
			case render.RECT_FILL_ARC:
				arcs += 1
				testing.expect(t, r.sheen[3] > 0, "every piece of a lid has some length")
			case render.RECT_FILL_SEGMENT:
				segments += 1
			case:
				testing.fail_now(t, "a crossed eye has no pupil")
			}
		}
		testing.expect_value(t, arcs, 4)
		testing.expect_value(t, segments, 1)
	}
}
