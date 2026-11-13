package main

import "core:fmt"
import "aio:layout"

// Finding and showing the pane a session runs in, wherever it is. Status lists and notices, focus
// jumps and notification clicks name panes by session.

// Finds the owning pane, never a tear-off preview borrowing the same session runtime.
session_pane_find :: proc(app: ^App, id: u32) -> (^Workspace, Workspace_Pane, bool) {
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if pane, found := workspace_first_session(app, workspace, id); found {return workspace, pane, true}
	}
	return nil, {}, false
}

// Where a session lives, for lists and notices that must say which pane they mean. The pane is
// named only when its tab is split.
session_location_at :: proc(workspace: ^Workspace, tab: int, entry: ^Session_Entry) -> string {
	title := tab_display_title(workspace.tabs[tab], tab + 1)
	if tab_pane_count(workspace.tabs[tab]) > 1 {
		return fmt.tprintf("%s › %s › %s", workspace.name, title, session_display_title(entry))
	}
	return fmt.tprintf("%s › %s", workspace.name, title)
}

// session_location_at for the first workspace holding the session; its title when none does.
session_location :: proc(app: ^App, entry: ^Session_Entry) -> string {
	if workspace, pane, found := session_pane_find(app, entry.id); found {
		return session_location_at(workspace, pane.tab, entry)
	}
	return session_display_title(entry)
}

session_workspace :: proc(app: ^App, session: u32) -> ^Workspace {
	workspace, _, _ := session_pane_find(app, session)
	return workspace
}

// The window showing the session's workspace, or `fallback` when none does.
session_window :: proc(app: ^App, session: u32, fallback: ^Window) -> ^Window {
	if owner := window_for_workspace(app, session_workspace(app, session)); owner != nil {return owner}
	return fallback
}

// Shows the session's pane, switching workspace, tab and focus as needed. A tiled pane is shown
// uncovered: the tab's shown floats are minimized; a floating pane comes out of its capsule to the top.
// Looking at the pane acknowledges its finished program status, as focusing it does; a failed reveal
// reports why.
session_show :: proc(app: ^App, w: ^Window, session: u32) -> bool {
	workspace, pane, found := session_pane_find(app, session)
	if found && workspace_eligible(app, workspace) && workspace_select(app, w, workspace) {
		if owner := window_for_workspace(app, workspace); owner != nil {
			if owner.workspace.selected != pane.tab {tab_select(app, owner, pane.tab)}
			pane_focus(app, owner, pane.node)
			tree := window_tree(owner)
			// Focus is now on the pane, unless it shows in its own linked window.
			if shown, _ := layout.float_counts(tree); shown > 0 && tree.focus == pane.node &&
			   !layout.is_floating(tree, pane.node) {
				floating_minimize_all(app, owner, true)
			}
			status_focus_enter(app, owner)
			owner.dirty = true
			return true
		}
	}
	notify(app, .Error, "Could not show that pane.")
	return false
}
