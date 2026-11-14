package main

import "aio:layout"

// Moving a pane from the keyboard (WORK-477). Each move is the drop a header drag would make there: it is
// planned as a Pane_Drop, measured by pane_drop_preview and carried out by pane_drop_commit, so a key and a
// drag reach the same layouts and give the same refusals. A direction finds its neighbour as focus does
// (pane_neighbour_toward), across the linked windows showing the tab.

// Moves w's focused pane one step toward `direction`, smallest change first (layout.step_plan). With a pane
// that way in its row it passes that neighbour when the two share the row, and otherwise joins the
// neighbour on the side facing it. In a split across the move it turns to sit beside its neighbour across
// that split; at the end of its row it docks along that edge of the next region out, the whole tab last.
// Only a pane already along the tab's edge goes on, into a linked window showing the same tab. A floating
// pane steps only within its float. Returns the window then holding the pane, or nil when nothing moved.
pane_move_toward :: proc(app: ^App, w: ^Window, direction: layout.Direction) -> ^Window {
	tree := window_tree(w)
	if tree == nil {return nil}
	node := tree.focus
	drop := Pane_Drop {
		window    = w.id,
		tab       = selected_tab(w.workspace),
		direction = direction,
	}
	switch step in layout.step_plan(tree, node, direction) {
	case layout.Step_Beside:
		drop.place, drop.target = .Beside, step.target
		return pane_step_drop(app, w, w, drop) ? w : nil
	case layout.Step_Region:
		drop.place, drop.target = .Region, step.region
		return pane_step_drop(app, w, w, drop) ? w : nil
	case layout.Step_Neighbour:
	case nil:
	}
	floating := layout.is_floating(tree, node)
	destination, target := pane_neighbour_toward(app, w, direction)
	switch {
	case destination == w && target == node, floating && destination != w:
		return nil
	case floating && layout.float_root(tree, target) != layout.float_root(tree, node):
		return nil
	case destination == w && layout.step_passes(tree, node, target, direction):
	case:
		drop.direction = layout.opposite(direction)
	}
	drop.window, drop.tab = destination.id, selected_tab(destination.workspace)
	drop.place, drop.target = .Beside, target
	return pane_step_drop(app, w, destination, drop) ? destination : nil
}

// Docks w's focused pane along the `direction` edge of its tab, as a drop on that edge's band does. A tiled
// pane already running along the whole edge stays where it is.
pane_dock :: proc(app: ^App, w: ^Window, direction: layout.Direction) -> bool {
	tree := window_tree(w)
	if tree == nil {return false}
	if !layout.is_floating(tree, tree.focus) && layout.spans_edge(tree, tree.focus, direction) {return false}
	drop := Pane_Drop {
		window    = w.id,
		tab       = selected_tab(w.workspace),
		place     = .Edge,
		target    = tree.focus,
		direction = direction,
	}
	return pane_step_drop(app, w, w, drop)
}

// Swaps w's focused pane with the pane toward `direction` in the same tree. A neighbour in another window
// is left alone, as a Shift drag swaps only within its own tab.
pane_swap_toward :: proc(app: ^App, w: ^Window, direction: layout.Direction) {
	destination, other := pane_neighbour_toward(app, w, direction)
	if destination == w {pane_swap(app, w, other)}
}

// Swaps w's focused pane with `other`, a pane of the same tree.
pane_swap :: proc(app: ^App, w: ^Window, other: layout.Node_Id) {
	tree := window_tree(w)
	if tree == nil || other == tree.focus {return}
	tab := selected_tab(w.workspace)
	swap := Pane_Operation {
		place       = .Swap,
		source      = tab,
		destination = tab,
		node        = tree.focus,
		target      = other,
		slot        = layout.INVALID_NODE,
	}
	_ = pane_rearrange(app, w, swap)
}

// Turns the split beside w's focused pane a quarter turn, as Hyprland's togglesplit does; the panes travel
// to their new places as rearranged panes do.
pane_rotate_split :: proc(app: ^App, w: ^Window) {
	tree := window_tree(w)
	if tree == nil || !layout.rotate_split(tree, tree.focus) {return}
	pane_motion_arm(w, .Move)
	window_relayout(app, w)
}

// Moves w's focused pane into tab `index` of the window showing its tab, beside that tab's focused pane, as
// a drop on the tab does; the window then shows that tab. Returns that window, or nil when nothing moved.
pane_move_to_tab :: proc(app: ^App, w: ^Window, index: int) -> ^Window {
	host := pane_link_acting_window(app, w)
	if index < 0 || index >= len(host.workspace.tabs) {return nil}
	tab := host.workspace.tabs[index]
	if tab == selected_tab(w.workspace) {return nil}
	drop := Pane_Drop {
		window    = host.id,
		tab       = tab,
		place     = .Beside,
		target    = tab.tree.focus,
		direction = .Right,
	}
	return pane_step_drop(app, w, host, drop) ? host : nil
}

// Moves w's focused pane into a new tab of the window showing its tab, as a drop on New tab does; a tab's
// only pane moves its tab to the end instead. Returns that window, or nil when nothing moved.
pane_move_to_new_tab :: proc(app: ^App, w: ^Window) -> ^Window {
	host := pane_link_acting_window(app, w)
	drop := Pane_Drop {
		window    = host.id,
		tab       = selected_tab(host.workspace),
		place     = .New_Tab,
		target    = layout.INVALID_NODE,
	}
	return pane_step_drop(app, w, host, drop) ? host : nil
}

// Moves the pane at `node` of `source`, the tab w shows, into a window of its own over the place it held,
// as a tear-off dropped there does; the new window then names its workspace. Returns the new window, or nil
// when the pane stays.
pane_move_to_new_window :: proc(app: ^App, w: ^Window, source: ^Tab, node: layout.Node_Id) -> ^Window {
	if source == nil {return nil}
	preview := pane_window_preview_create(app, source, node)
	if preview == nil {
		notify(app, .Info, "This pane cannot move to a new window.")
		return nil
	}
	corner: [2]f32
	for pane in w.panes {if pane.node == node {corner = {pane.rect.x, pane.rect.y}; break}}
	if !window_place_at_corner(app, preview, w, corner) || !pane_to_window(app, w, source, node, preview.id) {
		window_preview_discard(app, preview.id)
		notify(app, .Error, "Could not move the pane to a new window. The source was preserved.")
		return nil
	}
	workspace_name_begin(app, preview)
	return preview
}

// Carries out `drop` for w's focused pane in `destination`, as releasing a header drag there does; a drop
// that does not fit gives the drag's refusal. Another window receiving the pane comes forward.
@(private = "file")
pane_step_drop :: proc(app: ^App, w, destination: ^Window, drop: Pane_Drop) -> bool {
	tree := window_tree(w)
	grab := Pane_Grab{selected_tab(w.workspace), tree == nil ? layout.INVALID_NODE : tree.focus}
	if grab.source == nil {return false}
	planned := drop
	_, planned.fit = pane_drop_preview(app, w, grab, destination, &planned)
	if planned.fit != .Fits {
		pane_drop_refused(app, planned.fit)
		return false
	}
	if !pane_drop_commit(app, w, grab, destination, planned) {
		if planned.place != .New_Tab {
			pane_drop_refused(app, pane_drop_refusal(w, grab.source, destination, planned))
		}
		return false
	}
	if destination != w {_ = window_activate(app, destination)}
	destination.dirty = true
	return true
}
