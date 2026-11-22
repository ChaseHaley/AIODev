package main

import "aio:term"
import "core:time"
import "cosmos:ui"
import "cosmos:host"

@(private)
COPY_NOTICE_DURATION :: 2 * time.Second

copy_selection :: proc(app: ^App, entry: ^Session_Entry, explicit: bool) {
	text, selected := term.selection_text(entry.session, context.temp_allocator)
	if !selected {
		return
	}
	if !clipboard_copy(app, text) {return}
	ui.notices_put(
		&app.notices,
		u32(Notice_Key.Copy),
		.Success,
		"Copied to clipboard",
		COPY_NOTICE_DURATION,
		app.animations,
		host.clock_now(&app.clock),
		stack = true,
	)
	mark_all_dirty(app)
	if explicit {term.clear_selection(entry.session)}
}

// A Left drag selecting terminal text; nil is Idle. Selecting holds the session pressed; past the top or
// bottom edge history scrolls a row each time `scroll` is due. The direction stays with the session's
// selection gesture. The procs in this file are the only writers.
Selection_Drag :: union {
	Selection_Selecting,
}

Selection_Selecting :: struct {
	session: u32,
	scroll:  ui.Edge_Scroll,
}

selection_active :: proc(w: ^Window) -> bool {
	return w.selection != nil
}

// The session the drag selects in, or nil while Idle or once it is gone.
selection_entry :: proc(app: ^App, w: ^Window) -> ^Session_Entry {
	selecting, ok := w.selection.(Selection_Selecting)
	return ok ? session_find(app, selecting.session) : nil
}

selection_autoscroll_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	selecting, ok := w.selection.(Selection_Selecting)
	if !ok {return {}, false}
	return ui.edge_scroll_deadline(selecting.scroll)
}

// A Left press on content starts the drag in `entry`; a press during the drag continues it.
@(private)
selection_begin :: proc(w: ^Window, entry: ^Session_Entry, x, y: f32, time_ns: i64) {
	if w.selection == nil {w.selection = Selection_Selecting{session = entry.id}}
	term.selection_press(entry.session, x, y, time_ns)
	w.dirty = true
}

// The pointer moved during the drag: the selection follows, and passing an edge starts autoscroll.
@(private)
selection_move :: proc(w: ^Window, entry: ^Session_Entry, x, y: f32, now: time.Tick) {
	term.selection_drag(entry.session, x, y)
	selection_follow(w, entry, now)
	w.dirty = true
}

@(private = "file")
selection_follow :: proc(w: ^Window, entry: ^Session_Entry, now: time.Tick) {
	selecting, ok := &w.selection.(Selection_Selecting)
	if !ok {return}
	selecting.session = entry.id
	_ = ui.edge_scroll_follow(&selecting.scroll, term.selection_autoscroll(entry.session) != .None, now)
}

// Scrolls one row once the autoscroll is due.
selection_autoscroll_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	selecting, ok := &w.selection.(Selection_Selecting)
	if !ok || selecting.scroll.due == nil {return}
	entry := session_find(app, selecting.session)
	// A gone session only stops the scrolling. The button is still held, so the drag stays Selecting
	// and keeps the pointer until the release ends it; selection_entry then finds nothing to copy.
	if entry == nil {
		ui.edge_scroll_stop(&selecting.scroll)
		return
	}
	if !ui.edge_scroll_due(&selecting.scroll, now) {return}
	term.selection_autoscroll_tick(entry.session, w.pointer.x, w.pointer.y)
	w.dirty = true
	selection_follow(w, entry, now)
}

// The release keeps the selection, and copies it when the setting asks.
@(private)
selection_finish :: proc(app: ^App, w: ^Window, x, y: f32) {
	entry := selection_entry(app, w)
	w.selection = nil
	if entry == nil {return}
	term.selection_release(entry.session, x, y)
	if app.settings.terminal.copy_on_select {copy_selection(app, entry, false)}
	w.dirty = true
}

// The drag stops where it is, without a release.
selection_cancel :: proc(w: ^Window) {
	w.selection = nil
}
