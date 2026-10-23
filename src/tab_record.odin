package main

import "aio:layout"
import "core:log"
import "core:strings"

Tab_Record_Error :: enum {
	None,
	Allocation,
	Capacity,
}

// Reserving is a step of its own because a producer may only create a session or separate a pane
// once capacity is certain; a capacity failure must leave the session registry and source layout
// untouched. The returned record is not yet part of the workspace.
@(require_results)
tab_record_reserve :: proc(workspace: ^Workspace) -> (^Tab, Tab_Record_Error) {
	tab, err := new(Tab)
	if err != nil {return nil, .Allocation}
	if reserve(&workspace.tabs, len(workspace.tabs) + 1) != nil {
		free(tab)
		return nil, .Capacity
	}
	return tab, .None
}

// Numbers the record from its workspace counter, derives its title and appends it. Reserved
// capacity makes the append infallible, so a committed record is never half in the strip.
tab_record_commit :: proc(app: ^App, workspace: ^Workspace, tab: ^Tab) {
	workspace.next_tab_id += 1
	tab.id = workspace.next_tab_id
	tab_update_title(app, tab)
	append(&workspace.tabs, tab)
}

// The one free order, for committed and partially built records alike. It never closes sessions:
// a preview tab borrows its source pane's runtime.
tab_record_free :: proc(tab: ^Tab) {
	layout.destroy(&tab.tree)
	delete(tab.title)
	delete(tab.name)
	free(tab)
}

// A tab shows its own name, else the title of its focused content. Settings has no session, so it
// names itself; deriving it here keeps construction and later refreshes on the same rule.
@(private)
tab_update_title :: proc(app: ^App, tab: ^Tab) {
	pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	title: string
	if pane.content.kind == .Settings {
		title = "Settings"
	} else if entry := session_find(app, pane.content.id); entry != nil {
		title = entry.name != "" ? entry.name : pane_header_title(&entry.header)
	}
	if tab.name != "" {title = tab.name}
	owned, err := strings.clone(title)
	if err != nil {log.error("copying the tab title failed"); return}
	delete(tab.title)
	tab.title = owned
}
