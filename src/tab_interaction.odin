package main

import "aio:input"
import "aio:platform"
import "aio:ui"

Tab_Interaction_Kind :: enum {
	Outside,
	Empty,
	Tab,
	Close,
	New_Tab,
	Profiles,
}

Tab_Interaction_Hit :: struct {
	kind:        Tab_Interaction_Kind,
	index:       int,
	menu_anchor: [2]f32,
}

@(private)
tab_interaction_hit :: proc(
	app: ^App,
	w: ^Window,
	x, y: f32,
	button: input.Mouse_Button,
) -> Tab_Interaction_Hit {
	if w.tabs_horizontal {return strip_tab_interaction_hit(app, w, x, y, button)}
	return rail_tab_interaction_hit(w, x, y, button)
}

@(require_results)
tab_interaction_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	hit := tab_interaction_hit(app, w, x, y, e.button)
	if w.tabs_horizontal {
		w.tab_pressed = e.button == .Left &&
			(hit.kind == .Tab || hit.kind == .Close || hit.kind == .New_Tab)
	} else if e.button == .Left {
		#partial switch hit.kind {
		case .Tab, .Close: w.rail_pressed = hit.index
		case .New_Tab: w.rail_pressed = RAIL_NEW_TAB_ROW
		case .Profiles: w.rail_pressed = RAIL_PROFILE_ROW
		}
	}
	switch hit.kind {
	case .Outside:
		return false
	case .Empty:
	case .Profiles:
		if e.button == .Left {profile_menu_open_new_tab(app, w, hit.menu_anchor[0], hit.menu_anchor[1])}
	case .New_Tab:
		if e.button == .Left {
			tab_new(app, w)
			rail_overlay_dismiss(app, w)
		} else if e.button == .Right {
			profile_menu_open_new_tab(app, w, hit.menu_anchor[0], hit.menu_anchor[1])
		}
	case .Tab, .Close:
		if e.button == .Left && hit.kind == .Close {
			ui.armed_press(&w.tab_close_armed, hit.index)
			return true
		}
		#partial switch e.button {
		case .Right:
			tab_menu_open(app, w, hit.index, x, y)
			rail_overlay_dismiss(app, w)
		case .Middle:
			tab_interaction_close(app, w, hit.index)
		case .Left:
			tab_pointer_select(app, w, hit.index, .Control in e.modifiers, .Shift in e.modifiers)
			// Overlay selection dismisses its rows; only a stable surface can start reordering.
			if w.tabs_horizontal || rail_docked(w) {
				tab_press(app, w, hit.index, x, y, e.modifiers & {.Control, .Shift} != {})
			}
		case:
		}
	}
	return true
}

@(private)
tab_interaction_close :: proc(app: ^App, w: ^Window, index: int) {
	id := w.id
	if index >= 0 {tab_close_request(app, w, index)}
	// Closing the last tab may retire this window.
	if current := window_find(app, id); current != nil {rail_overlay_dismiss(app, current)}
}

@(require_results)
tab_interaction_release :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if !ui.armed_down(w.tab_close_armed) {return false}
	hit := tab_interaction_hit(app, w, x, y, .Left)
	index := hit.kind == .Close ? hit.index : -1
	fired, ok := ui.armed_release(&w.tab_close_armed, index)
	tab_interaction_close(app, w, ok ? fired : -1)
	return true
}
