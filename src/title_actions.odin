package main

import "aio:render"
import "aio:ui"

Title_Action :: enum {None, Settings, Palette}

title_actions_end :: proc(w: ^Window) -> f32 {
	return (3 * ui.RAIL_TOGGLE_WIDTH + 8) * w.scale
}

title_action_rect :: proc(w: ^Window, action: Title_Action) -> render.Rect {
	if action == .None {return {}}
	r := tab_orientation_button_rect(w)
	r.x += f32(int(action)) * ui.RAIL_TOGGLE_WIDTH * w.scale
	return r
}

title_action_hit :: proc(w: ^Window, x, y: f32) -> Title_Action {
	for action in Title_Action {
		if action != .None && rect_contains(title_action_rect(w, action), x, y) {return action}
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
