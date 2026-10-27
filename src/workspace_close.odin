package main

// Group closes and pane transfers finish using the source before retiring its last tab's workspace.
workspace_close_empty :: proc(app: ^App, workspace: ^Workspace, replace_window := true) {
	if workspace == nil || workspace.provisional || len(workspace.tabs) != 0 {return}
	owner := window_for_workspace(app, workspace)
	if owner != nil {
		destination := replace_window ? workspace_delete_destination(app, workspace) : nil
		if !replace_window {
			window_close(app, owner)
		} else if destination != nil {
			if !workspace_select(app, owner, destination) {
				notify(app, .Error, "Could not display the remaining workspace. Reopen it from the tray.")
				window_close(app, owner)
			}
		} else {
			for candidate in app.workspaces {
				if candidate == workspace || !workspace_eligible(app, candidate) {continue}
				if other := window_for_workspace(app, candidate); other != nil {
					if !window_activate(app, other) {
						notify(app, .Error, "Could not focus the remaining workspace window.")
					}
					break
				}
			}
			window_close(app, owner)
		}
		if window_for_workspace(app, workspace) != nil {return}
	}
	workspace_delete_release(app, workspace)
	workspace_pickers_refresh(app)
	mark_all_dirty(app)
	for candidate in app.workspaces {if workspace_eligible(app, candidate) {return}}
	app.running = false
}
