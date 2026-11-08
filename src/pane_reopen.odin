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
	// It was in a linked window, so it returns there when its neighbours still are.
	linked: bool,
	// It floated above its tab, so it returns floating at the same place.
	float:  []Saved_Float `json:"float,omitempty"`,
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
	for _, id in tab.tree.nodes {
		content, is_pane := layout.pane_content(&tab.tree, layout.Node_Id(id))
		if is_pane {terminal ||= pane_owns_session(content.kind)}
	}
	if !terminal {return}
	saved, encoded := layout_tab_encode(app, tab, pane_processes(app))
	if !encoded {return}
	closed_push(app, {workspace = workspace.id}, {index = index, tab = saved})
}

// Remembers a pane before it closes; a tab's only pane is remembered as the tab.
closed_record_pane :: proc(app: ^App, workspace: ^Workspace, tab_index: int, node: layout.Node_Id) {
	if tab_index < 0 || tab_index >= len(workspace.tabs) {return}
	tab := workspace.tabs[tab_index]
	content, is_pane := layout.pane_content(&tab.tree, node)
	if !is_pane || !pane_owns_session(content.kind) {return}
	sibling, axis, before, share, split := layout.placement(&tab.tree, node)
	if !split {
		closed_record_tab(app, workspace, tab_index)
		return
	}
	beside := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(&tab.tree, sibling, &beside)
	nodes := []Saved_Node{layout_pane_encode(app, content, pane_processes(app))}
	floating, is_floating := layout.float_of(&tab.tree, node)
	record := Closed_Record {
		tab    = {nodes = nodes},
		beside = beside[:],
		axis   = axis,
		before = before,
		share  = share,
		linked = layout.link_root(&tab.tree, node) != layout.INVALID_NODE,
		float  = layout_float_encode(is_floating, floating),
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
	tab_show(app, w, to)
}

// Returns the pane beside the panes it was split from when they are still together; otherwise
// beside one of them, or beside the focused pane.
@(private)
closed_reopen_pane :: proc(app: ^App, w: ^Window, tab_index: int, record: ^Closed_Record) {
	tab := w.workspace.tabs[tab_index]
	if len(record.float) == 1 {
		closed_reopen_floating(app, w, tab_index, record)
		return
	}
	target := layout.find_group(&tab.tree, record.beside)
	for content in record.beside {
		if target != layout.INVALID_NODE {break}
		target = layout.find_content(&tab.tree, content)
	}
	if target == layout.INVALID_NODE {target = tab.tree.focus}
	if record.linked && layout.link_root(&tab.tree, target) != layout.INVALID_NODE {
		closed_reopen_linked(app, w, tab_index, target, record)
		return
	}
	if !closed_fits(app, w, &tab.tree, target, record) {return}
	added, placed := closed_pane_restore(app, &tab.tree, target, record)
	if !placed {return}
	if w.workspace.selected != tab_index {tab_select(app, w, tab_index)}
	pane_focus(app, w, added)
	tab_update_title(app, tab)
	window_relayout(app, w)
}

@(private)
closed_reopen_floating :: proc(app: ^App, w: ^Window, tab_index: int, record: ^Closed_Record) {
	tab := w.workspace.tabs[tab_index]
	bounds := layout_float_decode(record.float[0]).bounds
	node, placed := closed_pane_restore(app, &tab.tree, bounds, record)
	if !placed {return}
	if w.workspace.selected != tab_index {tab_select(app, w, tab_index)}
	pane_focus(app, w, node)
	tab_update_title(app, tab)
	window_floats_layout(app, w)
}

// The pane's neighbours are in a linked window, so it goes back among them there: its size is checked in
// that window, and it joins their slot in the tab's tree.
@(private)
closed_reopen_linked :: proc(
	app: ^App,
	w: ^Window,
	tab_index: int,
	home_target: layout.Node_Id,
	record: ^Closed_Record,
) {
	tree := &w.workspace.tabs[tab_index].tree
	group := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(tree, home_target, &group)
	linked := pane_link_window_of(app, group[0])
	if linked == nil {return}
	if !pane_link_reconcile(app, linked) {return}
	shown := window_tree(linked)
	target := layout.find_group(shown, group[:])
	if target == layout.INVALID_NODE {target = layout.find_content(shown, group[0])}
	if !closed_fits(app, linked, shown, target, record) {return}
	// The reconcile may have rebuilt the slot, so the neighbours are found there again.
	home := layout.find_group(tree, group[:])
	if home == layout.INVALID_NODE {home = layout.find_content(tree, group[0])}
	added, placed := closed_pane_restore(app, tree, home, record, join_slot = true)
	if !placed {return}
	content, _ := layout.pane_content(tree, added)
	if w.workspace.selected != tab_index {tab_select(app, w, tab_index)}
	pane_link_joined(app, linked, content, focus = true)
	pane_link_activate(linked)
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
	trial, copy_error := layout.clone(tree, context.temp_allocator)
	if copy_error != nil {notify(app, .Error, "Could not check the reopened pane's size."); return false}
	defer layout.destroy(&trial)
	added, placed := closed_place(&trial, target, record, PANE_MEASUREMENT_CONTENT, false)
	if !placed {notify(app, .Error, "Could not check the reopened pane's size."); return false}
	return pane_trial_evaluate(app, w, tree, &trial, added, true).error == .None
}

// Where a reopened pane goes in its tree: beside a tiled pane, or floating within its saved bounds.
@(private)
Closed_Place :: union {
	layout.Node_Id,
	layout.Rect,
}

// Opens the closed pane's session and places it, closing the session again when it cannot be placed.
// Tiled, floating and linked reopening differ only in where it goes and what they refresh afterwards;
// `join_slot` puts it in the linked slot its neighbours are in.
@(private, require_results)
closed_pane_restore :: proc(
	app: ^App,
	tree: ^layout.Layout,
	place: Closed_Place,
	record: ^Closed_Record,
	join_slot := false,
) -> (
	layout.Node_Id,
	bool,
) {
	if id, restored := layout_session_restore(app, &record.tab.nodes[0]); restored {
		node, placed := closed_place(tree, place, record, {.Terminal, id}, join_slot)
		if placed {return node, true}
		session_close(app, id)
	}
	notify(app, .Error, "Could not reopen the pane.")
	return layout.INVALID_NODE, false
}

@(private, require_results)
closed_place :: proc(
	tree: ^layout.Layout,
	place: Closed_Place,
	record: ^Closed_Record,
	content: layout.Content,
	join_slot: bool,
) -> (
	layout.Node_Id,
	bool,
) {
	switch at in place {
	case layout.Node_Id:
		node, err := layout.insert_beside(
			tree, at, record.axis, record.before, record.share, content, join_slot,
		)
		return node, err == nil
	case layout.Rect:
		node, err := layout.float_new(tree, content, at)
		return node, err == nil
	}
	return layout.INVALID_NODE, false
}
