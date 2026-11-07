package main

import "aio:input"

// Pane focus as a jump list, like an editor's back and forward. Entries are session ids, so a pane
// keeps its place as it moves between tabs, workspaces and windows.

@(private) FOCUS_JUMPS_LIMIT :: 100

Focus_Jumps :: struct {
	entries: [dynamic]u32,
	// The entry the user is on; entries after it are the forward path.
	index: int,
	// The window the user last worked in. It is tracked here rather than read from window focus
	// events, which arrive a tick after a jump asks for activation.
	window: input.Window_Id,
}

focus_jumps_destroy :: proc(j: ^Focus_Jumps) {
	delete(j.entries)
	j^ = {}
}

// Records a focus change. A new pane away from the current entry drops the forward path, as
// browsing does.
focus_jumps_note :: proc(j: ^Focus_Jumps, session: u32) {
	if session == 0 {return}
	if len(j.entries) > 0 && j.entries[j.index] == session {return}
	if len(j.entries) > 0 {resize(&j.entries, j.index + 1)}
	if len(j.entries) >= FOCUS_JUMPS_LIMIT {ordered_remove(&j.entries, 0)}
	if _, err := append(&j.entries, session); err != nil {return}
	j.index = len(j.entries) - 1
}

// Moves one step back (step < 0) or forward along the path, dropping entries `reachable` refuses
// on the way. Returns the session to show.
focus_jumps_step :: proc(
	j: ^Focus_Jumps,
	step: int,
	reachable: proc(data: rawptr, session: u32) -> bool,
	data: rawptr,
) -> (
	session: u32,
	ok: bool,
) {
	direction := step < 0 ? -1 : 1
	for {
		target := j.index + direction
		if target < 0 || target >= len(j.entries) {return 0, false}
		if reachable(data, j.entries[target]) {
			j.index = target
			return j.entries[target], true
		}
		ordered_remove(&j.entries, target)
		if direction < 0 {j.index -= 1}
	}
}

// Called once per tick, after every event, so a jump or a reveal that walks several tabs records
// only the pane it lands on.
focus_jumps_track :: proc(app: ^App) {
	w := window_find(app, app.focus_jumps.window)
	if w == nil {return}
	if entry := focused_session(app, w); entry != nil {focus_jumps_note(&app.focus_jumps, entry.id)}
}

// A destroyed window never reports losing focus, so the jump list follows the notices to the window
// focused most recently.
focus_jumps_window_closed :: proc(app: ^App, id: input.Window_Id) {
	if app.focus_jumps.window == id {app.focus_jumps.window = app.notice_window}
}

@(private)
focus_jump_reachable :: proc(data: rawptr, session: u32) -> bool {
	app := (^App)(data)
	if session_find(app, session) == nil {return false}
	workspace := session_workspace(app, session)
	return workspace != nil && workspace_eligible(app, workspace)
}

// Steps back or forward along the focus path, crossing tabs, workspaces and windows.
focus_jump :: proc(app: ^App, w: ^Window, step: int) {
	session, ok := focus_jumps_step(&app.focus_jumps, step, focus_jump_reachable, app)
	if !ok {return}
	target := session_window(app, session, w)
	if target != w && !window_activate(app, target) {return}
	if !session_show(app, target, session) {return}
	if owner := window_for_workspace(app, session_workspace(app, session)); owner != nil {
		app.focus_jumps.window = owner.id
	}
}
