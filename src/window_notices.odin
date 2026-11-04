package main

import "aio:platform"
import "aio:ui"

window_notices_sync :: proc(app: ^App) {
	target: ^Window
	for w in app.windows {
		if w.preparing || (w.linked && !w.link_shown) || w.width <= 0 || w.height <= 0 {continue}
		if target == nil ||
		   (w.focused && !target.focused) ||
		   (w.focused == target.focused && w.focus_order > target.focus_order) {
			target = w
		}
	}
	id := target != nil ? target.id : platform.Window_Id(0)
	if app.notice_window == id {return}
	app.notice_window = id
	for w in app.windows {
		w.notice_hover = 0
		w.notice_buttons = {}
		ui.armed_cancel(&w.notice_armed)
		w.dirty = true
	}
}
