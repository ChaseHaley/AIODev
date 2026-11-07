package main

import "aio:input"
import "aio:layout"

// A pane torn off into a window of its own; tear_off_window.odin owns the preview window and thumbnail.

@(private)
pane_window_source_allows :: proc(workspace: ^Workspace) -> bool {
	if workspace == nil {return false}
	walk := workspace_panes(nil, workspace)
	count := 0
	for _, ok := workspace_pane_next(&walk); ok; _, ok = workspace_pane_next(&walk) {
		count += 1
		if count > 1 {return true}
	}
	return false
}

// The pane at `node` of `source`, where it really lives, and whether it can leave for a window of its
// own: its workspace keeps content, and its tab keeps a pane it can show when the pane is not already
// linked.
@(private = "file", require_results)
pane_window_source :: proc(
	app: ^App,
	source: ^Tab,
	node: layout.Node_Id,
) -> (
	home: Pane_Link_Home,
	pane: Workspace_Pane,
	ok: bool,
) {
	linked, found: bool
	home, linked, found = pane_link_origin(app, source, node)
	if !found || !pane_window_source_allows(home.workspace) {return}
	if !linked && !pane_link_tab_can_lose(home.tab) {return}
	pane, ok = workspace_pane_at(app, home.workspace, tab_index_by_id(home.workspace, home.tab.id), home.node)
	return
}

@(require_results)
pane_window_source_can_lose :: proc(app: ^App, source: ^Tab, node: layout.Node_Id) -> bool {
	_, _, ok := pane_window_source(app, source, node)
	return ok
}

// Prepares the hidden destination window of a tear-off, proving the pane fits before the drop.
@(require_results)
pane_window_preview_create :: proc(app: ^App, source: ^Tab, node: layout.Node_Id) -> ^Window {
	home, pane, ok := pane_window_source(app, source, node)
	if !ok {return nil}
	name := home.node == home.tab.tree.root ? home.tab.name : ""
	preview := window_preview_prepare(app, pane.content, name)
	if preview == nil {return nil}
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, notify_failure = false) {
		window_preview_discard(app, preview.id)
		return nil
	}
	return preview
}

pane_drag_thumbnail_sync :: proc(
	app: ^App,
	w: ^Window,
	a: ^Drag_Active,
	carry: ^Pane_Carry,
	shown: bool,
	x, y: i32,
) {
	region: layout.Rect
	for pane in w.panes {if pane.node == carry.node {region = pane.rect; break}}
	drag_thumbnail_sync(app, w, &a.thumbnail, region, shown, x, y)
}

// Moves the pane into the prepared window. Every step that can fail comes first, and the window shows before
// the pane leaves its tab, so a failure leaves the source as it was and the preview still prepared.
@(require_results)
pane_to_window :: proc(
	app: ^App,
	source_window: ^Window,
	source: ^Tab,
	node: layout.Node_Id,
	preview_id: input.Window_Id,
) -> bool {
	preview := window_find(app, preview_id)
	home, pane, ok := pane_window_source(app, source, node)
	if !ok {return false}
	workspace := home.workspace
	if preview == nil ||
	   preview.phase != .Preparing ||
	   !(source_window.workspace == workspace ||
			   window_link_workspace(source_window) == workspace.id) {
		return false
	}
	destination := selected_tab(preview.workspace)
	if destination == nil ||
	   destination.tree.nodes[destination.tree.root].(layout.Pane).content !=
		   pane.content {return false}
	layout_pane := home.tab.tree.nodes[home.node].(layout.Pane)
	area := window_content_area(app, preview)
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = area}}
	if !pane_minimum_allows(app, preview, panes[:], nil, notify_failure = true) {return false}
	name := workspace_default_name(app)
	if name == "" {return false}
	// The preview is still Preparing here, so the move leaves only the windows that were live.
	move := pane_move_begin(app, preview, home.tab, home.node)
	if !tear_off_window_show(app, preview, name) {
		pane_move_enter(app, move)
		return false
	}
	// The node was checked to be a pane above, which is all a removal needs.
	removed := layout.remove(&home.tab.tree, home.node)
	assert(removed)
	// A pane that leaves its slot joins an ordinary window, where it must be shown.
	layout.pane_adopt(&destination.tree, layout_pane)
	window_preview_publish(preview, name)
	workspace_mutation_finish(app, preview.workspace, {.Names})
	pane_move_finish(app, move, destination)
	_ = window_activate(app, preview)
	return true
}
