package ui_test

import "core:testing"
import "aio:render"
import "aio:ui"

@(test)
panel_draw_stacks_shadow_border_and_surface :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	if render.push_layer(&list, {0, 0, 100, 100}) != .None {
		testing.fail_now(t, "layer push failed")
	}
	frame := ui.Panel {
		rect     = {10, 10, 50, 20},
		radius   = 4,
		scale    = 1,
		shadow_y = 6,
		softness = 16,
		border   = .Expanded,
	}
	testing.expect_value(t, ui.panel_draw(&list, frame, {}), render.Error.None)
	testing.expect_value(t, len(list.rects), 3)
	testing.expect_value(t, list.rects[0].rect.y, 16)
	testing.expect_value(t, list.rects[0].softness, 16)
	testing.expect_value(t, list.rects[1].rect.x, 9)
	testing.expect_value(t, list.rects[1].radius, 5)
	testing.expect_value(t, list.rects[2].rect, render.Rect{10, 10, 50, 20})
}

@(test)
panel_border_styles_draw_what_they_name :: proc(t: ^testing.T) {
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	if render.push_layer(&list, {0, 0, 100, 100}) != .None {
		testing.fail_now(t, "layer push failed")
	}
	frame := ui.Panel{rect = {10, 10, 50, 20}, radius = 4, scale = 2, border = .Stroked}
	testing.expect_value(t, ui.panel_draw(&list, frame, {}), render.Error.None)
	testing.expect_value(t, len(list.rects), 3)
	testing.expect_value(t, list.rects[2].stroke, 2)
	frame.border = .None
	clear(&list.rects)
	testing.expect_value(t, ui.panel_draw(&list, frame, {}), render.Error.None)
	testing.expect_value(t, len(list.rects), 2)
}
