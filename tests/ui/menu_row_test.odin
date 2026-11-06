package ui_test

import "aio:ui"
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
	m.selected = 0
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
