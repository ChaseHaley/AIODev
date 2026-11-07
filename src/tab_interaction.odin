package main

import "aio:input"
import "aio:ui"
import "aio:render"

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

tab_interaction_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	hit := tab_chrome_hit(app, w, x, y, e.button)
	// A Left press draws its tab, new-tab button or rail row pressed until the release; the strip's
	// profile chevron opens its menu without drawing pressed.
	if e.button == .Left && hit.target != nil {
		_, profiles := hit.target.(Tab_Chrome_Profiles)
		if !w.tabs_horizontal || !profiles {gesture_tab_press(w, hit.target)}
	}
	if !hit.inside {return}
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
			return
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

// Tab strip and rail pointer surface

@(private)
tabs_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return tab_chrome_hit(app, w, x, y, .Left).inside
}

@(private)
tabs_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	hover: Tab_Chrome_Target
	if owner == .Tabs && w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		hover = window_tab_hit(app, w, bar, x, y)
		chevron := tab_chevron_rect(app, w)
		if x >= chevron.x && x < chevron.x + chevron.width && y >= 0 && y < bar.height {
			hover = Tab_Chrome_Profiles{}
		}
	} else if owner == .Tabs {
		if layout, ok := rail_current_layout(w); ok {
			if index := rail_tab_hit(w, layout, x, y); index >= 0 {
				hover = Tab_Chrome_Tab{index}
			} else {
				hover = rail_footer_target(layout, x, y)
			}
		}
	}
	if hover != w.tab_hover {w.tab_hover, w.dirty = hover, true}
	if owner == .Tabs {pointer_set(app, w, chrome_pointer(app, w, x, y))}
}

@(private)
tabs_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		if window_tab_close_hit(app, w, bar, x, y) >= 0 {return "Close tab"}
		if x >= tab_chevron_rect(app, w).x {return "Choose profile"}
		if _, new_tab := window_tab_hit(app, w, bar, x, y).(Tab_Chrome_New); new_tab {return "New tab"}
	} else if layout, ok := rail_current_layout(w); ok {
		if row := rail_tab_hit(w, layout, x, y); row >= 0 {
			close := rail_tab_close_rect(w, layout, row)
			if render.rect_contains(close, x, y) {return "Close tab"}
		}
		if ui.rail_footer_hit(layout, x, y) {
			if ui.rail_profile_hit(layout, x, y) {return "Choose profile"}
		}
	}
	return ""
}

// A tab close fires on a matching release; a tab drag settles wherever it is released.
@(private)
tabs_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	w.dirty = true
	if tab_interaction_release(app, w, f32(e.x), f32(e.y)) {return true}
	if !tab_drag_held(w) {return false}
	// A drag holding a workspace dropdown open drops on the row under the release.
	if drag_holds_dropdown(w) {_ = tab_drag_move(app, w, f32(e.x), f32(e.y))}
	tab_drag_finish(app, w)
	return true
}

@(private)
tabs_cancel :: proc(_: ^App, w: ^Window) {
	w.tab_hover = nil
	ui.armed_cancel(&w.tab_close_armed)
}

@(private)
tabs_leave :: proc(_: ^App, w: ^Window) {
	w.tab_hover = nil
	gesture_tab_unpress(w)
}

// A tab drag follows the pointer once it has started, or while no modal surface is under it.
@(private)
tabs_held :: proc(app: ^App, w: ^Window, under: Pointer_Target, e: input.Mouse_Move_Event) -> Pointer_Held {
	if !tab_drag_held(w) || drag_active(w) == nil && pointer_modal(under) {return .Free}
	if .Left not_in e.buttons {tab_drag_cancel(app, w); return .Ended}
	if !tab_drag_move(app, w, f32(e.x), f32(e.y)) {return .Free}
	if a, carry := tab_drag_state(w); a != nil {
		_, reorder := carry.destination.(Drop_Reorder)
		pointer_set(app, w, carry.destination == nil || reorder ? .Arrow : .Resize_All)
	}
	return .Taken
}
