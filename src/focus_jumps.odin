package main

import "cosmos:input"
import "aio:layout"

// Pane focus as a jump list, like an editor's back and forward. Entries are session ids, so a pane
// keeps its place as it moves between tabs, workspaces and windows.

@(private) FOCUS_JUMPS_LIMIT :: 100

Focus_Jumps :: struct {
	entries: [dynamic]u32,
	// The entry the user is on; entries after it are the forward path.
	index: int,
	// The window the user last worked in. It is tracked here rather than read from window focus
	// events, which arrive a tick after a jump asks for activation, and for a linked window only once
	// it is shown.
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

// A destroyed window never reports losing focus, so the jump list moves on to the window the user is
// in now.
focus_jumps_window_closed :: proc(app: ^App, id: input.Window_Id) {
	if app.focus_jumps.window != id {return}
	next := window_focused_or_recent(app)
	app.focus_jumps.window = next != nil ? next.id : 0
}

// A reveal moved the keyboard to `content`, so the jump list follows the window that holds the pane: its
// linked window when it has one, else `owner`, the window showing its workspace. Following `owner` for a
// linked pane would record the pane focused there, which the user never landed on, and drop the forward
// path (WORK-457).
focus_jumps_follow :: proc(app: ^App, owner: ^Window, content: layout.Content) {
	holder := pane_link_window_of(app, content)
	app.focus_jumps.window = (holder != nil ? holder : owner).id
}

@(private)
focus_jump_reachable :: proc(data: rawptr, session: u32) -> bool {
	app := (^App)(data)
	if session_find(app, session) == nil {return false}
	workspace := session_workspace(app, session)
	return workspace != nil && workspace_eligible(app, workspace)
}

// Steps back or forward along the focus path, crossing tabs, workspaces and windows. The reveal points
// the jump list at the window holding the pane.
focus_jump :: proc(app: ^App, w: ^Window, step: int) {
	session, ok := focus_jumps_step(&app.focus_jumps, step, focus_jump_reachable, app)
	if !ok {return}
	target := session_window(app, session, w)
	if target != w && !window_activate(app, target) {return}
	_ = session_show(app, target, session)
}
