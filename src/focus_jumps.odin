package main

import "cosmos:input"
import "aio:layout"

// Pane focus as a jump list, like an editor's back and forward. Entries name panes by their content, so a
// pane of any kind keeps its place as it moves between tabs, workspaces and windows.

@(private) FOCUS_JUMPS_LIMIT :: 100

Focus_Jumps :: struct {
	entries: [dynamic]Focus_Jump,
	// The entry the user is on; entries after it are the forward path.
	index: int,
	// The window the user last worked in. It is tracked here rather than read from window focus
	// events, which arrive a tick after a jump asks for activation, and for a linked window only once
	// it is shown.
	window: input.Window_Id,
}

// A pane in the jump list. Content each workspace shows at most once (Settings) has the same id in every
// workspace, so its entry also names the workspace; other content is unique and found wherever it moves.
Focus_Jump :: struct {
	content:   layout.Content,
	workspace: u32,
}

// The entry for `content` shown in `workspace`.
focus_jump_of :: proc(workspace: ^Workspace, content: layout.Content) -> Focus_Jump {
	if !CONTENT_POLICY[content.kind].one_per_workspace || workspace == nil {return {content = content}}
	return {content, workspace.id}
}

focus_jumps_destroy :: proc(j: ^Focus_Jumps) {
	delete(j.entries)
	j^ = {}
}

// Records a focus change. A new pane away from the current entry drops the forward path, as
// browsing does.
focus_jumps_note :: proc(j: ^Focus_Jumps, jump: Focus_Jump) {
	if len(j.entries) > 0 && j.entries[j.index] == jump {return}
	if len(j.entries) > 0 {resize(&j.entries, j.index + 1)}
	if len(j.entries) >= FOCUS_JUMPS_LIMIT {ordered_remove(&j.entries, 0)}
	if _, err := append(&j.entries, jump); err != nil {return}
	j.index = len(j.entries) - 1
}

// A pane of `workspace` now shows `to` in place of `from`, keeping its split, float or linked slot. It is
// still the same pane, so its entries keep their places in the path.
focus_jumps_replace :: proc(j: ^Focus_Jumps, workspace: ^Workspace, from, to: layout.Content) {
	before, after := focus_jump_of(workspace, from), focus_jump_of(workspace, to)
	for &entry in j.entries {
		if entry == before {entry = after}
	}
}

// Moves one step back (step < 0) or forward along the path, dropping entries `reachable` refuses
// on the way. Returns the pane to show.
focus_jumps_step :: proc(
	j: ^Focus_Jumps,
	step: int,
	reachable: proc(data: rawptr, jump: Focus_Jump) -> bool,
	data: rawptr,
) -> (
	jump: Focus_Jump,
	ok: bool,
) {
	direction := step < 0 ? -1 : 1
	for {
		target := j.index + direction
		if target < 0 || target >= len(j.entries) {return {}, false}
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
	content, is_pane := window_focused_content(w)
	if !is_pane {return}
	// A linked window shows its own view of a tab whose panes belong to the linked window's home workspace.
	workspace := window_linked(w) ? workspace_find(app, window_link_workspace(w)) : w.workspace
	focus_jumps_note(&app.focus_jumps, focus_jump_of(workspace, content))
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

// The pane an entry names, in a workspace the user can reach.
@(private)
focus_jump_find :: proc(app: ^App, jump: Focus_Jump) -> (^Workspace, Workspace_Pane, bool) {
	if jump.workspace == 0 {return content_pane_find(app, jump.content)}
	workspace := workspace_find(app, jump.workspace)
	if workspace == nil || workspace.provisional {return nil, {}, false}
	pane, found := workspace_content_pane(app, workspace, jump.content)
	return found ? workspace : nil, pane, found
}

@(private)
focus_jump_reachable :: proc(data: rawptr, jump: Focus_Jump) -> bool {
	app := (^App)(data)
	workspace, _, found := focus_jump_find(app, jump)
	return found && workspace_eligible(app, workspace)
}

// Steps back or forward along the focus path, crossing tabs, workspaces and windows. The reveal points
// the jump list at the window holding the pane.
focus_jump :: proc(app: ^App, w: ^Window, step: int) {
	jump, ok := focus_jumps_step(&app.focus_jumps, step, focus_jump_reachable, app)
	if !ok {return}
	workspace, pane, _ := focus_jump_find(app, jump)
	target := window_for_workspace(app, workspace)
	if target == nil {target = w}
	if target != w && !window_activate(app, target) {return}
	_ = pane_show(app, target, workspace, pane)
}
