package app_test

import app "../../src"
import "aio:input"
import "aio:render"
import "aio:ui"
import "core:testing"
import "core:time"

@(test)
tooltip_waits_for_its_hover_deadline :: proc(t: ^testing.T) {
	now := time.tick_now()
	w := app.Window{tooltip = app.Tooltip_Pending{"Split right", time.tick_add(now, 700 * time.Millisecond), {}}}
	app.tooltip_tick(&w, now)
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))

	app.tooltip_tick(&w, time.tick_add(now, 700 * time.Millisecond))
	label, shown := app.tooltip_shown(&w)
	testing.expect(t, shown && !tooltip_pending(&w))
	testing.expect_value(t, label, "Split right")
}

@(test)
tooltip_covers_scrollback_find_buttons :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1}
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	ui.find_open(&w.find)
	l := ui.find_layout(900, 1, 50)
	buttons := [?]struct{rect: render.Rect, label: string} {
		{l.case_toggle, "Match case"},
		{l.regex_toggle, "Use regular expression"},
		{l.older, "Previous match"},
		{l.newer, "Next match"},
		{l.close, "Close find"},
	}
	for button in buttons {
		x := i32(button.rect.x + button.rect.width / 2)
		y := i32(button.rect.y + button.rect.height / 2)
		_ = ui.find_hover(&w.find, l, true, f32(x), f32(y))
		app.tooltip_hover(&state, &w, .Find, input.Mouse_Move_Event{x = x, y = y})
		testing.expect_value(t, app.tooltip_current(&w), button.label)
		testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
	}
}

@(test)
tooltip_covers_palette_setting_reset :: proc(t: ^testing.T) {
	state: app.App
	state.palette.reset_hover = 0
	w: app.Window
	app.tooltip_hover(&state, &w, .Palette, input.Mouse_Move_Event{})
	testing.expect_value(t, app.tooltip_current(&w), "Reset setting")
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(test)
tooltip_neighbor_buttons_skip_second_delay :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 400, height = 300, scale = 1}
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 285, y = 20})
	testing.expect_value(t, app.tooltip_current(&w), "Minimize")
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
	app.tooltip_tick(&w, time.tick_add(time.tick_now(), time.Second))
	testing.expect(t, tooltip_visible(&w))

	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 330, y = 20})
	testing.expect_value(t, app.tooltip_current(&w), "Maximize")
	testing.expect(t, tooltip_visible(&w) && !tooltip_pending(&w))
	app.tooltip_hover(&state, &w, .Content, input.Mouse_Move_Event{x = 355, y = 20})
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 375, y = 20})
	testing.expect_value(t, app.tooltip_current(&w), "Close window")
	testing.expect(t, tooltip_visible(&w) && !tooltip_pending(&w))

	app.tooltip_hover(&state, &w, .Content, input.Mouse_Move_Event{x = 0, y = 20})
	app.tooltip_hover(&state, &w, .Tab_Orientation, input.Mouse_Move_Event{x = 100, y = 20})
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(test)
tooltip_workspace_color_wheel :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1}
	w.workspace_picker.state = app.Workspace_Picker_Icons{}
	r := app.workspace_icon_color_button(&w)
	app.tooltip_hover(&state, &w, .Workspace_Picker,
		input.Mouse_Move_Event{x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, app.tooltip_current(&w), "Change icon color")
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(test)
tooltip_skips_labeled_vertical_new_tab :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1, rail_wide = true, rail = app.Rail_Docked{}}
	l := ui.rail_layout({0, ui.TITLE_BAR_HEIGHT, ui.RAIL_WIDTH, 560}, 1, 0, 0)
	r := ui.rail_new_tab_tile(l)
	app.tooltip_hover(&state, &w, .Tabs,
		input.Mouse_Move_Event{x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, app.tooltip_current(&w), "")
	testing.expect(t, w.tooltip == nil)
}

@(test)
tooltip_neighbor_grace_expires :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 400, height = 300, scale = 1}
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 285, y = 20})
	app.tooltip_tick(&w, time.tick_add(time.tick_now(), time.Second))
	app.tooltip_hover(&state, &w, .Content, input.Mouse_Move_Event{x = 310, y = 20})
	warm, ok := &w.tooltip.(app.Tooltip_Warm)
	if !testing.expect(t, ok) {return}
	warm.until = time.tick_add(time.tick_now(), -time.Millisecond)
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 330, y = 20})
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(private = "file")
tooltip_visible :: proc(w: ^app.Window) -> bool {
	_, shown := app.tooltip_shown(w)
	return shown
}

@(private = "file")
tooltip_pending :: proc(w: ^app.Window) -> bool {
	_, pending := app.tooltip_deadline(w)
	return pending
}
