package main

import "aio:input"
import "aio:ui"
import "core:time"

// w took focus, so it becomes the most recently focused window, the one the notices prefer.
window_focus_note :: proc(app: ^App, w: ^Window) {
	app.window_focus_order += 1
	w.focus_order = app.window_focus_order
}

// The notices show in window_focused_or_recent. Focus changes, closing a window and each tick call
// this, as any of them can change which window that is.
window_notices_sync :: proc(app: ^App) {
	target := window_focused_or_recent(app)
	id := target != nil ? target.id : input.Window_Id(0)
	if app.notice_window == id {return}
	app.notice_window = id
	ui.notices_pointer_cancel(&app.notices)
	for w in app.windows {w.dirty = true}
}

@(private = "file")
notice_hit :: proc(app: ^App, w: ^Window, x, y: f32) -> ui.Notice_Hit {
	if app.notice_window != w.id {return {}}
	return ui.notices_hit(&app.notices, &w.ui_text, f32(w.width), f32(w.height), w.scale, x, y)
}

@(private)
notice_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	return notice_hit(app, w, x, y).contains
}

@(private)
notice_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	// Only the window holding the notices has their hover to change.
	if app.notice_window != w.id {return}
	hit := owner == .Notice ? notice_hit(app, w, f32(e.x), f32(e.y)) : ui.Notice_Hit{}
	if ui.notices_hover(&app.notices, hit.close ? hit.id : 0) {w.dirty = true}
	if owner == .Notice {pointer_set(app, w, hit.close ? .Hand : .Arrow)}
}

@(private)
notice_tooltip :: proc(app: ^App, w: ^Window, x, y: f32) -> string {
	return notice_hit(app, w, x, y).close ? "Dismiss notification" : ""
}

@(private)
notice_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if e.button != .Left {return}
	hit := notice_hit(app, w, f32(e.x), f32(e.y))
	ui.notices_press(&app.notices, hit.close ? hit.id : 0)
}

// A notice press ends here even after the notices moved to another window, which cancelled it there.
@(private)
notice_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if app.notice_window != w.id {return true}
	if e.button == .Left {
		hit := notice_hit(app, w, f32(e.x), f32(e.y))
		if ui.notices_release(&app.notices, hit.close ? hit.id : 0, app.animations, time.tick_now()) {
			for window in app.windows {window.dirty = true}
		}
	}
	_ = ui.notices_hover(&app.notices, 0)
	w.dirty = true
	return true
}

@(private)
notice_cancel :: proc(app: ^App, w: ^Window) {
	if app.notice_window == w.id {ui.notices_pointer_cancel(&app.notices)}
}

@(private)
notice_leave :: proc(app: ^App, w: ^Window) {
	if app.notice_window == w.id {_ = ui.notices_hover(&app.notices, 0)}
}
