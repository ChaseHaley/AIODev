package ui_test

import "core:testing"
import "aio:render"
import "aio:settings"
import "aio:ui"

@(test)
hover_lift_follows_the_theme_and_stops_at_rest :: proc(t: ^testing.T) {
	theme := ui.theme_from(settings.theme_resolve({.Studio, .Dark}))
	testing.expect_value(t, theme.hover_lift, f32(1.5))
	testing.expect_value(t, theme.hover_gloss, f32(1))
	testing.expect_value(t, ui.hover_lift_at(theme, 0, 1), f32(0))
	testing.expect_value(t, ui.hover_lift_at(theme, 1, 1), f32(1.5))
	testing.expect_value(t, ui.hover_lift_at(theme, 0.5, 2), f32(1.5))
	theme.hover_lift = 0
	testing.expect_value(t, ui.hover_lift_at(theme, 1, 1), f32(0))
}

@(test)
hover_rim_draws_a_pointer_centred_line_and_honours_gloss :: proc(t: ^testing.T) {
	theme := ui.theme_from(settings.theme_resolve({.Studio, .Dark}))
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	if !testing.expect_value(t, render.push_layer(&list, {0, 0, 200, 100}), render.Error.None) {
		return
	}
	rect := render.Rect{10, 20, 100, 30}
	if !testing.expect_value(
		t,
		ui.hover_rim_draw(&list, theme, rect, 6, 1, 1, {60, 35}),
		render.Error.None,
	) {
		return
	}
	if !testing.expect_value(t, len(list.rects), 1) {return}
	rim := list.rects[0]
	testing.expect_value(t, rim.fill, render.RECT_FILL_RIM)
	testing.expect_value(t, rim.rect, rect)
	testing.expect_value(t, rim.sheen[0], f32(50))
	testing.expect_value(t, rim.sheen[1], f32(15))
	testing.expect_value(t, rim.sheen[2], f32(90))
	testing.expect_value(t, rim.sheen[3], f32(1.25))

	theme.hover_gloss = 0
	if !testing.expect_value(
		t,
		ui.hover_rim_draw(&list, theme, rect, 6, 1, 1, {60, 35}),
		render.Error.None,
	) {
		return
	}
	testing.expect_value(t, len(list.rects), 1)
}

@(test)
hover_rim_present_reports_whether_the_frame_carries_a_pointer_light :: proc(t: ^testing.T) {
	theme := ui.theme_from(settings.theme_resolve({.Studio, .Dark}))
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	if !testing.expect_value(t, render.push_layer(&list, {0, 0, 200, 100}), render.Error.None) {
		return
	}
	testing.expect(t, !ui.hover_rim_present(&list))
	if !testing.expect_value(
		t,
		ui.hover_rim_draw(&list, theme, {10, 20, 100, 30}, 6, 1, 1, {60, 35}),
		render.Error.None,
	) {
		return
	}
	testing.expect(t, ui.hover_rim_present(&list))
}

@(test)
hover_shadow_sits_under_the_lifted_rect :: proc(t: ^testing.T) {
	theme := ui.theme_from(settings.theme_resolve({.Studio, .Dark}))
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	if !testing.expect_value(t, render.push_layer(&list, {0, 0, 200, 100}), render.Error.None) {
		return
	}
	if !testing.expect_value(
		t,
		ui.hover_shadow_draw(&list, theme, {10, 20, 100, 30}, 6, 1, 1),
		render.Error.None,
	) {
		return
	}
	if !testing.expect_value(t, len(list.rects), 1) {return}
	testing.expect_value(t, list.rects[0].rect, render.Rect{10, 22, 100, 30})
	testing.expect_value(t, list.rects[0].softness, f32(7))
	testing.expect_value(t, list.rects[0].color.a, theme.shadow.a)
}
