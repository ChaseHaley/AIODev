package app_test

import "core:testing"
import app "../../src"
import "aio:layout"

@(test)
floating_capsules_fit_inside_the_available_row :: proc(t: ^testing.T) {
	widths := []f32{160, 160, 160, 160}
	start, gap := app.floating_capsule_row_fit(widths, 300, 8)
	testing.expect_value(t, start, f32(0))
	testing.expect_value(t, gap, f32(8))
	for width in widths {testing.expect_value(t, width, f32(69))}
	end := start + gap * f32(len(widths) - 1)
	for width in widths {end += width}
	testing.expect(t, end <= 300)

	roomy := []f32{80, 100}
	start, gap = app.floating_capsule_row_fit(roomy, 300, 8)
	testing.expect_value(t, start, f32(112))
	testing.expect_value(t, gap, f32(8))

	narrow := []f32{96, 96, 96, 96}
	start, gap = app.floating_capsule_row_fit(narrow, 3, 8)
	end = start + gap * f32(len(narrow) - 1)
	for width in narrow {
		testing.expect(t, width > 0)
		end += width
	}
	testing.expect(t, end <= 3)
}

@(test)
floating_drag_geometry_clamps_moves_edges_and_bounds :: proc(t: ^testing.T) {
	area := layout.Rect{10, 20, 800, 600}
	original := layout.Rect{210, 170, 400, 300}

	moved := app.floating_drag_rect(area, original, {-500, 700}, {}, 1)
	testing.expect_value(t, moved, layout.Rect{10, 320, 400, 300})

	left := app.floating_drag_rect(area, original, {500, 0}, {.Left}, 1)
	testing.expect_value(t, left, layout.Rect{370, 170, 240, 300})
	right := app.floating_drag_rect(area, original, {-500, 0}, {.Right}, 1)
	testing.expect_value(t, right, layout.Rect{210, 170, 240, 300})
	top := app.floating_drag_rect(area, original, {0, 500}, {.Top}, 1)
	testing.expect_value(t, top, layout.Rect{210, 350, 400, 120})
	bottom := app.floating_drag_rect(area, original, {0, -500}, {.Bottom}, 1)
	testing.expect_value(t, bottom, layout.Rect{210, 170, 400, 120})

	bounds := app.floating_bounds_for_rect(area, original)
	testing.expect_value(t, bounds, layout.Rect{0.25, 0.25, 0.5, 0.5})
}
