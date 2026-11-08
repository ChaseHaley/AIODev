package main

import "aio:platform"
import "aio:render"
import "core:log"

// Changes the window's pointer shape; an unchanged shape costs nothing and makes no native call.
@(private)
pointer_set :: proc(app: ^App, w: ^Window, shape: platform.Cursor_Shape) {
	if shape == w.pointer_shape {return}
	when AIO_CONTROL {app.verify.pointer_updates += 1}
	// A window without a native window yet, or any longer, has no pointer to change.
	#partial switch platform.window_set_cursor(&app.platform, w.id, shape) {
	case .None: w.pointer_shape = shape
	case .Invalid_Window:
	case: log.error("setting the pointer cursor failed")
	}
}

// The pointer over the title bar and the tabs, wherever they are docked. A hand marks a control
// whose click changes something; the selected tab is already shown, so only its close button
// takes a hand. Caption buttons keep the arrow, as native windows do.
chrome_pointer :: proc(app: ^App, w: ^Window, x, y: f32) -> platform.Cursor_Shape {
	if title_action_hit(w, x, y) != .None {return .Hand}
	if tab_orientation_button_hit(w, x, y) {return .Hand}
	if y >= 0 && y < window_title_height(w) && x < workspace_button_width(app, w) {
		toggle := tab_orientation_button_rect(w)
		if x >= toggle.x + toggle.width {return .Hand}
	}
	if render.rect_contains(status_pill_rect(app, w), x, y) {return .Hand}
	hit := tab_chrome_hit(app, w, x, y, .Left)
	if hit.close {return .Hand}
	switch target in hit.target {
	case Tab_Chrome_New, Tab_Chrome_Profiles:
		return .Hand
	case Tab_Chrome_Tab:
		if w.workspace != nil && target.index != w.workspace.selected {return .Hand}
	}
	return .Arrow
}
