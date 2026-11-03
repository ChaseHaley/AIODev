package main

import "aio:layout"
import "core:encoding/json"
import "core:log"

// Recently closed panes and tabs, so Reopen Closed brings the newest back as fresh shells in
// their last directories, with their names and a note of what they were running. Closes and
// shells that exit are kept; moves are not.
CLOSED_LIMIT :: 20

Closed_Item :: struct {
	// The workspace it was closed from, and for a pane the tab it left (zero for a whole tab).
	workspace, tab: u32,
	// The encoded Closed_Record.
	text:           string,
}

Closed_Record :: struct {
	// A whole tab and its position, or a tab holding just the closed pane.
	index:  int,
	tab:    Saved_Tab,
	// For a pane: the panes it was split from, and how it sat against them.
	beside: []layout.Content,
	axis:   layout.Axis,
	before: bool,
	share:  f32,
}

closed_destroy :: proc(app: ^App) {
	for item in app.closed {delete(item.text)}
	delete(app.closed)
	app.closed = nil
}

// Remembers the tab at `index` before it closes. Tabs without a terminal are not kept.
closed_record_tab :: proc(app: ^App, workspace: ^Workspace, index: int) {
	if index < 0 || index >= len(workspace.tabs) {return}
	tab := workspace.tabs[index]
	terminal := false
	for node in tab.tree.nodes {
		pane := node.(layout.Pane) or_continue
		terminal ||= pane.content.kind == .Terminal
	}
	if !terminal {return}
	nodes := make([dynamic]Saved_Node, 0, len(tab.tree.nodes), context.temp_allocator)
	focus := 0
	if layout_node_encode(app, &tab.tree, tab.tree.root, &nodes, &focus, pane_processes(app)) < 0 {return}
	saved := Saved_Tab {
		name   = tab.name,
		focus  = focus,
		zoomed = tab.tree.zoomed,
		nodes  = nodes[:],
	}
	closed_push(app, {workspace = workspace.id}, {index = index, tab = saved})
}

// Remembers a pane before it closes; a tab's only pane is remembered as the tab.
closed_record_pane :: proc(app: ^App, workspace: ^Workspace, tab_index: int, node: layout.Node_Id) {
	if tab_index < 0 || tab_index >= len(workspace.tabs) {return}
	tab := workspace.tabs[tab_index]
	if int(node) >= len(tab.tree.nodes) {return}
	pane, is_pane := tab.tree.nodes[node].(layout.Pane)
	if !is_pane || pane.content.kind != .Terminal {return}
	sibling, axis, before, share, split := layout.placement(&tab.tree, node)
	if !split {
		closed_record_tab(app, workspace, tab_index)
		return
	}
	beside := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(&tab.tree, sibling, &beside)
	nodes := []Saved_Node{layout_pane_encode(app, pane.content, pane_processes(app))}
	record := Closed_Record {
		tab    = {nodes = nodes},
		beside = beside[:],
		axis   = axis,
		before = before,
		share  = share,
	}
	closed_push(app, {workspace = workspace.id, tab = tab.id}, record)
}

@(private)
closed_push :: proc(app: ^App, item: Closed_Item, record: Closed_Record) {
	data, err := json.marshal(record, {use_enum_names = true})
	if err != nil {log.errorf("remembering the closed pane failed: %v", err); return}
	if len(app.closed) >= CLOSED_LIMIT {
		delete(app.closed[0].text)
		ordered_remove(&app.closed, 0)
	}
	kept := item
	kept.text = string(data)
	if _, append_error := append(&app.closed, kept); append_error != nil {
		delete(data)
		log.error("remembering the closed pane failed")
	}
}

// Reopens the newest pane or tab closed from this window's workspace, or from one since deleted.
closed_reopen :: proc(app: ^App, w: ^Window) {
	index := -1
	for i := len(app.closed) - 1; i >= 0; i -= 1 {
		workspace := app.closed[i].workspace
		if workspace == w.workspace.id || workspace_find(app, workspace) == nil {index = i; break}
	}
	if index < 0 {
		notify(app, .Info, "No closed panes or tabs to reopen.")
		return
	}
	item := app.closed[index]
	ordered_remove(&app.closed, index)
	defer delete(item.text)
	record: Closed_Record
	decode_error := json.unmarshal(transmute([]u8)item.text, &record, allocator = context.temp_allocator)
	if decode_error != nil || len(record.tab.nodes) == 0 {
		log.errorf("reading the closed pane failed: %v", decode_error)
		notify(app, .Error, "Could not reopen the pane.")
		return
	}
	if item.tab != 0 {
		if tab := tab_index_by_id(w.workspace, item.tab); tab >= 0 {
			closed_reopen_pane(app, w, tab, &record)
			return
		}
		// The tab it left is gone, so the pane comes back as a tab of its own at the end.
		record.index = len(w.workspace.tabs)
	}
	closed_reopen_tab(app, w, &record)
}

@(private)
closed_reopen_tab :: proc(app: ^App, w: ^Window, record: ^Closed_Record) {
	if !pane_minimum_single(app, w) {return}
	if !layout_tab_restore(app, w.workspace, &record.tab) {
		notify(app, .Error, "Could not reopen the tab.")
		return
	}
	last := len(w.workspace.tabs) - 1
	to := clamp(record.index, 0, last)
	tab_move(app, w, last, to)
	tab_select(app, w, to)
	rail_overlay_dismiss(app, w)
}

// Returns the pane beside the panes it was split from when they are still together; otherwise
// beside one of them, or beside the focused pane.
@(private)
closed_reopen_pane :: proc(app: ^App, w: ^Window, tab_index: int, record: ^Closed_Record) {
	tab := w.workspace.tabs[tab_index]
	target := layout.find_group(&tab.tree, record.beside)
	for content in record.beside {
		if target != layout.INVALID_NODE {break}
		for node, i in tab.tree.nodes {
			pane := node.(layout.Pane) or_continue
			if pane.content == content {target = layout.Node_Id(i); break}
		}
	}
	if target == layout.INVALID_NODE {target = tab.tree.focus}
	if !closed_fits(app, w, &tab.tree, target, record) {return}
	if !layout_session_restore(app, &record.tab.nodes[0]) {
		notify(app, .Error, "Could not reopen the pane.")
		return
	}
	id := app.next_session_id
	added, err := layout.insert_beside(
		&tab.tree,
		target,
		record.axis,
		record.before,
		record.share,
		{.Terminal, id},
	)
	if err != nil {
		session_close(app, id)
		notify(app, .Error, "Could not reopen the pane.")
		return
	}
	if w.workspace.selected != tab_index {tab_select(app, w, tab_index)}
	pane_focus(app, w, added)
	tab_update_title(app, tab)
	window_relayout(app, w)
}

// Whether the reopened pane and its neighbours keep the minimum pane size.
@(private)
closed_fits :: proc(
	app: ^App,
	w: ^Window,
	tree: ^layout.Layout,
	target: layout.Node_Id,
	record: ^Closed_Record,
) -> bool {
	trial, copied := pane_trial_copy(tree, context.temp_allocator)
	if !copied {notify(app, .Error, "Could not check the reopened pane's size."); return false}
	defer layout.destroy(&trial)
	added, err := layout.insert_beside(
		&trial,
		target,
		record.axis,
		record.before,
		record.share,
		{.Terminal, app.next_session_id + 1},
	)
	if err != nil {notify(app, .Error, "Could not check the reopened pane's size."); return false}
	return pane_trial_evaluate(app, w, tree, &trial, added, true).error == .None
}
