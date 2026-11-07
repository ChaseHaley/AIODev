package main

import "aio:input"
import "aio:layout"

// Moving a pane is one operation in two steps: pane_drop_operation resolves where it goes to the trees
// that own the panes, which pane_trial_operation measures on copies and pane_operation_move then carries
// out, so the outline a drag shows is the move its drop makes. Membership changes only in tabs' own trees:
// a pane in a linked window resolves to its slot in its tab, and a linked destination to the slot it shows.
// Only moves within the tree a window shows, a linked window's copy included, stay in that tree as
// arrangement changes (pane_rearrange). pane_move_finish completes every move that crosses trees. See
// src/pane_links.odin.

// A pane operation resolved to the trees that own the panes: `source` holds the pane at `node` and
// `destination` receives it, the same tab for a move within one tree. A linked destination names the `slot`
// the pane joins, with `target` resolved into its tab's tree; otherwise `slot` is INVALID.
Pane_Operation :: struct {
	place:               Pane_Place,
	source, destination: ^Tab,
	node, target, slot:  layout.Node_Id,
	direction:           layout.Direction,
}

// Carries out `op` on `source` and `destination`, the operation's own trees or copies of them, returning the
// node that then holds the pane. A new tab is not a tree operation and never resolves to one.
@(require_results)
pane_operation_apply :: proc(
	op: Pane_Operation,
	source, destination: ^layout.Layout,
) -> (
	layout.Node_Id,
	bool,
) {
	edge := op.place == .Edge
	within := op.source == op.destination
	linked := op.slot != layout.INVALID_NODE
	switch {
	case op.place == .New_Tab:
		return layout.INVALID_NODE, false
	case op.place == .Swap:
		return op.target, layout.swap(destination, op.node, op.target)
	case linked && within:
		return layout.slot_take_pane(source, op.node, op.slot, op.target, op.direction, edge)
	case linked:
		return layout.transfer_pane_to_slot(source, destination, op.node, op.slot, op.target, op.direction, edge)
	case within && edge:
		return layout.dock_pane(source, op.node, op.direction)
	case within:
		return layout.move_pane(source, op.node, op.target, op.direction)
	}
	return layout.transfer_pane(source, destination, op.node, op.target, op.direction, edge)
}

// Whether a drop from `source_window` into `w` reaches across a linked window, so the panes involved are
// found in their tabs' trees rather than in the trees the windows show.
@(private)
pane_drop_crosses_link :: proc(source_window, w: ^Window) -> bool {
	return w != source_window && (window_linked(source_window) || window_linked(w))
}

// Why the move a drop plans is refused, in the terms its release reports: a move across a linked window keeps
// the pane in its tab, a move to another tab keeps both tabs, and a move within one tree changes nothing.
@(require_results)
pane_drop_refusal :: proc(source_window: ^Window, source: ^Tab, w: ^Window, drop: Pane_Drop) -> Drop_Fit {
	if pane_drop_crosses_link(source_window, w) {return .Refused_Source_Kept}
	if drop.tab != source {return .Refused_Tabs_Kept}
	return .Refused
}

