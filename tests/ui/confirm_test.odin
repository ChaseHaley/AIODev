package ui_test

import "core:testing"
import "aio:platform"
import "aio:ui"

@(private="file")
press :: proc(key: platform.Key_Event) -> platform.Key_Event {
	e := key
	e.pressed = true
	return e
}

@(test)
confirm_keys_choose_cancel_or_accept :: proc(t: ^testing.T) {
	c: ui.Confirm
	ui.confirm_open(&c)
	testing.expect_value(t, c.focus, ui.Confirm_Button.Accept)
	testing.expect_value(t, ui.confirm_key(&c, press({key = .Enter})), ui.Confirm_Outcome.Accept)
	testing.expect_value(t, ui.confirm_key(&c, press({key = .Escape})), ui.Confirm_Outcome.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, {key = .Enter}), ui.Confirm_Outcome.None)
	testing.expect_value(t, ui.confirm_key(&c, press({key = .Tab})), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, c.focus, ui.Confirm_Button.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, press({key = .Space})), ui.Confirm_Outcome.Cancel)
	testing.expect_value(t, ui.confirm_key(&c, press({key = .Arrow_Right})), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, c.focus, ui.Confirm_Button.Accept)
	testing.expect_value(t, ui.confirm_key(&c, press({key = .A})), ui.Confirm_Outcome.None)
	ui.confirm_open(&c)
	testing.expect_value(t, c.focus, ui.Confirm_Button.Accept)
}

@(test)
confirm_pointer_needs_press_and_release_on_one_button :: proc(t: ^testing.T) {
	c: ui.Confirm
	ui.confirm_open(&c)
	l := ui.confirm_layout(1000, 700, 1)
	accept := [2]f32{l.accept.x+l.accept.width/2, l.accept.y+l.accept.height/2}
	cancel := [2]f32{l.cancel.x+l.cancel.width/2, l.cancel.y+l.cancel.height/2}
	inside := [2]f32{l.panel.x+10, l.panel.y+10}
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, true, accept.x, accept.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, false, cancel.x, cancel.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, true, cancel.x, cancel.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, c.focus, ui.Confirm_Button.Cancel)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, false, cancel.x, cancel.y), ui.Confirm_Outcome.Cancel)
	ui.confirm_mouse(&c, l, .Left, true, accept.x, accept.y)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, false, accept.x, accept.y), ui.Confirm_Outcome.Accept)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, true, inside.x, inside.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, false, inside.x, inside.y), ui.Confirm_Outcome.Changed)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Left, true, 2, 2), ui.Confirm_Outcome.Cancel)
	testing.expect_value(t, ui.confirm_mouse(&c, l, .Right, true, accept.x, accept.y), ui.Confirm_Outcome.None)
}

@(test)
confirm_layout_fits_narrow_windows :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 2}) {
		l := ui.confirm_layout(300, 400, scale)
		testing.expect(t, l.panel.x >= 0 && l.panel.x+l.panel.width <= 300)
		testing.expect(t, l.cancel.x+l.cancel.width <= l.accept.x)
		testing.expect(t, l.accept.y+l.accept.height <= l.panel.y+l.panel.height)
	}
}
