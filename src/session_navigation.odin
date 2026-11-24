package main

import "core:fmt"
import "aio:layout"

// Finding and showing a pane wherever it is. Status lists and notices and notification clicks name panes
// by session, or by a Neovim pane's status id (WORK-548); pane history names them by content.

// Finds the owning pane, never a tear-off preview borrowing the same session runtime. An id no session
// has may be a Neovim pane's status entry, found as the pane that shows that Neovim.
session_pane_find :: proc(app: ^App, id: u32) -> (^Workspace, Workspace_Pane, bool) {
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if pane, found := workspace_first_session(app, workspace, id); found {return workspace, pane, true}
	}
	for neovim in app.neovim_panes {
		if neovim.status.id == id {return content_pane_find(app, {.Neovim, neovim.id})}
	}
	return nil, {}, false
}

// The pane showing `content` in the first workspace that has it, never a tear-off preview.
content_pane_find :: proc(app: ^App, content: layout.Content) -> (^Workspace, Workspace_Pane, bool) {
	for workspace in app.workspaces {
		if workspace.provisional {continue}
		if pane, found := workspace_content_pane(app, workspace, content); found {return workspace, pane, true}
	}
	return nil, {}, false
}

// The pane showing `content` in `workspace`.
workspace_content_pane :: proc(
	app: ^App,
	workspace: ^Workspace,
	content: layout.Content,
) -> (Workspace_Pane, bool) {
	for tab, index in workspace.tabs {
		node := layout.find_content(&tab.tree, content)
		if node != layout.INVALID_NODE {return workspace_pane_at(app, workspace, index, node)}
	}
	return {}, false
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

// Shows the session's pane, as pane_show does.
session_show :: proc(app: ^App, w: ^Window, session: u32) -> bool {
	workspace, pane, _ := session_pane_find(app, session)
	return pane_show(app, w, workspace, pane)
}

// Shows `pane` of `workspace`, switching workspace, tab and focus as needed. A tiled pane is shown
// uncovered: the tab's shown floats are minimized; a floating pane comes out of its capsule to the top.
// Looking at the pane acknowledges its finished program status, as focusing it does, and the jump list
// follows the window that now holds the pane. A nil workspace is a pane that was not found; a failed
// reveal reports why.
pane_show :: proc(app: ^App, w: ^Window, workspace: ^Workspace, pane: Workspace_Pane) -> bool {
	if workspace != nil && workspace_eligible(app, workspace) && workspace_select(app, w, workspace) {
		if owner := window_for_workspace(app, workspace); owner != nil {
			if owner.workspace.selected != pane.tab {tab_select(app, owner, pane.tab)}
			pane_focus(app, owner, pane.node)
			tree := window_tree(owner)
			// Focus is now on the pane, unless it shows in its own linked window.
			if shown, _ := layout.float_counts(tree); shown > 0 && tree.focus == pane.node &&
			   !layout.is_floating(tree, pane.node) {
				floating_minimize_all(app, owner, true)
			}
			focus_jumps_follow(app, owner, pane.content)
			status_focus_enter(app, owner)
			owner.dirty = true
			return true
		}
	}
	notify(app, .Error, "Could not show that pane.")
	return false
}