// Resolves dropping the pane at `node` of `source`, the tab `source_window` shows, on `drop` in `w`. Fails
// for a drop the move would refuse, so the trial and the release refuse the same drops.
@(require_results)
pane_drop_operation :: proc(
	app: ^App,
	source_window: ^Window,
	source: ^Tab,
	node: layout.Node_Id,
	w: ^Window,
	drop: Pane_Drop,
) -> (
	Pane_Operation,
	bool,
) {
	if drop.place == .New_Tab || source == nil || int(node) >= len(source.tree.nodes) {return {}, false}
	pane, is_pane := source.tree.nodes[node].(layout.Pane)
	if !is_pane {return {}, false}
	op := Pane_Operation {
		place     = drop.place,
		node      = node,
		target    = drop.target,
		slot      = layout.INVALID_NODE,
		direction = drop.direction,
	}
	if !pane_drop_crosses_link(source_window, w) {
		if drop.tab == source || drop.place == .Swap {
			if drop.tab != source || int(drop.target) >= len(source.tree.nodes) {return {}, false}
			op.source, op.destination = source, source
			return op, true
		}
		return pane_transfer_operation(app, w, source, drop.tab, op)
	}
	if drop.place == .Swap {return {}, false}
	home, source_linked, found := pane_link_origin(app, source, node)
	if !found {return {}, false}
	if !source_linked && !pane_link_tab_can_lose(home.tab) {return {}, false}
	destination_linked := window_linked(w)
	destination := drop.tab
	if destination_linked {
		destination_home, located := pane_link_locate(app, w)
		if !located {return {}, false}
		destination, op.slot = destination_home.tab, destination_home.slot
		if !layout.slot_valid(&destination.tree, op.slot) {return {}, false}
		if op.target != layout.INVALID_NODE {
			if int(op.target) >= len(drop.tab.tree.nodes) {return {}, false}
			target_pane, target_is_pane := drop.tab.tree.nodes[op.target].(layout.Pane)
			if !target_is_pane {return {}, false}
			op.target = layout.find_content(&destination.tree, target_pane.content)
			if op.target == layout.INVALID_NODE && drop.place != .Edge {return {}, false}
		}
	}
	if destination == nil {return {}, false}
	destination_workspace := pane_source_workspace(app, destination)
	if destination_workspace == nil {return {}, false}
	// An unlinked destination window shows the tab it receives, so the tab must be one of its own.
	if !destination_linked && destination_workspace != w.workspace {return {}, false}
	if !pane_content_can_join(pane.content, destination_workspace, home.tab) {return {}, false}
	if destination == home.tab {
		if destination_linked {
			// Two windows of one slot show the same panes; moving between them is no move at all.
			if source_linked && home.slot == op.slot {return {}, false}
		} else if !source_linked {
			return {}, false
		}
	}
	op.source, op.destination, op.node = home.tab, destination, home.node
	return op, true
}

// Resolves moving the pane at op.node of `source` into `destination`, another tab of w's workspace.
@(private, require_results)
pane_transfer_operation :: proc(
	app: ^App,
	w: ^Window,
	source, destination: ^Tab,
	op: Pane_Operation,
) -> (
	Pane_Operation,
	bool,
) {
	if source == nil || destination == nil || source == destination {return {}, false}
	if pane_source_workspace(app, source) == nil || tab_index_by_id(w.workspace, destination.id) < 0 {
		return {}, false
	}
	if int(op.node) >= len(source.tree.nodes) || int(op.target) >= len(destination.tree.nodes) {
		return {}, false
	}
	pane, valid := source.tree.nodes[op.node].(layout.Pane)
	if !valid || !pane_content_can_join(pane.content, w.workspace, source) {return {}, false}
	resolved := op
	resolved.source, resolved.destination = source, destination
	return resolved, true
}

// Carries out a pane drop from `source_window` on `drop` in `w`, as pane_drop_operation resolves it once
// linked windows have settled: settling can rebuild a tree, so the pane and its target are found again by
// what they show.
@(require_results)
pane_drop_commit :: proc(
	app: ^App,
	source_window: ^Window,
	grab: Pane_Grab,
	w: ^Window,
	drop: Pane_Drop,
) -> bool {
	if int(grab.node) >= len(grab.source.tree.nodes) {return false}
	pane, is_pane := grab.source.tree.nodes[grab.node].(layout.Pane)
	if !is_pane {return false}
	if drop.place == .New_Tab {
		if !window_linked(source_window) {return pane_to_tab(app, w, grab.source, grab.node)}
		if window_linked(w) || !pane_link_reconcile(app, source_window) {return false}
		home, linked := pane_link_home(app, pane.content)
		return linked && pane_to_tab(app, w, home.tab, home.node)
	}
	if !pane_drop_crosses_link(source_window, w) {
		if drop.tab != grab.source {
			edge := drop.place == .Edge
			return pane_transfer(app, w, grab.source, drop.tab, grab.node, drop.target, drop.direction, edge)
		}
		op, resolved := pane_drop_operation(app, source_window, grab.source, grab.node, w, drop)
		return resolved && pane_rearrange(app, w, op)
	}
	target := layout.Content{}
	targeted := false
	if int(drop.target) < len(drop.tab.tree.nodes) {
		target_pane: layout.Pane
		target_pane, targeted = drop.tab.tree.nodes[drop.target].(layout.Pane)
		target = target_pane.content
	}
	if window_linked(source_window) && !pane_link_reconcile(app, source_window) {return false}
	if window_linked(w) && !pane_link_reconcile(app, w) {return false}
	settled := drop
	if targeted {settled.target = layout.find_content(&drop.tab.tree, target)}
	node := layout.find_content(&grab.source.tree, pane.content)
	op, resolved := pane_drop_operation(app, source_window, grab.source, node, w, settled)
	return resolved && pane_operation_move(app, w, op)
}

