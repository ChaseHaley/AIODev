package main

import "core:fmt"

// Finding and showing the pane a session runs in, wherever it is. Status lists and notices, focus
// jumps and notification clicks name panes by session.

// A tab's title, or its position when the user has not named it.
tab_display_title :: proc(workspace: ^Workspace, tab: int) -> string {
	if tab < len(workspace.tabs) && workspace.tabs[tab].title != "" {return workspace.tabs[tab].title}
	return fmt.tprintf("Tab %d", tab + 1)
}

// The name the user gave the session, else its header's title.
session_title :: proc(entry: ^Session_Entry) -> string {
	return entry.name != "" ? entry.name : pane_header_title(&entry.header)
}

// Where a session lives, for lists and notices that must say which pane they mean. The pane is
// named only when its tab is split.
session_location_at :: proc(workspace: ^Workspace, tab: int, entry: ^Session_Entry) -> string {
	title := tab_display_title(workspace, tab)
	if tab_pane_count(workspace.tabs[tab]) > 1 {
		return fmt.tprintf("%s › %s › %s", workspace.name, title, session_title(entry))
	}
	return fmt.tprintf("%s › %s", workspace.name, title)
}

// session_location_at for the first workspace holding the session; its title when none does.
session_location :: proc(app: ^App, entry: ^Session_Entry) -> string {
	for workspace in app.workspaces {
		if pane, ok := workspace_first_session(app, workspace, entry.id); ok {
			return session_location_at(workspace, pane.tab, entry)
		}
	}
	return session_title(entry)
}

session_workspace :: proc(app: ^App, session: u32) -> ^Workspace {
	for workspace in app.workspaces {
		if _, ok := workspace_first_session(app, workspace, session); ok {return workspace}
	}
	return nil
}

// The window showing the session's workspace, or `fallback` when none does.
session_window :: proc(app: ^App, session: u32, fallback: ^Window) -> ^Window {
	if owner := window_for_workspace(app, session_workspace(app, session)); owner != nil {return owner}
	return fallback
}

// Shows the session's pane, switching workspace, tab and focus as needed. Looking at the pane
// acknowledges its finished program status, as focusing it does.
session_reveal :: proc(app: ^App, w: ^Window, session: u32) -> bool {
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		pane, ok := workspace_first_session(app, workspace, session)
		if !ok {continue}
		if !workspace_select(app, w, workspace) {return false}
		owner := window_for_workspace(app, workspace)
		if owner == nil {return false}
		if owner.workspace.selected != pane.tab {tab_select(app, owner, pane.tab)}
		pane_focus(app, owner, pane.node)
		status_focus_enter(app, owner)
		owner.dirty = true
		return true
	}
	return false
}

// session_reveal, telling the user when the pane could not be shown.
session_show :: proc(app: ^App, w: ^Window, session: u32) -> bool {
	if session_reveal(app, w, session) {return true}
	notify(app, .Error, "Could not show that pane.")
	return false
}
