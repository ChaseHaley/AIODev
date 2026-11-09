package main

import "aio:term"
import "aio:ui"
import "core:time"

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
		clock_now(&app.clock),
	)
	mark_all_dirty(app)
	if explicit {term.clear_selection(entry.session)}
}

// A Left drag selecting terminal text; nil is Idle. Selecting holds the session pressed; past the top or
// bottom edge it is Autoscrolling, and history scrolls a row each time `deadline` passes. The direction
// stays with the session's selection gesture. The procs in this file are the only writers.
Selection_Drag :: union {
	Selection_Selecting,
	Selection_Autoscrolling,
}

Selection_Selecting :: struct {
	session: u32,
}

Selection_Autoscrolling :: struct {
	session:  u32,
	deadline: time.Tick,
}

// How often an autoscrolling drag moves history by a row.
@(private = "file")
AUTOSCROLL_INTERVAL :: 30 * time.Millisecond

selection_active :: proc(w: ^Window) -> bool {
	return w.selection != nil
}

// The session the drag selects in, or nil while Idle or once it is gone.
selection_entry :: proc(app: ^App, w: ^Window) -> ^Session_Entry {
	switch s in w.selection {
	case Selection_Selecting: return session_find(app, s.session)
	case Selection_Autoscrolling: return session_find(app, s.session)
	}
	return nil
}

selection_autoscroll_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	autoscrolling, ok := w.selection.(Selection_Autoscrolling)
	return autoscrolling.deadline, ok
}

// A Left press on content starts the drag in `entry`; a press during the drag continues it.
@(private)
selection_begin :: proc(w: ^Window, entry: ^Session_Entry, x, y: f32, time_ns: i64) {
	if w.selection == nil {w.selection = Selection_Selecting{entry.id}}
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
	if term.selection_autoscroll(entry.session) == .None {
		w.selection = Selection_Selecting{entry.id}
	} else if _, autoscrolling := w.selection.(Selection_Autoscrolling); !autoscrolling {
		w.selection = Selection_Autoscrolling{entry.id, time.tick_add(now, AUTOSCROLL_INTERVAL)}
	}
}

// Scrolls one row once the autoscroll deadline passes.
selection_autoscroll_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	autoscrolling, ok := w.selection.(Selection_Autoscrolling)
	if !ok {return}
	entry := session_find(app, autoscrolling.session)
	// A gone session only stops the scrolling. The button is still held, so the drag stays Selecting
	// and keeps the pointer until the release ends it; selection_entry then finds nothing to copy.
	if entry == nil {
		w.selection = Selection_Selecting{autoscrolling.session}
		return
	}
	if time.tick_diff(autoscrolling.deadline, now) < 0 {return}
	term.selection_autoscroll_tick(entry.session, w.pointer.x, w.pointer.y)
	w.selection = Selection_Autoscrolling{entry.id, time.tick_add(now, AUTOSCROLL_INTERVAL)}
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
