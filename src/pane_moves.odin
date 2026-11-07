package main

import "aio:input"
import "aio:layout"

@(private)
Pane_Move :: struct {
	source: ^Tab,
	workspace: ^Workspace,
	destination: input.Window_Id,
	departed: [2]input.Window_Id,
	count: int,
}

@(private)
pane_move_begin :: proc(app: ^App, w: ^Window, source: ^Tab, workspace: ^Workspace) -> Pane_Move {
	move := Pane_Move{source = source, workspace = workspace, destination = w.id}
	for window in app.windows {
		if window.phase == .Preparing {continue}
		if window != w && selected_tab(window.workspace) != source {continue}
		move.departed[move.count] = window.id
		move.count += 1
		focus_leave(app, window)
	}
	return move
}

// Gives focus back to every window the move left that is still open, after a failure or once the
// destination is settled. A window that has entered its new pane already hears nothing again.
@(private)
pane_move_enter :: proc(app: ^App, move: Pane_Move) {
	for i in 0 ..< move.count {
		if window := window_find(app, move.departed[i]); window != nil {focus_enter(app, window)}
	}
}

@(private)
pane_move_finish :: proc(app: ^App, move: Pane_Move, destination: ^Tab) {
	w := window_find(app, move.destination)
	if move.source.tree.root != layout.INVALID_NODE {tab_update_title(app, move.source)}
	// The moved content may have been Settings, so each side's page follows what it now shows.
	workspace_settings_sync(app, move.workspace)
	index := tab_index_by_id(w.workspace, destination.id)
	tab_select_one(w.workspace, index)
	w.workspace.selected = index
	mark_all_dirty(app)
	window_relayout(app, w)
	focus_enter(app, w)
	if move.source.tree.root == layout.INVALID_NODE {
		for tab, source_index in move.workspace.tabs {
			if tab == move.source {workspace_close_tab(app, move.workspace, source_index); break}
		}
	} else if move.workspace != w.workspace {
		if owner := window_for_workspace(app, move.workspace); owner != nil {
			window_relayout(app, owner)
			if selected_tab(move.workspace) == move.source {focus_enter(app, owner)}
		}
	}
	workspace_settings_sync(app, w.workspace)
	// A transfer has already focused its destination; its exhausted source window can retire.
	workspace_close_empty(app, move.workspace, replace_window = false)
}

pane_rearrange :: proc(
	app: ^App,
	w: ^Window,
	node, target: layout.Node_Id,
	direction: layout.Direction,
	swap, root: bool,
) {
	changed := false
	if swap {
		changed = layout.swap(window_tree(w), node, target)
	} else if root {
		_, changed = layout.dock_pane(window_tree(w), node, direction)
	} else {
		_, changed = layout.move_pane(window_tree(w), node, target, direction)
	}
	if changed {
		window_relayout(app, w)
		window_update_title(app, w)
		cursor_blink_reset(w)
	}
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
	move := pane_move_begin(app, w, source, source_workspace)
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
	source_workspace := pane_source_workspace(app, source)
	destination_index := -1
	for tab, index in w.workspace.tabs {if tab == destination {destination_index = index; break}}
	if source_workspace == nil || destination_index < 0 || source == destination {return false}
	if int(node) >= len(source.tree.nodes) || int(target) >= len(destination.tree.nodes) {return false}
	pane, valid := source.tree.nodes[node].(layout.Pane)
	if !valid || !pane_content_can_join(pane.content, w.workspace, source) {return false}
	move := pane_move_begin(app, w, source, source_workspace)
	_, moved := layout.transfer_pane(
		&source.tree,
		&destination.tree,
		node,
		target,
		direction,
		root,
	)
	if !moved {
		pane_move_enter(app, move)
		return false
	}
	pane_move_finish(app, move, destination)
	return true
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
