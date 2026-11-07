package main

import "aio:input"
import "aio:ui"

// A control on the tab strip or rail: a tab by index, the new-tab button or the profile chevron. Nil
// is none: empty chrome or outside it.
Tab_Chrome_Target :: union {
	Tab_Chrome_Tab,
	Tab_Chrome_New,
	Tab_Chrome_Profiles,
}

Tab_Chrome_Tab :: struct {
	index: int,
}

Tab_Chrome_New :: struct {}

Tab_Chrome_Profiles :: struct {}

// Where a point falls on the tab chrome. `inside` is false off the strip or rail; inside it, a nil
// target is empty chrome. `close` marks the target tab's close button.
Tab_Interaction_Hit :: struct {
	target:      Tab_Chrome_Target,
	inside:      bool,
	close:       bool,
	menu_anchor: [2]f32,
}

tab_chrome_hit :: proc(
	app: ^App,
	w: ^Window,
	x, y: f32,
	button: input.Mouse_Button,
) -> Tab_Interaction_Hit {
	if w.tabs_horizontal {return strip_tab_interaction_hit(app, w, x, y, button)}
	return rail_tab_interaction_hit(w, x, y, button)
}

@(require_results)
tab_interaction_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	x, y := f32(e.x), f32(e.y)
	hit := tab_chrome_hit(app, w, x, y, e.button)
	// A Left press draws its tab, new-tab button or rail row pressed until the release; the strip's
	// profile chevron opens its menu without drawing pressed.
	if e.button == .Left && hit.target != nil {
		_, profiles := hit.target.(Tab_Chrome_Profiles)
		if !w.tabs_horizontal || !profiles {gesture_tab_press(w, hit.target)}
	}
	if !hit.inside {return false}
	switch target in hit.target {
	case Tab_Chrome_Profiles:
		if e.button == .Left {profile_menu_open_new_tab(app, w, hit.menu_anchor[0], hit.menu_anchor[1])}
	case Tab_Chrome_New:
		if e.button == .Left {
			tab_new(app, w)
			rail_overlay_dismiss(app, w)
		} else if e.button == .Right {
			profile_menu_open_new_tab(app, w, hit.menu_anchor[0], hit.menu_anchor[1])
		}
	case Tab_Chrome_Tab:
		if e.button == .Left && hit.close {
			ui.armed_press(&w.tab_close_armed, target.index)
			return true
		}
		#partial switch e.button {
		case .Right:
			tab_menu_open(app, w, target.index, x, y)
			rail_overlay_dismiss(app, w)
		case .Middle:
			tab_interaction_close(app, w, target.index)
		case .Left:
			tab_pointer_select(app, w, target.index, .Control in e.modifiers, .Shift in e.modifiers)
			// Overlay selection dismisses its rows; only a stable surface can start reordering.
			if w.tabs_horizontal || rail_docked(w) {
				tab_press(app, w, target.index, x, y, e.modifiers & {.Control, .Shift} != {})
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
	hit := tab_chrome_hit(app, w, x, y, .Left)
	index := -1
	if tab, on_tab := hit.target.(Tab_Chrome_Tab); on_tab && hit.close {index = tab.index}
	fired, ok := ui.armed_release(&w.tab_close_armed, index)
	tab_interaction_close(app, w, ok ? fired : -1)
	return true
}
