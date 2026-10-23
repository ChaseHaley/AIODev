package main

import "aio:commands"
import "aio:term"
import "aio:ui"

palette_active :: proc(app: ^App, w: ^Window) -> bool {
	return w != nil && w.id != 0 && app.palette_window == w.id && app.palette.open
}

palette_visible :: proc(app: ^App, w: ^Window) -> bool {
	return(
		w != nil &&
		w.id != 0 &&
		app.palette_window == w.id &&
		(app.palette.open || app.palette.motion.value > 0) \
	)
}

palette_close :: proc(app: ^App, w: ^Window) {
	if w == nil || w.id == 0 || app.palette_window != w.id {return}
	ui.palette_close(&app.palette)
	w.dirty = true
}

palette_release :: proc(app: ^App, w: ^Window) {
	if w == nil || w.id == 0 || app.palette_window != w.id {return}
	palette_close(app, w)
	app.palette.motion = {}
	app.palette_window = 0
}

palette_open :: proc(app: ^App, w: ^Window) {
	if w == nil || w.id == 0 {return}
	if previous := window_find(app, app.palette_window); previous != nil && previous != w {
		palette_release(app, previous)
	}
	if !gesture_cancel(app, w) {return}
	window_overlays_cancel(app, w)
	entry := focused_session(app, w)
	has_selection := entry != nil && term.has_selection(entry.session)
	registered := commands.set_enabled(
		&app.registry,
		commands.Command_Id(Action.Copy),
		has_selection,
	)
	assert(registered)
	app.palette_window = w.id
	ui.palette_open(&app.palette, &app.registry)
	ui.palette_layout(&app.palette, f32(w.width), f32(w.height), w.scale)
	w.dirty = true
}

window_overlays_cancel :: proc(app: ^App, w: ^Window, focus_lost := false) {
	palette_release(app, w)
	workspace_picker_cancel(w, focus_lost)
	w.tab_menu.open = false
	w.rename.dragging = false
	if w.rename_open {rename_finish(app, w, false)}
	if w.pending_close.confirm.open {pending_close_finish(app, w, false)}
	pending_close_clear(&w.pending_close)
	w.dirty = true
}