// Rearranges panes within the tree w shows, a linked window's copy included, which pane_links_sync stores in
// its slot. The selection, a divider drag and the wheel referred to the panes as they were, so they end.
pane_rearrange :: proc(app: ^App, w: ^Window, op: Pane_Operation) -> bool {
	tree := window_tree(w)
	if _, changed := pane_operation_apply(op, tree, tree); !changed {return false}
	selection_cancel(w)
	divider_cancel(w)
	w.wheel_remainder = 0
	window_relayout(app, w)
	window_update_title(app, w)
	cursor_blink_reset(w)
	return true
}

// Moves a pane across trees, or from or into a linked slot of its tab's tree, and completes the move in w,
// the window that receives it.
@(require_results)
pane_operation_move :: proc(app: ^App, w: ^Window, op: Pane_Operation) -> bool {
	move := pane_move_begin(app, w, op.source, op.node)
	if _, moved := pane_operation_apply(op, &op.source.tree, &op.destination.tree); !moved {
		pane_move_enter(app, move)
		return false
	}
	pane_move_finish(app, move, op.destination)
	return true
}

// A pane leaving `source` for a tab window `destination` receives: what the move takes focus from and what
// its completion settles. Only the receiving window and the one showing the source tab can be showing either
// tab; a linked window showing the pane shows a copy, which the completion reloads.
@(private)
Pane_Move :: struct {
	source:      ^Tab,
	workspace:   ^Workspace,
	content:     layout.Content,
	destination: input.Window_Id,
	// The window showing the source tab when that is another window, or 0.
	owner:       input.Window_Id,
	// The linked window the pane leaves, or 0.
	linked:      input.Window_Id,
}

// Takes focus from the windows the move changes, before either tree does. A window still being prepared has
// no focus to take.
@(private)
pane_move_begin :: proc(app: ^App, w: ^Window, source: ^Tab, node: layout.Node_Id) -> Pane_Move {
	pane := source.tree.nodes[node].(layout.Pane)
	move := Pane_Move {
		source      = source,
		workspace   = pane_source_workspace(app, source),
		content     = pane.content,
		destination = w.id,
	}
	if layout.link_root(&source.tree, node) != layout.INVALID_NODE {
		if linked := pane_link_window_of(app, pane.content); linked != nil {move.linked = linked.id}
	}
	if w.phase != .Preparing {focus_leave(app, w)}
	owner := window_for_workspace(app, move.workspace)
	if owner != nil && owner != w && owner.phase != .Preparing && selected_tab(owner.workspace) == source {
		move.owner = owner.id
		focus_leave(app, owner)
	}
	return move
}

// Gives focus back to every window the move left that is still open, after a failure or once the
// destination is settled. A window that has entered its new pane already hears nothing again.
@(private)
pane_move_enter :: proc(app: ^App, move: Pane_Move) {
	for id in ([2]input.Window_Id{move.destination, move.owner}) {
		if window := window_find(app, id); window != nil && window.phase != .Preparing {focus_enter(app, window)}
	}
}

