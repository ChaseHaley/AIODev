package main

import "aio:term"

workspace_delete_request :: proc(app: ^App, w: ^Window, workspace: ^Workspace) {
	if w == nil || w.phase == .Preparing || !workspace_eligible(app, workspace) {return}
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
	   !committed {workspace_delete_release(app, destination); workspace_mutation_finish(app, nil, {.Names})}
	session: u32
	if plan.created_tab {
		created: bool
		session, created = tab_create(app, destination)
		if !created {return false}
	}
	defer if plan.created_tab && !plan.fresh && !committed {workspace_close_tab(app, destination, 0)}
	// A created tab can hold a shell that failed to start; the replacement must actually run.
	if plan.created_tab {
		entry := session_find(app, session)
		if entry == nil || term.status(entry.session).kind == .Failed {return false}
	}
	// Replacing pre-flights every view before the old workspace is released (D-053).
	if owner != nil && !workspace_adopt(app, owner, destination, .Replace) {return false}
	workspace_delete_release(app, workspace)
	committed = true
	workspace_mutation_finish(app, destination, {.Names})
	return true
}

// Deletes the workspace when the plan the question presented still holds, and asks again with the
// current plan when it does not.
workspace_delete_accept :: proc(app: ^App, w: ^Window, presented: Workspace_Delete_Plan) {
	workspace := workspace_find(app, presented.workspace)
	if workspace == nil {return}
	plan := workspace_delete_plan(app, workspace)
	if !workspace_delete_plan_same(plan, presented) {
		workspace_delete_request(app, w, workspace)
		return
	}
	if !workspace_delete_commit(app, plan) {
		notify(app, .Error, "Could not prepare the replacement. The workspace was preserved.")
	}
}
