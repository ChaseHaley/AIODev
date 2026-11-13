package main

import "aio:input"
import "aio:ui"

// A control on the tab strip or rail: a tab, a tab group's chip, the new-tab button or the profile
// chevron. Nil is none: empty chrome or outside it.
Tab_Chrome_Target :: union {
	Tab_Chrome_Tab,
	Tab_Chrome_Group,
	Tab_Chrome_New,
	Tab_Chrome_Profiles,
}

// A tab by its id in the window's workspace, never by its place: the hover, press and Close press a target
// names stay on the tab when a reorder, insert or close moves it to another slot.
Tab_Chrome_Tab :: struct {
	id: u32,
}

// A group's chip, by the group's id in the window's workspace.
Tab_Chrome_Group :: struct {
	id: u32,
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

// The target naming tab `index` of the window's workspace.
tab_chrome_tab :: proc(w: ^Window, index: int) -> Tab_Chrome_Tab {
	return {w.workspace.tabs[index].id}
}

// Whether tab `index` of the window's workspace draws hovered: the pointer is over that tab.
tab_hovered :: proc(w: ^Window, index: int) -> bool {
	return w.tab_hover == tab_chrome_tab(w, index)
}

// Whether tab `index` draws pressed: a Left press on it is held.
tab_pressed :: proc(w: ^Window, index: int) -> bool {
	return gesture_tab_pressed(w) == tab_chrome_tab(w, index)
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
	case Tab_Chrome_Group:
		#partial switch e.button {
		case .Left:
			// A click folds the group when it ends without a drag; a drag carries the whole group. An
			// overlay rail, which cannot reorder, folds at once.
			group := tab_group_find(w.workspace, target.id)
			if group == nil {return}
			if w.tabs_horizontal || rail_docked(w) {
				tab_chip_press(app, w, target.id, x, y)
			} else {
				_ = tab_group_fold(app, w, target.id, !group.folded)
			}
		case .Right:
			tab_group_menu_open(app, w, target.id, x, y)
			rail_overlay_dismiss(app, w)
		}
	case Tab_Chrome_Tab:
		index := tab_index_by_id(w.workspace, target.id)
		if index < 0 {return}
		if e.button == .Left && hit.close {
			ui.armed_press(&w.tab_close_armed, target.id)
			return
		}
		#partial switch e.button {
		case .Right:
			tab_menu_open(app, w, index, x, y)
			rail_overlay_dismiss(app, w)
		case .Middle:
			tab_interaction_close(app, w, index)
		case .Left:
			tab_pointer_select(app, w, index, .Control in e.modifiers, .Shift in e.modifiers)
			// Overlay selection dismisses its rows; only a stable surface can start reordering.
			if w.tabs_horizontal || rail_docked(w) {
				tab_press(app, w, index, x, y, e.modifiers & {.Control, .Shift} != {})
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
	// Tab ids start at 1, so 0 is no Close button under the release.
	released: u32
	if tab, on_tab := hit.target.(Tab_Chrome_Tab); on_tab && hit.close {released = tab.id}
	fired, ok := ui.armed_release(&w.tab_close_armed, released)
	tab_interaction_close(app, w, ok ? tab_index_by_id(w.workspace, fired) : -1)
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
	if owner == .Tabs {hover = tab_chrome_hit(app, w, x, y, .Left).target}
	if hover != w.tab_hover {w.tab_hover, w.dirty = hover, true}
	if owner == .Tabs {pointer_set(app, w, chrome_pointer(app, w, x, y))}
}

@(private)
tabs_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	hit := tab_chrome_hit(app, w, x, y, .Left)
	switch target in hit.target {
	case Tab_Chrome_Tab: if hit.close {return "Close tab"}
	case Tab_Chrome_Group:
		group := tab_group_find(w.workspace, target.id)
		if group != nil {return group.folded ? "Unfold group" : "Fold group"}
	case Tab_Chrome_Profiles: return "Choose profile"
	case Tab_Chrome_New: if w.tabs_horizontal {return "New tab"}
	case nil:
	}
	return ""
}

// The commands that do from the keyboard what a tab's close button and a group chip do for the selected
// tab: close it, and fold or unfold its group.
@(private)
tabs_shortcut :: proc(app: ^App, w: ^Window, x, y: f32) -> Tooltip_Shortcut {
	hit := tab_chrome_hit(app, w, x, y, .Left)
	switch _ in hit.target {
	case Tab_Chrome_Tab: if hit.close {return Action.Close_Tab}
	case Tab_Chrome_Group: return Action.Fold_Tab_Group
	case Tab_Chrome_New: return Action.New_Tab
	case Tab_Chrome_Profiles, nil:
	}
	return nil
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
