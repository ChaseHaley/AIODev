package main

import "aio:term"

workspace_delete_request :: proc(app: ^App, w: ^Window, workspace: ^Workspace) {
	if w == nil || w.preparing || !workspace_eligible(app, workspace) {return}
	pending_close_open_workspace(app, w, workspace, workspace_delete_plan(app, workspace))
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

// Performs exactly the plan the question presented. The plan carries the owner and destination
// identities, so the commit resolves them instead of deriving a second, possibly different plan.
@(private)
@(require_results)
workspace_delete_commit :: proc(app: ^App, plan: Workspace_Delete_Plan) -> bool {
	workspace := workspace_find(app, plan.workspace)
	if workspace == nil || !workspace_eligible(app, workspace) {return false}
	owner: ^Window
	if plan.owner != 0 {
		owner = window_find(app, plan.owner)
		if owner == nil {return false}
	}
	destination := plan.destination != 0 ? workspace_find(app, plan.destination) : nil
	if plan.fresh {
		destination = workspace_create_empty(app)
		if destination == nil {return false}
	} else if plan.destination != 0 && destination == nil {return false}
	committed := false
	defer if plan.fresh &&
	   !committed {workspace_delete_release(app, destination); workspace_pickers_refresh(app)}
	if plan.created_tab && !tab_create(app, destination) {return false}
	defer if plan.created_tab && !plan.fresh && !committed {workspace_close_tab(app, destination, 0)}
	if plan.created_tab {
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
	workspace := workspace_find(app, pc.plan.workspace)
	if workspace == nil {return}
	plan := workspace_delete_plan(app, workspace)
	if !workspace_delete_plan_same(plan, pc.plan) {
		workspace_delete_request(app, w, workspace)
		return
	}
	if !workspace_delete_commit(app, plan) {
		notify(app, .Error, "Could not prepare the replacement. The workspace was preserved.")
	}
}
