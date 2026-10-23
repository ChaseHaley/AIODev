package main

import "aio:layout"
import "aio:platform"

@(private)
Pane_Move :: struct {
	source: ^Tab,
	workspace: ^Workspace,
	destination: platform.Window_Id,
	departed: [2]platform.Window_Id,
	count: int,
}

@(private)
pane_move_begin :: proc(app: ^App, w: ^Window, source: ^Tab, workspace: ^Workspace) -> Pane_Move {
	move := Pane_Move{source = source, workspace = workspace, destination = w.id}
	for window in app.windows {
		if window.preparing {continue}
		if window != w && selected_tab(window.workspace) != source {continue}
		move.departed[move.count] = window.id
		move.count += 1
		focus_leave(app, window)
	}
	return move
}

@(private)
pane_move_abort :: proc(app: ^App, move: Pane_Move) {
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
	w.tree = &destination.tree
	mark_all_dirty(app)
	window_relayout(app, w)
	focus_enter(app, w)
	if move.source.tree.root == layout.INVALID_NODE {
		for tab, source_index in move.workspace.tabs {
			if tab == move.source {workspace_close_tab(app, move.workspace, source_index); break}
		}
		// Closing the exhausted tab may have freed its window and the source tab.
		if move.workspace != w.workspace {_ = workspace_discard_empty(app, move.workspace)}
	} else if move.workspace != w.workspace {
		if owner := window_for_workspace(app, move.workspace); owner != nil {
			window_relayout(app, owner)
			if selected_tab(move.workspace) == move.source {focus_enter(app, owner)}
		}
	}
	workspace_settings_sync(app, w.workspace)
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
		changed = layout.swap(w.tree, node, target)
	} else if root {
		_, changed = layout.dock_pane(w.tree, node, direction)
	} else {
		_, changed = layout.move_pane(w.tree, node, target, direction)
	}
	if changed {
		window_relayout(app, w)
		window_update_title(app, w)
		reset_blink(w)
	}
}
