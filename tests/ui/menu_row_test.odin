package ui_test

import "aio:ui"
import "aio:render"
import "aio:glyphs"
import "aio:font"
import "core:testing"

@(test)
menu_row_buttons_sit_inside_their_row_and_hide_with_selection :: proc(t: ^testing.T) {
	m: ui.Menu
	ui.menu_init(&m)
	defer ui.menu_destroy(&m)
	ui.menu_anchor(&m, 40, 40)
	_ = ui.menu_add(&m, {label = "first", enabled = true, action = ui.Icon.Workspace, selected_action = ui.Icon.Close})
	_ = ui.menu_add(&m, {label = "second", enabled = true, action = ui.Icon.Workspace, selected_action = ui.Icon.Close})
	_ = ui.menu_add(&m, {label = "plain", enabled = true})
	width, height, scale := f32(800), f32(600), f32(1.5)
	ui.menu_select(&m, 0)
	center :: proc(r: [4]f32) -> (f32, f32) {return r[0] + r[2] / 2, r[1] + r[3] / 2}
	for index in 0 ..< 2 {
		row := ui.menu_row_rect(&m, index, width, height, scale)
		action := ui.menu_action_rect(&m, index, .Action, width, height, scale)
		remove := ui.menu_action_rect(&m, index, .Selected_Action, width, height, scale)
		testing.expect(t, action.x + action.width <= remove.x + 0.01)
		testing.expect(t, remove.x + remove.width <= row.x + row.width)
		testing.expect(t, action.y >= row.y && action.y + action.height <= row.y + row.height)
	}
	x, y := center(transmute([4]f32)ui.menu_action_rect(&m, 0, .Selected_Action, width, height, scale))
	testing.expect_value(t, ui.menu_row_part(&m, 0, x, y, width, height, scale), ui.Menu_Row_Part.Selected_Action)
	x, y = center(transmute([4]f32)ui.menu_action_rect(&m, 1, .Selected_Action, width, height, scale))
	testing.expect_value(t, ui.menu_row_part(&m, 1, x, y, width, height, scale), ui.Menu_Row_Part.Row)
	x, y = center(transmute([4]f32)ui.menu_action_rect(&m, 1, .Action, width, height, scale))
	testing.expect_value(t, ui.menu_row_part(&m, 1, x, y, width, height, scale), ui.Menu_Row_Part.Action)
	x, y = center(transmute([4]f32)ui.menu_action_rect(&m, 2, .Action, width, height, scale))
	testing.expect_value(t, ui.menu_row_part(&m, 2, x, y, width, height, scale), ui.Menu_Row_Part.Row)
	row := ui.menu_row_rect(&m, 0, width, height, scale)
	testing.expect_value(t, ui.menu_row_part(&m, 0, row.x + 2, row.y + 2, width, height, scale), ui.Menu_Row_Part.Row)
}

@(test)
menu_drawing_preserves_selection_and_scroll_and_hit_testing_matches :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	device, device_error := render.device_create()
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, fonts, device)
	defer glyphs.destroy(&cache)
	m: ui.Menu
	ui.menu_init(&m)
	defer ui.menu_destroy(&m)
	for _ in 0..<30 {_ = ui.menu_add(&m, {separator = true})}
	ui.menu_select(&m, 25)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, &cache, 14)) {return}
	testing.expect_value(t, ui.menu_draw(&m, &list, &text, {}, 400, 100, 1), glyphs.Result.Ok)
	testing.expect_value(t, ui.menu_selected(&m), 25)
	testing.expect_value(t, m.scroll, 0)
	selected := ui.menu_row_rect(&m, 25, 400, 100, 1)
	testing.expect_value(t, ui.menu_hit(&m, selected.x + 1, selected.y + 1, 400, 100, 1), 25)
	ui.menu_reveal(&m, 400, 100, 1)
	testing.expect(t, m.scroll > 0 && m.scroll <= ui.menu_selected(&m))
	// No row is a real selection state, not a sentinel a draw must repair.
	ui.menu_select(&m, -1)
	testing.expect_value(t, ui.menu_draw(&m, &list, &text, {}, 400, 100, 1), glyphs.Result.Ok)
	testing.expect(t, m.selection == nil)
}

@(test)
menu_edge_navigation_without_enabled_rows_preserves_selection :: proc(t: ^testing.T) {
	m: ui.Menu
	ui.menu_init(&m)
	defer ui.menu_destroy(&m)
	_ = ui.menu_add(&m, {label = "disabled"})
	_ = ui.menu_add(&m, {separator = true})
	testing.expect_value(t, ui.menu_key(&m, {key = .End, pressed = true}), ui.Menu_Outcome.Changed)
	testing.expect_value(t, ui.menu_selected(&m), 0)
	testing.expect_value(t, ui.menu_key(&m, {key = .Home, pressed = true}), ui.Menu_Outcome.Changed)
	testing.expect_value(t, ui.menu_selected(&m), 0)
	testing.expect_value(t, ui.menu_key(&m, {key = .Escape, pressed = true}), ui.Menu_Outcome.Closed)
	testing.expect_value(t, ui.menu_selected(&m), 0)
}
