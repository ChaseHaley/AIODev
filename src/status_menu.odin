package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:log"

// The menu a right click on an Activity row opens. Its rows are w.status_menu; which pane they act on
// is the overlay's.

Status_Menu_Choice :: enum u32 {
	Go_To_Pane,
	Mark_Read,
	Mark_Unread,
}

@(private = "file", rodata)
STATUS_MENU_LABELS := [Status_Menu_Choice]string {
	.Go_To_Pane  = "Go to Pane",
	.Mark_Read   = "Mark as Read",
	.Mark_Unread = "Mark as Unread",
}

status_menu_shown :: proc(w: ^Window) -> bool {
	_, shown := w.overlay.(Overlay_Status_Menu)
	return shown
}

// Offers what the row's pane allows: going to it, and reading it or marking it unread, whichever the
// row is not.
status_menu_open :: proc(app: ^App, w: ^Window, item: Status_Item, x, y: f32) {
	if !gesture_cancel(app, w) {return}
	overlay_open(app, w, Overlay_Status_Menu{session = item.session})
	menu := &w.status_menu
	ui.menu_clear(menu)
	ui.menu_anchor(menu, x, y)
	mark: Status_Menu_Choice = item.record.read ? .Mark_Unread : .Mark_Read
	for choice in ([2]Status_Menu_Choice{.Go_To_Pane, mark}) {
		row := ui.Menu_Item{label = STATUS_MENU_LABELS[choice], enabled = true, payload = u32(choice)}
		if added, err := ui.menu_add(menu, row); !added {
			log.errorf("adding an Activity menu row failed: %v", err)
			overlay_close(app, w)
			return
		}
	}
}

status_menu_choose :: proc(app: ^App, w: ^Window) {
	shown, ok := w.overlay.(Overlay_Status_Menu)
	index := ui.menu_selected(&w.status_menu)
	if !ok || index < 0 {return}
	item := w.status_menu.items[index]
	if !item.enabled || item.separator {return}
	overlay_close(app, w)
	switch Status_Menu_Choice(item.payload) {
	case .Go_To_Pane:
		_ = session_show(app, w, shown.session)
	case .Mark_Read:
		status_mark(app, shown.session, true)
	case .Mark_Unread:
		status_mark(app, shown.session, false)
	}
}

status_menu_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	if !e.pressed {return}
	w.dirty = true
	switch ui.menu_key(&w.status_menu, e) {
	case .None, .Submenu:
	case .Changed: ui.menu_reveal(&w.status_menu, f32(w.width), f32(w.height), w.scale)
	case .Chosen: status_menu_choose(app, w)
	case .Closed: overlay_close(app, w)
	}
}

status_menu_wheel :: proc(w: ^Window, rows: int) {
	ui.menu_wheel(&w.status_menu, rows)
	ui.menu_reveal(&w.status_menu, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

status_menu_hit :: proc(w: ^Window, x, y: f32) -> int {
	return ui.menu_hit(&w.status_menu, x, y, f32(w.width), f32(w.height), w.scale)
}

status_menu_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	width, height := f32(w.width), f32(w.height)
	return ui.menu_draw(&w.status_menu, &w.list, &w.ui_text, app.theme, width, height, w.scale, w.pointer)
}

// Activity menu pointer surface

@(private)
status_menu_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return status_menu_shown(w)}

@(private)
status_menu_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner != .Status_Menu {return}
	hit := status_menu_hit(w, f32(e.x), f32(e.y))
	enabled := hit >= 0 && w.status_menu.items[hit].enabled
	if enabled && hit != ui.menu_selected(&w.status_menu) {
		ui.menu_select(&w.status_menu, hit)
		w.dirty = true
	}
	pointer_set(app, w, enabled ? .Hand : .Arrow)
}

@(private)
status_menu_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if !e.pressed {return}
	gesture_swallow(w, e.button, .Status_Menu)
	if hit := status_menu_hit(w, f32(e.x), f32(e.y)); hit >= 0 && e.button == .Left {
		if w.status_menu.items[hit].enabled {
			ui.menu_select(&w.status_menu, hit)
			status_menu_choose(app, w)
		}
	} else {overlay_close(app, w)}
}