// Completes a move into `destination`: the receiving window shows the pane focused, in the tab it now has
// or in its linked slot; the source tab's title and Settings page follow what it still holds, a tab the pane
// left empty closes and a linked window it left shows its slot again; the layout is saved, and the
// workspace it left retires once nothing is left in it.
@(private)
pane_move_finish :: proc(app: ^App, move: Pane_Move, destination: ^Tab) {
	w := window_find(app, move.destination)
	emptied := move.source.tree.root == layout.INVALID_NODE
	if !emptied {tab_update_title(app, move.source)}
	// The moved content may have been Settings, so each side's page follows what it now shows.
	workspace_settings_sync(app, move.workspace)
	destination_workspace := w.workspace
	if window_linked(w) {
		destination_workspace = pane_source_workspace(app, destination)
		pane_link_joined(app, w, move.content, focus = true)
	} else {
		if index := tab_index_by_id(w.workspace, destination.id); index >= 0 {
			tab_select_one(w.workspace, index)
			w.workspace.selected = index
		}
		if node := layout.find_content(&destination.tree, move.content); node != layout.INVALID_NODE {
			destination.tree.focus = node
		}
		window_relayout(app, w)
		focus_enter(app, w)
	}
	if linked := window_find(app, move.linked); linked != nil {
		pane_link_refresh_source(app, linked, move.content)
	}
	// A tab the pane left empty closes, which settles its window; otherwise the window showing it re-enters.
	if emptied {
		for tab, index in move.workspace.tabs {
			if tab == move.source {workspace_close_tab(app, move.workspace, index); break}
		}
	} else if owner := window_for_workspace(app, move.workspace); owner != nil && owner != w {
		window_relayout(app, owner)
		if owner.id == move.owner {focus_enter(app, owner)}
	}
	workspace_mutation_finish(app, destination_workspace, {.Structure})
	// A move has already focused its destination; its exhausted source window can retire.
	workspace_close_empty(app, move.workspace, replace_window = false)
}

pane_focus :: proc(app: ^App, w: ^Window, node: layout.Node_Id) {
	tree := window_tree(w)
	if tree.focus == node || int(node) >= len(tree.nodes) {return}
	// Status, jumps and scripts name a pane wherever it is; a linked one takes focus in its own window.
	pane, is_pane := tree.nodes[node].(layout.Pane)
	if is_pane && layout.link_root(tree, node) != layout.INVALID_NODE {
		if linked := pane_link_window_of(app, pane.content); linked != nil {
			pane_focus(app, linked, layout.find_content(window_tree(linked), pane.content))
			pane_link_activate(linked)
		}
		return
	}
	focus_leave(app, w)
	// A floating pane rises above the others, and comes out of its capsule, as it takes focus.
	floats_changed := layout.focus_set(tree, node)
	if pane_view_solo(w) && !layout.is_floating(tree, node) {
		window_relayout(app, w)
	} else if floats_changed {
		window_floats_layout(app, w)
	}
	focus_enter(app, w)
}

// One-per-workspace content must never show in two panes at once. Other content is keyed by its own
// id and cannot collide.
@(require_results)
pane_content_can_join :: proc(content: layout.Content, destination: ^Workspace, source: ^Tab) -> bool {
	if !CONTENT_POLICY[content.kind].one_per_workspace {return true}
	return !workspace_content_outside_tab(destination, content, source)
}

