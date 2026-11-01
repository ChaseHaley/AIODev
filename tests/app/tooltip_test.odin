package app_test

import app "../../src"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:testing"
import "core:time"

@(test)
tooltip_waits_for_its_hover_deadline :: proc(t: ^testing.T) {
	w := app.Window{tooltip = "Split right"}
	w.tooltip_deadline = time.tick_add(time.tick_now(), 700 * time.Millisecond)
	app.tooltip_tick(&w)
	testing.expect(t, !w.tooltip_visible)
	testing.expect(t, w.tooltip_deadline != {})

	w.tooltip_deadline = time.tick_add(time.tick_now(), -time.Millisecond)
	app.tooltip_tick(&w)
	testing.expect(t, w.tooltip_visible)
	testing.expect(t, w.tooltip_deadline == {})
}

@(test)
tooltip_covers_scrollback_find_buttons :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1}
	w.find.open = true
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
		app.tooltip_hover(&state, &w, .Find, platform.Mouse_Move_Event{x = x, y = y})
		testing.expect_value(t, w.tooltip, button.label)
		testing.expect(t, !w.tooltip_visible && w.tooltip_deadline != {})
	}
}

@(test)
tooltip_covers_palette_setting_reset :: proc(t: ^testing.T) {
	state: app.App
	state.palette.reset_hover = 0
	w: app.Window
	app.tooltip_hover(&state, &w, .Palette, platform.Mouse_Move_Event{})
	testing.expect_value(t, w.tooltip, "Reset setting")
	testing.expect(t, !w.tooltip_visible && w.tooltip_deadline != {})
}
