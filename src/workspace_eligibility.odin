package main

// A picker row, selection or deletion may act on a workspace only after its record is live, it
// has stopped borrowing a preview runtime and its owning window has finished preparing.
@(require_results)
workspace_eligible :: proc(app: ^App, workspace: ^Workspace) -> bool {
	if !workspace_registered(app, workspace) || workspace.provisional {return false}
	owner := window_for_workspace(app, workspace)
	return owner == nil || !owner.preparing
}

// Editing stored workspace data is not a display action, so it needs only the live record.
@(require_results)
workspace_registered :: proc(app: ^App, workspace: ^Workspace) -> bool {
	return workspace != nil && workspace_find(app, workspace.id) == workspace
}