@(require_results)
pane_to_tab :: proc(app: ^App, w: ^Window, source: ^Tab, node: layout.Node_Id) -> bool {
	source_workspace := pane_source_workspace(app, source)
	if source_workspace == nil || int(node) >= len(source.tree.nodes) {return false}
	if node == source.tree.root && source_workspace == w.workspace {
		for tab, index in w.workspace.tabs {
			if tab != source {continue}
			tab_move(app, w, index, len(w.workspace.tabs) - 1)
			tab_select(app, w, len(w.workspace.tabs) - 1)
			return true
		}
		return false
	}
	pane, valid := source.tree.nodes[node].(layout.Pane)
	if !valid {return false}
	destination_workspace := w.workspace
	if !pane_content_can_join(pane.content, destination_workspace, source) {return false}
	panes := [?]layout.Pane_Rect{{content = pane.content, rect = window_content_area(app, w)}}
	if !pane_minimum_allows(app, w, panes[:], nil, notify_failure = true) {return false}
	tab, reserved := tab_record_reserve(w.workspace)
	if !reserved {
		notify(app, .Error, "Could not create a tab. The pane was preserved.")
		return false
	}
	move := pane_move_begin(app, w, source, node)
	tree, separated := layout.separate_pane(&source.tree, node)
	if !separated {
		pane_move_enter(app, move)
		tab_record_free(tab)
		notify(app, .Error, "Could not move the pane. The layout was preserved.")
		return false
	}
	tab.tree = tree
	tab_record_commit(app, w.workspace, tab)
	pane_move_finish(app, move, tab)
	return true
}

@(require_results)
pane_transfer :: proc(
	app: ^App,
	w: ^Window,
	source, destination: ^Tab,
	node, target: layout.Node_Id,
	direction: layout.Direction,
	root: bool,
) -> bool {
	place := root ? Pane_Place.Edge : Pane_Place.Beside
	request := Pane_Operation{place = place, node = node, target = target, slot = layout.INVALID_NODE,
		direction = direction}
	op, resolved := pane_transfer_operation(app, w, source, destination, request)
	return resolved && pane_operation_move(app, w, op)
}

pane_keep_open :: proc(app: ^App, w: ^Window) {
	entry := focused_session(app, w)
	if entry == nil {return}
	entry.keep_open = !entry.keep_open
	notify(
		app,
		.Info,
		entry.keep_open ? "Pane will stay open after exit." : "Pane will close after exit.",
	)
	if !entry.keep_open && entry.status == .Exited {_ = close_exited_session(app, entry.id)}
}

pane_close :: proc(app: ^App, w: ^Window) {
	if window_linked(w) {
		home, found := pane_link_home(app, pane_link_content(w))
		if found {
			pane_close_at(app, home.workspace, tab_index_by_id(home.workspace, home.tab.id), home.node)
		}
		return
	}
	pane_close_at(app, w.workspace, w.workspace.selected, window_tree(w).focus)
}

// A close Reopen Closed can undo, by request or because the shell exited.
pane_close_at :: proc(app: ^App, workspace: ^Workspace, tab_index: int, node: layout.Node_Id) {
	closed_record_pane(app, workspace, tab_index, node)
	pane_remove(app, workspace, tab_index, node)
}

@(private)
pane_remove :: proc(
	app: ^App,
	workspace: ^Workspace,
	original_tab_index: int,
	node: layout.Node_Id,
) {
	tab_index := original_tab_index
	tab := workspace.tabs[tab_index]
	for w in app.windows {if w.workspace == workspace {_ = gesture_cancel(app, w)}}
	for current, i in workspace.tabs {if current == tab {tab_index = i; break}}
	pane, is_pane := tab.tree.nodes[node].(layout.Pane)
	if !is_pane {return}
	if tab.tree.root == node {
		workspace_close_tab(app, workspace, tab_index)
		workspace_close_empty(app, workspace)
		return
	}
	visible := tab_index == workspace.selected
	was_focused := visible && tab.tree.focus == node
	if was_focused {
		for w in app.windows {if w.workspace == workspace {focus_leave(app, w)}}
	}
	if !layout.remove(&tab.tree, node) {return}
	if pane_owns_session(pane.content.kind) {session_close(app, pane.content.id)}
	workspace_settings_sync(app, workspace)
	tab_update_title(app, tab)
	if visible {
		for w in app.windows {
			if w.workspace != workspace {continue}
			// A floating pane's close leaves the tiled panes exactly as they were.
			if pane.floating {window_floats_layout(app, w)} else {window_relayout(app, w)}
			if was_focused {focus_enter(app, w)}
		}
	}
}
