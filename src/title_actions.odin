package main

import "aio:render"
import "aio:ui"

Title_Action :: enum {None, Settings, Palette}

title_actions_end :: proc(w: ^Window) -> f32 {
	return (3 * ui.TITLE_BUTTON_WIDTH + 8) * w.scale
}

// The title-bar width the native caption buttons keep at the right, which the workspace chip and the
// tab bar both leave free.
window_caption_reserve :: proc(w: ^Window) -> f32 {
	return 218 * w.scale
}

title_action_rect :: proc(w: ^Window, action: Title_Action) -> render.Rect {
	if action == .None {return {}}
	r := tab_orientation_button_rect(w)
	r.x += f32(int(action)) * ui.TITLE_BUTTON_WIDTH * w.scale
	return r
}

title_action_hit :: proc(w: ^Window, x, y: f32) -> Title_Action {
	for action in Title_Action {
		if action != .None && render.rect_contains(title_action_rect(w, action), x, y) {return action}
	}
	return .None
}

title_actions_draw :: proc(app: ^App, w: ^Window) {
	if render.push_layer(&w.list, {0, 0, f32(w.width), ui.TITLE_BAR_HEIGHT * w.scale}) != .None {return}
	for action in Title_Action {
		if action == .None {continue}
		icon: ui.Icon = action == .Settings ? .Settings : .Command
		_ = ui.icon_button_draw(
			&w.list, app.theme, title_action_rect(w, action), icon,
			f32(int(w.title_action_hover == action)),
			f32(int(ui.armed_is(w.title_action_armed, action))), w.scale, w.pointer,
		)
	}
}

when AIO_CONTROL {
	title_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		state_rect(r, "title.settings", title_action_rect(w, .Settings))
		state_rect(r, "title.palette", title_action_rect(w, .Palette))
		state_valuef(r, "title.height", "%g", ui.TITLE_BAR_HEIGHT * w.scale)
		state_value(r, "title.controls_end", i32(window_title_controls_end(app, w)))
		state_valuef(r, "title.caption_start", "%g", f32(w.width) - ui.CAPTION_WIDTH * w.scale)
	}
}
