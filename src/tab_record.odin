package main

import "aio:events"
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
	// Only listed workspaces announce tabs: a tear-off preview announces its tabs once published, and
	// a linked window's private view (id 0) shows a pane whose tab was announced where it lives.
	if !workspace.provisional && workspace.id != 0 {
		events.push(&app.events, .Tab_Created, Event_Tab{tab.id, workspace.id})
		app_events_panes_attached(app)
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
	return tab_title_or_ordinal(tab.title, ordinal)
}

// What tab_display_title calls the tab while `content` is its focused pane, as a label turning away from that
// pane shows (WORK-483).
tab_display_title_with :: proc(app: ^App, tab: ^Tab, content: layout.Content, ordinal: int) -> string {
	return tab_title_or_ordinal(tab_title_of(app, tab, content), ordinal)
}

@(private = "file")
tab_title_or_ordinal :: proc(title: string, ordinal: int) -> string {
	return title != "" ? title : fmt.tprintf("Tab %d", ordinal)
}

// One rule for construction and later refreshes: the tab's own name, else its content's title.
@(private = "file")
tab_title_of :: proc(app: ^App, tab: ^Tab, content: layout.Content) -> string {
	if tab.name != "" {return tab.name}
	return content_pane_title(app, workspace_session_for_content(app, content), content)
}

@(private)
tab_update_title :: proc(app: ^App, tab: ^Tab) {
	content, _ := layout.focused_content(&tab.tree)
	owned, err := strings.clone(tab_title_of(app, tab, content))
	if err != nil {log.error("copying the tab title failed"); return}
	delete(tab.title)
	tab.title = owned
}
