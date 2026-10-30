package main

import "aio:platform"
import "aio:ui"

// The pointer over the title bar and the tabs, wherever they are docked. A hand marks a control
// whose click changes something; the selected tab is already shown, so only its close button
// takes a hand. Caption buttons keep the arrow, as native windows do.
chrome_pointer :: proc(app: ^App, w: ^Window, x, y: f32) -> platform.Cursor_Shape {
	if tab_orientation_button_hit(w, x, y) {return .Hand}
	if y >= 0 && y < ui.TITLE_BAR_HEIGHT * w.scale && x < workspace_button_width(w) {
		toggle := tab_orientation_button_rect(w)
		if x >= toggle.x + toggle.width {return .Hand}
	}
	if status_rect_contains(status_pill_rect(app, w), x, y) {return .Hand}
	hit := tab_interaction_hit(app, w, x, y, .Left)
	switch hit.kind {
	case .Outside, .Empty:
	case .Close, .New_Tab, .Profiles:
		return .Hand
	case .Tab:
		if w.workspace != nil && hit.index != w.workspace.selected {return .Hand}
	}
	return .Arrow
}
