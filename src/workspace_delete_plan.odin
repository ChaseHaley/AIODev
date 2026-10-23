package main

import "aio:platform"

// One workspace deletion: the subject that must still be live when it is accepted, the window
// that must receive a replacement before the old workspace is discarded (D-051), the destination
// it should display, and what the commit must create. Request shows it, accept revalidates its
// identity and commit consumes it, so the rule has one home (D-053).
Workspace_Delete_Plan :: struct {
	workspace:   u32,
	owner:       platform.Window_Id,
	destination: u32,
	fresh:       bool,
	created_tab: bool,
}

// Derives the subject, owner, destination, fresh replacement and first-tab need from live state.
// No allocation, so accept can revalidate without a failure path.
@(require_results)
workspace_delete_plan :: proc(app: ^App, workspace: ^Workspace) -> Workspace_Delete_Plan {
	plan: Workspace_Delete_Plan
	if workspace == nil {return plan}
	plan.workspace = workspace.id
	if owner := window_for_workspace(app, workspace); owner != nil {
		plan.owner = owner.id
		if destination := workspace_delete_destination(app, workspace); destination != nil {
			plan.destination = destination.id
			plan.created_tab = len(destination.tabs) == 0
		} else {
			plan.fresh = true
		}
	} else {
		// A hidden workspace has nobody to replace. Only the last workspace still needs a fresh
		// one, so the shared set never becomes empty (D-053).
		plan.fresh = len(app.workspaces) == 1
	}
	plan.created_tab = plan.created_tab || plan.fresh
	return plan
}

// Reports whether the live plan still names the subject, owner and destination the question
// showed. Counts, names, freshness and the first-tab need may change while it stays open.
@(require_results)
workspace_delete_plan_same :: proc(a, b: Workspace_Delete_Plan) -> bool {
	return a.workspace == b.workspace && a.owner == b.owner && a.destination == b.destination
}

// Finds the first eligible workspace after the subject that no window displays, so the replaced
// owner receives work instead of an empty surface. The workspace list order decides.
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
