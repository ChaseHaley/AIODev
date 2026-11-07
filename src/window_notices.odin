package main

import "aio:input"
import "aio:ui"

// w took focus, so it becomes the most recently focused window, the one the notices prefer.
window_focus_note :: proc(app: ^App, w: ^Window) {
	app.window_focus_order += 1
	w.focus_order = app.window_focus_order
}

// The notices show in one window: the focused one, else the one focused most recently. Focus changes,
// closing a window and each tick call this, as any of them can change which window that is.
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
	id := target != nil ? target.id : input.Window_Id(0)
	if app.notice_window == id {return}
	app.notice_window = id
	ui.notices_pointer_cancel(&app.notices)
	for w in app.windows {w.dirty = true}
}
