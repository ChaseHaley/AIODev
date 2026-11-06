package main

import "aio:platform"
import "aio:ui"

window_notices_sync :: proc(app: ^App) {
	target: ^Window
	for w in app.windows {
		if !window_drawable(w) {continue}
		if target == nil ||
		   (w.focused && !target.focused) ||
		   (w.focused == target.focused && w.focus_order > target.focus_order) {
			target = w
		}
	}
	id := target != nil ? target.id : platform.Window_Id(0)
	if app.notice_window == id {return}
	app.notice_window = id
	ui.notices_pointer_cancel(&app.notices)
	for w in app.windows {
		w.notice_buttons = {}
		w.dirty = true
	}
}
