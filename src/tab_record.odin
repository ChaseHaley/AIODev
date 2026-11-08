package main

import "aio:layout"
import "core:fmt"
import "core:log"
import "core:strings"

// A caller may only create a session or separate a pane after this succeeds, so a failure must
// leave the session registry and source layout untouched.
@(require_results)
tab_record_reserve :: proc(workspace: ^Workspace) -> (^Tab, bool) {
	tab, err := new(Tab)
	if err != nil {return nil, false}
	if reserve(&workspace.tabs, len(workspace.tabs) + 1) != nil {
		free(tab)
		return nil, false
	}
	return tab, true
}

// Capacity was reserved, so the insert cannot leave a half-built record in the rail.
tab_record_commit :: proc(app: ^App, workspace: ^Workspace, tab: ^Tab, at := -1) {
	workspace.next_tab_id += 1
	tab.id = workspace.next_tab_id
	tab_update_title(app, tab)
	if at < 0 {
		append(&workspace.tabs, tab)
	} else {
		inject_at(&workspace.tabs, at, tab)
	}
}

// Preview tabs borrow their source pane's runtime, so freeing a record never closes sessions.
tab_record_free :: proc(tab: ^Tab) {
	layout.destroy(&tab.tree)
	documents_destroy(&tab.documents)
	delete(tab.title)
	delete(tab.name)
	free(tab)
}

// The selected position after the tab at `from` moves to `to`.
tab_selected_after_move :: proc(selected, from, to: int) -> int {
	switch {
	case selected == from:
		return to
	case from < selected && selected <= to:
		return selected - 1
	case to <= selected && selected < from:
		return selected + 1
	}
	return selected
}

// The selected position after `index` closes, clamped to the `count` tabs that remain.
tab_selected_after_remove :: proc(selected, index, count: int) -> int {
	shifted := index < selected ? selected - 1 : selected
	return clamp(shifted, 0, max(0, count - 1))
}

// What the strip, rail and status crumbs call a tab: its title, else `Tab N` for its 1-based ordinal.
tab_display_title :: proc(tab: ^Tab, ordinal: int) -> string {
	return tab.title != "" ? tab.title : fmt.tprintf("Tab %d", ordinal)
}

// One rule for construction and later refreshes: the tab's own name, else its content's title.
@(private)
tab_update_title :: proc(app: ^App, tab: ^Tab) {
	content, _ := layout.focused_content(&tab.tree)
	title := content_pane_title(app, workspace_session_for_content(app, content), content)
	if tab.name != "" {title = tab.name}
	owned, err := strings.clone(title)
	if err != nil {log.error("copying the tab title failed"); return}
	delete(tab.title)
	tab.title = owned
}
