package main

import "aio:layout"
import "core:log"
import "core:strings"

Tab_Record_Error :: enum {
	None,
	Allocation,
	Capacity,
}

// A caller may only create a session or separate a pane after this succeeds, so a capacity
// failure must leave the session registry and source layout untouched.
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

// Capacity was reserved, so the append cannot leave a half-built record in the strip.
tab_record_commit :: proc(app: ^App, workspace: ^Workspace, tab: ^Tab) {
	workspace.next_tab_id += 1
	tab.id = workspace.next_tab_id
	tab_update_title(app, tab)
	append(&workspace.tabs, tab)
}

// Preview tabs borrow their source pane's runtime, so freeing a record never closes sessions.
tab_record_free :: proc(tab: ^Tab) {
	layout.destroy(&tab.tree)
	delete(tab.title)
	delete(tab.name)
	free(tab)
}

// One rule for construction and later refreshes: the tab's own name, else its content's title.
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
