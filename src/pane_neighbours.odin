package main

import "aio:layout"
import "aio:platform"

// Focus left, right, up and down reach every pane of the tab on screen, whichever window shows it: the
// window displaying the tab and the linked windows showing part of it (D-079), placed by where they are on
// the desktop (WORK-479). Panes in hidden linked windows, other tabs and other windows' floats are never
// reached.

// The pane toward `direction` from w's focused pane, and the window it is in; (w, the pane to stay on)
// when none lies that way. A move stays in w while w has a pane that way, as it always has: inside a
// floating group it stays in the group, and leaving the group's outer edge continues from the tiled pane
// behind it, so stopping there focuses that pane. Only past w's last pane does it cross to the other
// windows showing the tab, measured from the pane it leaves on the desktop. Windows may overlap, so w
// goes first: a pane w shows beside the focused one is never passed over for one in a window behind it.
// The node belongs to the returned window's own tree.
pane_neighbour_toward :: proc(
	app: ^App,
	w: ^Window,
	direction: layout.Direction,
) -> (
	target: ^Window,
	node: layout.Node_Id,
) {
	tree := window_tree(w)
	start := pane_action_focus(w)
	own := pane_action_rects(app, w)
	if layout.is_floating(tree, start) {
		if other := layout.focus_direction(own, start, direction); other != start {return w, other}
		start, own = layout.focus_tiled(tree), pane_tiled_action_rects(app, w)
	}
	if other := layout.focus_direction(own, start, direction); other != start {return w, other}
	others := pane_tab_windows(app, w)
	if len(others) == 0 {return w, start}
	x, y, origin_error := platform.window_to_screen(&app.platform, w.id, 0, 0)
	if origin_error != .None {return w, start}

	// The pane being left, then every pane of the other windows, on the desktop with the window each is in.
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	windows := make([dynamic]^Window, context.temp_allocator)
	for pane in own {
		if pane.node != start {continue}
		append(&rects, pane_rect_offset(pane, x, y))
		append(&windows, w)
		break
	}
	if len(rects) == 0 {return w, start}
	for other in others {
		ox, oy, other_error := platform.window_to_screen(&app.platform, other.id, 0, 0)
		if other_error != .None {continue}
		for pane in pane_tiled_action_rects(app, other) {
			append(&rects, pane_rect_offset(pane, ox, oy))
			append(&windows, other)
		}
	}
	nearest := layout.nearest_toward(rects[:], 0, direction)
	if nearest < 0 {return w, start}
	return windows[nearest], rects[nearest].node
}

// Moves focus to the pane toward `direction`, bringing its window forward when it is another one. The
// jump list follows that window, as a reveal does (WORK-457), so the pane is recorded as landed on.
pane_focus_toward :: proc(app: ^App, w: ^Window, direction: layout.Direction) {
	target, node := pane_neighbour_toward(app, w, direction)
	if target == w {pane_focus(app, w, node); return}
	content, is_pane := layout.pane_content(window_tree(target), node)
	if !is_pane || !window_activate(app, target) {return}
	pane_focus(app, target, node)
	focus_jumps_follow(app, target, content)
	target.dirty = true
}

// The other windows on screen showing w's tab: the window displaying it, when w is a linked window, and
// its linked windows that are shown.
@(private)
pane_tab_windows :: proc(app: ^App, w: ^Window) -> []^Window {
	tab: ^Tab
	if window_linked(w) {
		home, found := pane_link_locate(app, w)
		if !found {return nil}
		tab = home.tab
	} else {
		tab = selected_tab(w.workspace)
	}
	if tab == nil {return nil}
	windows := make([dynamic]^Window, context.temp_allocator)
	for other in app.windows {
		if other == w || !window_drawable(other) {continue}
		if window_linked(other) {
			home, found := pane_link_locate(app, other)
			if !found || home.tab != tab {continue}
		} else if selected_tab(other.workspace) != tab {
			continue
		}
		append(&windows, other)
	}
	return windows[:]
}

@(private)
pane_rect_offset :: proc(pane: layout.Pane_Rect, x, y: i32) -> layout.Pane_Rect {
	moved := pane
	moved.rect.x += f32(x)
	moved.rect.y += f32(y)
	return moved
}
