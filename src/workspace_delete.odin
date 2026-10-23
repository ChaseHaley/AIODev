package main

import "aio:term"

@(private)
workspace_delete_destination :: proc(app: ^App, workspace: ^Workspace) -> ^Workspace {
	index := -1
	for current, i in app.workspaces {if current == workspace {index = i; break}}
	if index < 0 {return nil}
	for offset in 1 ..< len(app.workspaces) {
		candidate := app.workspaces[(index + offset) % len(app.workspaces)]
		if workspace_eligible(app, candidate) &&
		   window_for_workspace(app, candidate) == nil {return candidate}
	}
	return nil
}

workspace_delete_request :: proc(app: ^App, w: ^Window, workspace: ^Workspace) {
	if w == nil || w.preparing || !workspace_eligible(app, workspace) {return}
	owner := window_for_workspace(app, workspace)
	destination := owner != nil ? workspace_delete_destination(app, workspace) : nil
	pending_close_open_workspace(app, w, workspace, owner, destination)
}

@(private)
workspace_delete_release :: proc(app: ^App, workspace: ^Workspace) {
	walk := workspace_session_panes(app, workspace)
	for pane, ok := workspace_pane_next(&walk); ok; pane, ok = workspace_pane_next(&walk) {
		session_close(app, pane.content.id)
	}
	for current, i in app.workspaces {
		if current == workspace {ordered_remove(&app.workspaces, i); break}
	}
	workspace_destroy(workspace)
}

@(private)
@(require_results)
workspace_delete_commit :: proc(app: ^App, workspace: ^Workspace) -> bool {
	if !workspace_eligible(app, workspace) {return false}
	owner := window_for_workspace(app, workspace)
	destination := owner != nil ? workspace_delete_destination(app, workspace) : nil
	fresh := destination == nil && (owner != nil || len(app.workspaces) == 1)
	if fresh {
		destination = workspace_create_empty(app)
		if destination == nil {return false}
	}
	committed := false
	defer if fresh &&
	   !committed {workspace_delete_release(app, destination); workspace_pickers_refresh(app)}
	created_tab := destination != nil && len(destination.tabs) == 0
	if created_tab && !tab_create(app, destination) {return false}
	defer if created_tab && !fresh && !committed {workspace_close_tab(app, destination, 0)}
	if created_tab {
		entry := session_find(app, app.next_session_id)
		if entry == nil || term.status(entry.session).kind == .Failed {return false}
	}
	// Replacing pre-flights every view before the old workspace is released (D-053).
	if owner != nil && !workspace_adopt(app, owner, destination, .Replace) {return false}
	workspace_delete_release(app, workspace)
	committed = true
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	return true
}

workspace_delete_accept :: proc(app: ^App, w: ^Window) {
	pc := &w.pending_close
	workspace := workspace_find(app, pc.workspace)
	if workspace == nil {return}
	owner := window_for_workspace(app, workspace)
	destination := owner != nil ? workspace_delete_destination(app, workspace) : nil
	owner_id := owner != nil ? owner.id : 0
	destination_id := destination != nil ? destination.id : 0
	if owner_id != pc.owner || destination_id != pc.destination {
		workspace_delete_request(app, w, workspace)
		return
	}
	if !workspace_delete_commit(app, workspace) {
		notify(app, .Error, "Could not prepare the replacement. The workspace was preserved.")
	}
}
