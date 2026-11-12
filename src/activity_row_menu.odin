package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:log"

// The menu a right click on an Activity row opens. Its rows are w.activity_row_menu; which pane they
// act on is the overlay's.

Activity_Row_Choice :: enum u32 {
	Go_To_Pane,
	Mark_Read,
	Mark_Unread,
}

@(private = "file", rodata)
ACTIVITY_ROW_LABELS := [Activity_Row_Choice]string {
	.Go_To_Pane  = "Go to Pane",
	.Mark_Read   = "Mark as Read",
	.Mark_Unread = "Mark as Unread",
}

activity_row_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Activity_Row_Menu)
	return shown
}

// Offers going to the row's pane, and reading it or marking it unread, whichever the row is not,
// unless the row is working out of view and so always unread.
activity_row_menu_open :: proc(app: ^App, w: ^Window, item: Status_Item, x, y: f32) {
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Activity_Row_Menu{session = item.session})
	menu := &w.activity_row_menu
	ui.menu_clear(menu)
	ui.menu_anchor(menu, x, y)
	mark: Activity_Row_Choice = item.record.read ? .Mark_Unread : .Mark_Read
	choices := [2]Activity_Row_Choice{.Go_To_Pane, mark}
	for choice in choices[:status_item_markable(item) ? 2 : 1] {
		row := ui.Menu_Item{label = ACTIVITY_ROW_LABELS[choice], enabled = true, payload = u32(choice)}
		if added, err := ui.menu_add(menu, row); !added {
			log.errorf("adding an Activity row menu row failed: %v", err)
			overlay_close(app, w)
			return
		}
	}
}

activity_row_menu_choose :: proc(app: ^App, w: ^Window) {
	shown, ok := w.overlay.(Overlay_Activity_Row_Menu)
	index := ui.menu_selected(&w.activity_row_menu)
	if !ok || index < 0 {return}
	item := w.activity_row_menu.items[index]
	if !item.enabled || item.separator {return}
	overlay_close(app, w)
	switch Activity_Row_Choice(item.payload) {
	case .Go_To_Pane:
		_ = session_show(app, w, shown.session)
	case .Mark_Read:
		status_mark(app, shown.session, true)
	case .Mark_Unread:
		status_mark(app, shown.session, false)
	}
}

activity_row_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	switch ui.menu_key(&w.activity_row_menu, e) {
	case .None, .Submenu:
	case .Changed: ui.menu_reveal(&w.activity_row_menu, f32(w.width), f32(w.height), w.scale)
	case .Chosen: activity_row_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

activity_row_menu_wheel :: proc(w: ^Window, rows: int) {
	ui.menu_wheel(&w.activity_row_menu, rows)
	ui.menu_reveal(&w.activity_row_menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

activity_row_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	return ui.menu_hit(&w.activity_row_menu, x, y, f32(w.width), f32(w.height), w.scale)
}

activity_row_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	width, height := f32(w.width), f32(w.height)
	return ui.menu_draw(&w.activity_row_menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}

// Activity row menu pointer surface

@(private)
activity_row_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return activity_row_menu_shown(w)}

@(private)
activity_row_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Activity_Row_Menu {return}
	hit := activity_row_menu_hit(w, f32(e.x), f32(e.y))
	enabled := hit >= 0 && w.activity_row_menu.items[hit].enabled
	if enabled && hit != ui.menu_selected(&w.activity_row_menu) {
		ui.menu_select(&w.activity_row_menu, hit)
		w.dirty = true
	}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

@(private)
activity_row_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Activity_Row_Menu)
	if hit := activity_row_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		if w.activity_row_menu.items[hit].enabled {
			ui.menu_select(&w.activity_row_menu, hit)
			activity_row_menu_choose(app, w)
		}
	} else {overlay_close(app, w)}
}
