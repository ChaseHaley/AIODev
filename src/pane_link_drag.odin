package main

import "aio:layout"
import "core:log"

// A pane in a linked window can be dragged anywhere: back to the window that owns its tab, into another
// linked window, or into another tab, window or workspace. It stays linked only while it lands in a linked
// window; every other destination takes it out of its slot. Membership moves happen in the tab's tree,
// never in a linked window's private copy. See src/pane_links.odin.

// Drops the dragged pane on a new tab of `destination_window`. The pane leaves its linked slot first.
@(require_results)
pane_link_new_tab :: proc(
	app: ^App,
	source_window, destination_window: ^Window,
	d: Pane_Drag,
) -> bool {
	if !window_linked(source_window) || window_linked(destination_window) {return false}
	pane, is_pane := d.source.tree.nodes[d.node].(layout.Pane)
	if !is_pane {return false}
	content := pane.content
	home, linked, found := pane_link_origin(app, d.source, d.node)
	if !found || !linked {return false}
	home = pane_link_reconcile_at(app, source_window, home)
	if refreshed, still_linked := pane_link_home(app, content); still_linked {
		home = refreshed
	} else {
		return false
	}
	if !pane_to_tab(app, destination_window, home.tab, home.node) {return false}
	pane_link_refresh_source(app, source_window, content)
	return true
}

// Drops a pane between two windows when either shows a linked slot. The caller has already checked that
// the destination has a pane target and that the source still exists.
@(require_results)
pane_link_drag_release :: proc(
	app: ^App,
	source_window, destination_window: ^Window,
	d: Pane_Drag,
) -> bool {
	pane, is_pane := d.source.tree.nodes[d.node].(layout.Pane)
	if !is_pane {return false}
	content := pane.content
	home, source_linked, found := pane_link_origin(app, d.source, d.node)
	if !found {return false}
	if !source_linked && !window_linked(destination_window) {return false}
	if source_linked {
		// Store this window's arrangement before the pane leaves the slot.
		home = pane_link_reconcile_at(app, source_window, home)
		if refreshed, still_linked := pane_link_home(app, content); still_linked {
			home = refreshed
		} else {
			return false
		}
	} else if !pane_link_tab_can_lose(home.tab) {
		return false
	}
	destination_linked := window_linked(destination_window)
	destination := d.destination
	slot := layout.INVALID_NODE
	target := d.target
	if destination_linked {
		destination_home, located := pane_link_locate(app, destination_window)
		if !located {return false}
		// Keep the destination's arrangement before adding to its slot.
		destination_home = pane_link_reconcile_at(app, destination_window, destination_home)
		destination, slot = destination_home.tab, destination_home.slot
		if !layout.slot_valid(&destination.tree, slot) {return false}
		if target != layout.INVALID_NODE {
			if int(target) >= len(d.destination.tree.nodes) {return false}
			target_pane, target_is_pane := d.destination.tree.nodes[target].(layout.Pane)
			if !target_is_pane {return false}
			target = layout.find_content(&destination.tree, target_pane.content)
			if target == layout.INVALID_NODE && !d.root {return false}
		}
	}
	if destination == nil {return false}
	destination_workspace := pane_source_workspace(app, destination)
	if destination_workspace == nil {return false}
	if !pane_content_can_join(content, destination_workspace, home.tab) {return false}
	same_tab := destination == home.tab
	if same_tab {
		if destination_linked {
			// Two windows of one slot show the same panes; moving between them is no move at all.
			if source_linked && home.slot == slot {return false}
		} else if !source_linked {
			return false
		}
	}
	move := pane_move_begin(app, destination_window, home.tab, home.workspace)
	moved := false
	switch {
	case destination_linked && same_tab:
		_, moved = layout.slot_take_pane(
			&home.tab.tree,
			home.node,
			slot,
			target,
			d.direction,
			d.root,
		)
	case destination_linked:
		_, moved = layout.transfer_pane_to_slot(
			&home.tab.tree,
			&destination.tree,
			home.node,
			slot,
			target,
			d.direction,
			d.root,
		)
	case same_tab:
		if d.root {
			_, moved = layout.dock_pane(&home.tab.tree, home.node, d.direction)
		} else {
			_, moved = layout.move_pane(&home.tab.tree, home.node, target, d.direction)
		}
	case:
		_, moved = layout.transfer_pane(
			&home.tab.tree,
			&destination.tree,
			home.node,
			target,
			d.direction,
			d.root,
		)
	}
	if !moved {
		pane_move_enter(app, move)
		return false
	}
	pane_link_drag_finish(
		app,
		source_window,
		destination_window,
		home,
		source_linked,
		destination,
		destination_linked,
		content,
	)
	// A linked source settles only its own window, so the window showing its tab is entered here.
	pane_move_enter(app, move)
	return true
}

// Settles both sides after a linked drag moved a pane: the source tab and window lose it, and the
// destination window shows it, linked or not.
@(private)
pane_link_drag_finish :: proc(
	app: ^App,
	source_window, destination_window: ^Window,
	source: Pane_Link_Home,
	source_linked: bool,
	destination: ^Tab,
	destination_linked: bool,
	content: layout.Content,
) {
	if source.tab.tree.root != layout.INVALID_NODE {
		tab_update_title(app, source.tab)
		workspace_settings_sync(app, source.workspace)
	}
	if source_linked {
		pane_link_refresh_source(app, source_window, content)
	} else if source.tab.tree.root == layout.INVALID_NODE {
		for tab, index in source.workspace.tabs {
			if tab == source.tab {
				workspace_close_tab(app, source.workspace, index)
				break
			}
		}
	} else if owner := window_for_workspace(app, source.workspace); owner != nil {
		window_relayout(app, owner)
		if selected_tab(source.workspace) == source.tab {focus_enter(app, owner)}
	}
	destination_workspace := pane_source_workspace(app, destination)
	if destination_linked {
		if home, found := pane_link_home(app, content); found {
			pane_link_refresh_at(app, destination_window, home)
			if node := layout.find_content(destination_window.tree, content); node != layout.INVALID_NODE {
				pane_focus(app, destination_window, node)
			}
		} else {
			log.error("the moved pane did not join the destination window")
		}
	} else {
		index := tab_index_by_id(destination_window.workspace, destination.id)
		if index >= 0 {
			tab_select_one(destination_window.workspace, index)
			destination_window.workspace.selected = index
		}
		destination_window.tree = &destination.tree
		if node := layout.find_content(&destination.tree, content); node != layout.INVALID_NODE {
			destination.tree.focus = node
		}
		window_relayout(app, destination_window)
		focus_enter(app, destination_window)
	}
	if destination_workspace != nil {workspace_settings_sync(app, destination_workspace)}
	mark_all_dirty(app)
	layout_state_touch(app)
	workspace_close_empty(app, source.workspace, replace_window = false)
}
