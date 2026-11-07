package main

import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:fmt"
import "core:math"
import "core:time"

@(private)
DOUBLE_CLICK_NS :: i64(500_000_000)
@(private)
DRAG_THRESHOLD :: 5
@(private)
GHOST_DURATION :: 120 * time.Millisecond

// Splits whose dividers meet under the pointer move together, outermost first.
Divider_Drag :: struct {
	nodes: [4]layout.Node_Id,
	offsets: [4]f32,
	count: int,
}

@(private)
divider_hits :: proc(w: ^Window, x, y: f32, out: []layout.Divider) -> int {
	if root, _, covered := floating_frame_at(w, x, y); covered {
		hits: [8]layout.Divider
		n := layout.divider_hit_all(w.dividers[:], x, y, 3 * w.scale, hits[:], 10 * w.scale, 2 * w.scale)
		count := 0
		for d in hits[:n] {
			if dock_divider(d.node) || layout.float_root(w.tree, d.node) != root {continue}
			if count >= len(out) {break}
			out[count] = d
			count += 1
		}
		return count
	}
	if rail_overlay(w) {
		area := rail_area(w)
		for d in w.dividers {
			if d.node != RAIL_DIVIDER {continue}
			if x < area.x || x >= d.rect.x + d.rect.width + 3 * w.scale ||
			   y < area.y || y >= area.y + area.height {break}
			docks: [2]layout.Divider
			count := 0
			for dock in w.dividers {
				if dock_divider(dock.node) {docks[count] = dock; count += 1}
			}
			return layout.divider_hit_all(docks[:count], x, y, 3 * w.scale, out)
		}
	}
	hits: [8]layout.Divider
	n := layout.divider_hit_all(w.dividers[:], x, y, 3 * w.scale, hits[:], 10 * w.scale, 2 * w.scale)
	count := 0
	for d in hits[:n] {
		if !dock_divider(d.node) && layout.float_root(w.tree, d.node) != layout.INVALID_NODE {continue}
		if count >= len(out) {break}
		out[count] = d
		count += 1
	}
	return count
}

// Starts a divider drag, or on a second click of the same divider balances the splits it belongs to.
divider_press :: proc(app: ^App, w: ^Window, x, y: f32, time_ns: i64) -> bool {
	hits: [4]layout.Divider
	n := divider_hits(w, x, y, hits[:])
	if n == 0 {return false}
	w.selecting, w.autoscrolling = false, false
	if hits[0].node == w.divider_click_node && time_ns > w.divider_click_ns &&
	   time_ns - w.divider_click_ns <= DOUBLE_CLICK_NS {
		w.divider_click_node = layout.INVALID_NODE
		balanced := false
		for d in hits[:n] {
			if dock_divider(d.node) {dock_divider_reset(w, d.node); balanced = true}
			else {balanced = layout.balance_related(w.tree, d.node) || balanced}
		}
		if balanced {window_relayout(app, w)}
		return true
	}
	w.divider_click_node, w.divider_click_ns = hits[0].node, time_ns
	w.dragging = {
		count = n,
	}
	for d, i in hits[:n] {
		w.dragging.nodes[i] = d.node
		if dock_divider(d.node) {
			pointer := d.axis == .Vertical ? y : x
			w.dragging.offsets[i] = pointer - dock_divider_position(app, w, d.node)
		}
		if d.node == RAIL_DIVIDER {w.rail_resizing = true}
	}
	return true
}

// Each split takes the pointer position on its own axis. Divider areas are refreshed after every move,
// because an outer split resizes the region of the splits nested inside it.
divider_drag :: proc(app: ^App, w: ^Window, x, y: f32) {
	gap := window_gap(app, w)
	moved := false
	for node, i in w.dragging.nodes[:w.dragging.count] {
		if dock_divider(node) {
			pointer := node == ACTIVITY_HEIGHT_DIVIDER ? y : x
			dock_divider_drag(app, w, node, pointer - w.dragging.offsets[i])
			w.dock_left_width = app.settings.status.panel_side == .Left ? status_panel_dock_width(app, w) : 0
			w.status_rail_reserve = status_panel_rail_height(app, w)
			window_dividers(app, w)
			moved = true
			continue
		}
		for d in w.dividers {
			if d.node != node {continue}
			if layout.drag_divider(w.tree, d, x, y, gap) {
				moved = true
				window_dividers(app, w)
			}
			break
		}
	}
	if moved {window_relayout(app, w)}
}

divider_cursor :: proc(w: ^Window, x, y: f32) -> (platform.Cursor_Shape, bool) {
	hits: [4]layout.Divider
	n := divider_hits(w, x, y, hits[:])
	if n == 0 {return .Arrow, false}
	axes: bit_set[layout.Axis]
	for d in hits[:n] {axes += {d.axis}}
	if axes == {.Horizontal, .Vertical} {return .Resize_All, true}
	return .Horizontal in axes ? .Resize_Horizontal : .Resize_Vertical, true
}

tab_press :: proc(app: ^App, w: ^Window, index: int, x, y: f32, modified: bool) {
	if index < 0 || index >= len(w.workspace.tabs) || !w.workspace.tabs[index].marked {return}
	offset: [2]f32
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		if bar.tab_width <= 0 {return}
		offset.x = x - (bar.x + tab_position(w, index) * bar.tab_width)
	} else {
		row := rail_row_rect_for_tab(w, index)
		if row.height <= 0 {return}
		offset.y = (y - row.y) / row.height
	}
	drag_press(w, x, y, Tab_Grab{w.workspace.tabs[index], offset, modified})
}

// Moves a tab and everything indexed by tab position, keeping the selected tab selected.
tab_move :: proc(app: ^App, w: ^Window, from, to: int) {
	tabs := &w.workspace.tabs
	if from == to || from < 0 || to < 0 || from >= len(tabs) || to >= len(tabs) {return}
	tab := tabs[from]
	ordered_remove(tabs, from)
	inject_at(tabs, to, tab)
	tab_presentation_move(&w.presentation, from, to)
	w.workspace.selected = tab_selected_after_move(w.workspace.selected, from, to)
	w.tree = &selected_tab(w.workspace).tree
	rail_reveal_active(w)
	mark_all_dirty(app)
}

// The active tab drag in w, or nil.
@(private)
tab_drag_state :: proc(w: ^Window) -> (^Drag_Active, ^Tab_Carry) {
	a := drag_active(w)
	if a == nil {return nil, nil}
	carry, tab := &a.carry.(Tab_Carry)
	if !tab {return nil, nil}
	return a, carry
}

tab_drag_move :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if grab, passed := drag_threshold_passed(w, x, y); passed {
		tab, is_tab := grab.(Tab_Grab)
		if !is_tab {return false}
		order, err := make([dynamic]^Tab, len(w.workspace.tabs))
		if err != nil {
			_ = drag_end(w)
			notify(app, .Error, "Could not begin tab dragging.")
			return true
		}
		copy(order[:], w.workspace.tabs[:])
		rank := 0
		for candidate in order {if candidate == tab.grabbed {break}; if candidate.marked {rank += 1}}
		_ = drag_activate(w, Tab_Carry{grab = tab, order = order, rank = rank}, x, y)
	}
	if !tab_drag_active(w) {return false}
	if tab_drag_windows_move(app, w, x, y) {return true}
	if w.tabs_horizontal {return tab_drag_move_strip(app, w, x)}
	return tab_drag_move_rail(app, w, x, y)
}

@(private)
tab_drag_apply_slot :: proc(app: ^App, w: ^Window, slot: int) -> bool {
	_, d := tab_drag_state(w)
	marked, mark_error := make([]bool, len(d.order), context.temp_allocator)
	if mark_error !=
	   nil {tab_drag_cancel(app, w); notify(app, .Error, "Could not move tabs."); return false}
	count := 0
	for tab, i in d.order {marked[i] = tab.marked; if tab.marked {count += 1}}
	if len(d.order) - count <= 0 {return false}
	order, order_error := make([]int, len(d.order), context.temp_allocator)
	if order_error !=
	   nil {tab_drag_cancel(app, w); notify(app, .Error, "Could not move tabs."); return false}
	if !ui.tab_group_order(marked, slot, order) {return false}
	for original, to in order {
		for tab, from in w.workspace.tabs {
			if tab == d.order[original] {tab_move(app, w, from, to); break}
		}
	}
	w.dirty = true
	return true
}

@(private)
tab_drag_move_strip :: proc(app: ^App, w: ^Window, x: f32) -> bool {
	a, d := tab_drag_state(w)
	drag_retarget(app, w, a, Drop_Reorder{})
	bar := window_tab_bar(app, w)
	if bar.tab_width <= 0 {return true}
	count := 0
	for tab in d.order {if tab.marked {count += 1}}
	if len(d.order) - count <= 0 {return true}
	first := clamp(
		(x - bar.x - d.offset.x) / bar.tab_width - f32(d.rank),
		0,
		f32(len(d.order) - count),
	)
	if !tab_drag_apply_slot(app, w, int(math.floor(first + 0.5))) {return true}
	tab_drag_follow_pointer(w, first)
	return true
}

@(private)
tab_drag_follow_pointer :: proc(w: ^Window, first: f32) {
	rank, now := 0, time.tick_now()
	for tab, i in w.workspace.tabs {
		if !tab.marked {continue}
		if i < len(w.tab_positions) {
			ui.motion_target(&w.tab_positions[i], first + f32(rank), 0, .Linear, false, now)
		}
		rank += 1
	}
}

@(private)
tab_drag_move_rail :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	a, d := tab_drag_state(w)
	layout, ok := rail_current_layout(w)
	if !ok || !rail_visible(w) || layout.list.height <= 0 || layout.row_height <= 0 {
		drag_retarget(app, w, a, nil)
		w.dirty = true
		return true
	}
	area := rail_area(w)
	if x < area.x || x >= area.x + area.width || y < area.y || y >= area.y + area.height {
		drag_retarget(app, w, a, nil)
		w.dirty = true
		return true
	}
	drag_retarget(app, w, a, Drop_Reorder{})
	if layout.count == 0 {return true}
	count := 0
	for tab in d.order {if tab.marked {count += 1}}
	if len(d.order) - count <= 0 {return true}
	first_row := ui.rail_row_rect(layout, 0)
	first :=
		(y - first_row.y) / layout.row_height -
		d.offset.y -
		f32(d.rank)
	first = clamp(first, 0, f32(len(d.order) - count))
	if !tab_drag_apply_slot(app, w, int(math.floor(first + 0.5))) {return true}
	first = clamp(first + (w.rail_scroll - layout.scroll) / layout.row_height, 0, f32(len(d.order) - count))
	tab_drag_follow_pointer(w, first)
	return true
}

tab_drag_cancel :: proc(app: ^App, w: ^Window) {
	if !tab_drag_held(w) {return}
	d := drag_end(w)
	if a, active := &d.(Drag_Active); active {tab_drag_abandon(app, w, a)}
}

// Puts an ended tab drag's tabs back in their order and lets go of everything it held.
@(private)
tab_drag_abandon :: proc(app: ^App, w: ^Window, a: ^Drag_Active) {
	for tab, to in a.carry.(Tab_Carry).order {
		for current, from in w.workspace.tabs {if current == tab {tab_move(app, w, from, to); break}}
	}
	drag_let_go(app, w, a)
}

// Drops the tabs at the destination. A click without a drag selects only the pressed tab, unless it changed
// the marks.
tab_drag_release :: proc(app: ^App, w: ^Window) {
	if !tab_drag_held(w) {return}
	d := drag_end(w)
	switch &state in d {
	case Drag_Pressed:
		if !state.grab.(Tab_Grab).modified {tab_select_one(w.workspace, w.workspace.selected)}
	case Drag_Active:
		a := &state
		drag_thumbnail_destroy(&a.thumbnail)
		switch destination in a.destination {
		case Drop_Workspace_Dropdown:
			tab_workspace_drag_release(app, w, a, destination)
		case Drop_Other_Window:
			tab_drag_release_on_window(app, w, a, destination)
		case Drop_Tear_Off:
			_, ready := a.preview.(Preview_Ready)
			if ready && tear_off_commit(app, w, a) {
				drag_free(app, a)
				return
			}
			tab_drag_abandon(app, w, a)
			if ready {notify(app, .Error, "Could not move the tabs. The source was preserved.")}
		case Drop_Reorder:
			drag_let_go(app, w, a)
		case nil, Drop_Pane, Drop_Swap, Drop_Dock_Root, Drop_New_Tab:
			tab_drag_abandon(app, w, a)
		}
	}
}

// The drop may take the window's last tab, and the window with it.
tab_drag_finish :: proc(app: ^App, w: ^Window) {
	id := w.id
	tab_drag_release(app, w)
	if window_find(app, id) != nil {rail_overlay_dismiss(app, w)}
}

pane_drag_press :: proc(app: ^App, w: ^Window, node: layout.Node_Id, x, y: f32) {
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		if i < len(app.windows) && app.windows[i] != w {pane_drag_cancel(app, app.windows[i])}
	}
	drag_press(w, x, y, Pane_Grab{selected_tab(w.workspace), node})
}

// The active pane drag in w, or nil.
@(private)
pane_drag_state :: proc(w: ^Window) -> (^Drag_Active, ^Pane_Carry) {
	a := drag_active(w)
	if a == nil {return nil, nil}
	carry, pane := &a.carry.(Pane_Carry)
	if !pane {return nil, nil}
	return a, carry
}

@(private)
pane_drag_show_source :: proc(app: ^App, w: ^Window, source: ^Tab) {
	for tab, i in w.workspace.tabs {if tab == source {tab_select(app, w, i, true); break}}
}

// Shows the tabs the drag found: the source's in its own window, and the original one in the window it
// visits.
@(private)
pane_drag_restore :: proc(app: ^App, w: ^Window, carry: ^Pane_Carry) {
	visit := carry.visit
	if destination := window_find(app, visit.window); destination != nil && destination != w {
		for tab, i in destination.workspace.tabs {
			if tab == visit.original {tab_select(app, destination, i, true); break}
		}
		if destination.workspace.selected != visit.original_index &&
		   visit.original_index >= 0 &&
		   visit.original_index < len(destination.workspace.tabs) {
			tab_select(app, destination, visit.original_index, true)
		}
		destination.dirty = true
	}
	pane_drag_show_source(app, w, carry.source)
}

pane_drag_cancel :: proc(app: ^App, w: ^Window) {
	grab, held := pane_drag_grab(w)
	if !held {return}
	d := drag_end(w)
	a, active := &d.(Drag_Active)
	if !active {
		pane_drag_show_source(app, w, grab.source)
		return
	}
	drag_let_go(app, w, a)
	pane_drag_restore(app, w, &a.carry.(Pane_Carry))
}

// The edge of `r` nearest to the point, as the side the dragged pane will take.
@(private)
nearest_side :: proc(r: layout.Rect, x, y: f32) -> layout.Direction {
	left, right := (x - r.x) / max(1, r.width), (r.x + r.width - x) / max(1, r.width)
	top, bottom := (y - r.y) / max(1, r.height), (r.y + r.height - y) / max(1, r.height)
	nearest := min(left, right, top, bottom)
	switch nearest {
	case left:
		return .Left
	case right:
		return .Right
	case top:
		return .Up
	}
	return .Down
}

// Where the dragged pane would land at `destination`, and whether it fits there: the target's card for a
// swap, the new tab's place, otherwise its card in a trial layout.
@(private)
pane_drag_preview :: proc(
	app: ^App,
	carry: ^Pane_Carry,
	destination: Drag_Destination,
) -> (
	layout.Rect,
	Drop_Fit,
) {
	w := window_find(app, drag_destination_window(destination))
	if w == nil {return {}, .Refused}
	switch d in destination {
	case Drop_New_Tab:
		pane := carry.source.tree.nodes[carry.node].(layout.Pane)
		panes := [?]layout.Pane_Rect{{content = pane.content, rect = window_content_area(app, w)}}
		reorders_tab :=
			pane_source_workspace(app, carry.source) == w.workspace && carry.node == carry.source.tree.root
		if !reorders_tab && !pane_minimum_allows(app, w, panes[:], nil, notify_failure = false) {
			return {}, .Too_Small
		}
		if w.tabs_horizontal {
			r := ui.tab_drop_region(window_tab_bar(app, w), f32(w.width), w.scale)
			return {
					r.x + 2 * w.scale,
					(ui.TITLE_BAR_HEIGHT - ui.HEIGHT_TOOLBAR) / 2 * w.scale,
					max(0, min(180 * w.scale, r.width) - 4 * w.scale),
					ui.HEIGHT_TOOLBAR * w.scale,
				},
				.Fits
		}
		r := rail_new_tab_rect(w)
		inset := 2 * w.scale
		return {
				r.x + inset,
				r.y + inset,
				max(0, min(180 * w.scale, r.width) - 2 * inset),
				max(0, r.height - 2 * inset),
			},
			.Fits
	case Drop_Swap:
		for pane in w.panes {if pane.node == d.target {return pane.rect, .Fits}}
	case Drop_Pane:
		return pane_drag_trial(app, carry, w, d.tab, d.target, d.direction, false)
	case Drop_Dock_Root:
		return pane_drag_trial(app, carry, w, d.tab, d.target, d.direction, true)
	case Drop_Reorder, Drop_Other_Window, Drop_Workspace_Dropdown, Drop_Tear_Off:
	}
	return {}, .Refused
}

@(private)
pane_drag_trial :: proc(
	app: ^App,
	carry: ^Pane_Carry,
	w: ^Window,
	destination: ^Tab,
	target: layout.Node_Id,
	direction: layout.Direction,
	root: bool,
) -> (
	layout.Rect,
	Drop_Fit,
) {
	result: Pane_Trial_Result
	// A pane returning to the window that owns its tab is still in that tree under its slot, so the
	// trial must move it there rather than copy it across from the linked window's view.
	home, source_linked := Pane_Link_Home{}, false
	if source_pane, is_pane := carry.source.tree.nodes[carry.node].(layout.Pane); is_pane {
		home, source_linked = pane_link_home(app, source_pane.content)
	}
	if source_linked && !window_linked(w) && destination == home.tab {
		result = pane_trial_move(app, w, &home.tab.tree, &home.tab.tree, home.node, target, direction, root)
	} else {
		result = pane_trial_move(app, w, &carry.source.tree, &destination.tree, carry.node, target, direction, root)
	}
	#partial switch result.error {
	case .None:
		return result.rect, .Fits
	case .Minimum:
		return result.rect, .Too_Small
	}
	return result.rect, .Refused
}

// Whether the outline shows: a destination the pane fits, or a tear-off with its window prepared.
@(private)
pane_drag_ghost_shown :: proc(a: ^Drag_Active) -> bool {
	if _, tear_off := a.destination.(Drop_Tear_Off); tear_off {
		_, ready := a.preview.(Preview_Ready)
		return ready
	}
	fit, placed := pane_drop_fit(a.destination)
	return placed && fit == .Fits
}

@(private)
pane_drop_fit :: proc(destination: Drag_Destination) -> (Drop_Fit, bool) {
	#partial switch d in destination {
	case Drop_Pane:
		return d.fit, true
	case Drop_Swap:
		return d.fit, true
	case Drop_Dock_Root:
		return d.fit, true
	case Drop_New_Tab:
		return d.fit, true
	}
	return .Refused, false
}

// The same place to land, whatever the fit.
@(private)
pane_drop_same :: proc(a, b: Drag_Destination) -> bool {
	switch x in a {
	case nil:
		return b == nil
	case Drop_Pane:
		y, ok := b.(Drop_Pane)
		return ok && x.window == y.window && x.tab == y.tab && x.target == y.target && x.direction == y.direction
	case Drop_Swap:
		y, ok := b.(Drop_Swap)
		return ok && x.window == y.window && x.target == y.target
	case Drop_Dock_Root:
		y, ok := b.(Drop_Dock_Root)
		return ok && x.window == y.window && x.tab == y.tab && x.target == y.target && x.direction == y.direction
	case Drop_New_Tab:
		y, ok := b.(Drop_New_Tab)
		return ok && x.window == y.window && x.tab == y.tab
	case Drop_Reorder, Drop_Other_Window, Drop_Workspace_Dropdown, Drop_Tear_Off:
	}
	return false
}

// Tracks a header drag; returns whether the drag owns the pointer.
pane_drag_move :: proc(app: ^App, w: ^Window, x, y: f32, swap: bool) -> bool {
	if grab, passed := drag_threshold_passed(w, x, y); passed {
		pane, is_pane := grab.(Pane_Grab)
		if !is_pane {return false}
		visit := Drag_Visit{window = w.id, original_index = w.workspace.selected}
		_ = drag_activate(w, Pane_Carry{grab = pane, visit = visit}, x, y)
	}
	a, carry := pane_drag_state(w)
	if a == nil {return false}
	a.pointer = {x, y}
	point, point_ok := drag_point(app, w, x, y)
	if !point_ok {pane_drag_cancel(app, w); return true}
	destination := point.window
	changed_window := pane_drag_visit(app, w, carry, destination)
	if destination == nil {
		pane_drag_outside(app, w, a, carry, swap, point)
		return true
	}
	return pane_drag_target_move(app, w, a, carry, destination, f32(point.x), f32(point.y), swap, changed_window)
}

// Moves the visit to the window under the pointer, showing again the tab the previous one showed. Returns
// whether the window changed.
@(private)
pane_drag_visit :: proc(app: ^App, w: ^Window, carry: ^Pane_Carry, destination: ^Window) -> bool {
	visit := &carry.visit
	previous := visit.window
	if previous == w.id && destination != w && selected_tab(w.workspace) != carry.source {
		pane_drag_show_source(app, w, carry.source)
	}
	id := destination == nil ? 0 : destination.id
	if id == previous {return false}
	if old := window_find(app, previous); old != nil && old != w {
		for tab, i in old.workspace.tabs {
			if tab == visit.original {tab_select(app, old, i, true); break}
		}
		old.dirty = true
	}
	visit.window, visit.original, visit.hover = id, nil, nil
	if destination != nil && destination != w {
		visit.original = selected_tab(destination.workspace)
		visit.original_index = destination.workspace.selected
	}
	return true
}

// Past every app window the drag offers a window of its own, when its source can lose the pane; while Shift
// is held it offers nothing there.
@(private)
pane_drag_outside :: proc(
	app: ^App,
	w: ^Window,
	a: ^Drag_Active,
	carry: ^Pane_Carry,
	swap: bool,
	point: Drag_Point,
) {
	next: Drag_Destination
	if swap {
	} else if pane_window_source_can_lose(app, carry.source, carry.node) {
		next = Drop_Tear_Off{}
		_ = tear_off_preview_ensure(app, a, true)
	} else {
		tear_off_preview_discard(app, a)
	}
	drag_retarget(app, w, a, next)
	_, tear_off := next.(Drop_Tear_Off)
	shown := pane_drag_ghost_shown(a)
	pane_drag_thumbnail_sync(app, w, a, carry, shown, point.screen_x, point.screen_y)
	rect: layout.Rect
	if tear_off {for pane in w.panes {if pane.node == carry.node {rect = pane.rect; break}}}
	values := [4]f32{rect.x, rect.y, rect.width, rect.height}
	for &m, i in carry.ghost {ui.motion_target(&m, values[i], 0, .Linear, false, time.tick_now())}
	w.dirty = true
}

@(private)
pane_drag_target_move :: proc(
	app: ^App,
	source_window: ^Window,
	a: ^Drag_Active,
	carry: ^Pane_Carry,
	w: ^Window,
	x, y: f32,
	swap, changed_window: bool,
) -> bool {
	if !window_linked(w) && pane_workspace_drag_move(app, source_window, w, x, y, swap) {return true}
	title_height := window_title_height(w)
	destination := selected_tab(w.workspace)
	now := time.tick_now()
	on_tab := -1
	over_rail, rail_new_tab := false, false
	if w.tabs_horizontal {
		bar := window_tab_bar(app, w)
		on_tab = window_tab_hit(app, w, bar, x, y)
		if on_tab >= 0 && on_tab < bar.count {
			destination = w.workspace.tabs[on_tab]
		}
	} else {
		rail_tab, new_tab_target, over := rail_pane_target(w, x, y)
		over_rail, rail_new_tab = over, new_tab_target
		if over && rail_tab >= 0 {
			on_tab = rail_tab
			if rail_tab < len(w.workspace.tabs) {destination = w.workspace.tabs[rail_tab]}
		}
	}
	// A floating window covers the rail and the tiling's edge bands: a drop over it lands on its panes.
	_, _, over_float := floating_frame_at(w, x, y)
	if over_float {
		on_tab, over_rail, rail_new_tab = -1, false, false
		destination = selected_tab(w.workspace)
	}
	new_tab := !swap && !window_linked(w) &&
		(w.tabs_horizontal
				? ui.tab_drop_hit(window_tab_bar(app, w), f32(w.width), w.scale, x, y)
				: over_rail && rail_new_tab)
	pane_drag_hover(app, source_window, carry, w, destination, on_tab, swap, now)
	target, direction := layout.INVALID_NODE, layout.Direction.Left
	root := false
	area := window_content_area(app, w)
	band := min(24 * w.scale, area.width / 5, area.height / 5)
	if destination != nil && on_tab >= 0 && on_tab < len(w.workspace.tabs) {
		if destination != carry.source && !swap {target, direction = destination.tree.focus, .Right}
	} else if !over_rail &&
	   destination != nil &&
	   x >= 0 &&
	   x < f32(w.width) &&
	   y >= title_height &&
	   y < f32(w.height) {
		if !swap && !over_float &&
		   (x < area.x + band ||
				   x >= area.x + area.width - band ||
				   y < area.y + band ||
				   y >= area.y + area.height - band) {
			root, direction, target = true, nearest_side(area, x, y), destination.tree.focus
			if destination == carry.source &&
			   carry.node == destination.tree.root {target, root = layout.INVALID_NODE, false}
		} else if pane, found := layout.hit_test(w.panes[:], x, y);
		   found && (destination != carry.source || pane.node != carry.node) {
			target, direction = pane.node, nearest_side(pane.rect, x, y)
		}
	}
	if swap && destination != carry.source {target = layout.INVALID_NODE}
	next: Drag_Destination
	switch {
	case new_tab:
		next = Drop_New_Tab{w.id, destination, .Fits}
	case target == layout.INVALID_NODE:
	case swap:
		next = Drop_Swap{w.id, target, .Fits}
	case root:
		next = Drop_Dock_Root{w.id, destination, target, direction, .Fits}
	case:
		next = Drop_Pane{w.id, destination, target, direction, .Fits}
	}
	if pane_drop_same(a.destination, next) && !changed_window {return true}
	rect, fit := pane_drag_preview(app, carry, next)
	#partial switch &d in next {
	case Drop_Pane:
		d.fit = fit
	case Drop_Swap:
		d.fit = fit
	case Drop_Dock_Root:
		d.fit = fit
	case Drop_New_Tab:
		d.fit = fit
	}
	shown := pane_drag_ghost_shown(a)
	drag_retarget(app, source_window, a, next)
	// The ghost fades in on every drop kind, so crossing between the tab strip and a pane
	// never flashes between faded and opaque.
	ui.motion_target(&carry.reveal, 1, GHOST_DURATION, .Decelerate, app.animations, now)
	w.dirty = true
	source_window.dirty = true
	values := [4]f32{rect.x, rect.y, rect.width, rect.height}
	for &m, i in carry.ghost {
		ui.motion_target(&m, values[i], GHOST_DURATION, .Decelerate, app.animations && shown, now)
	}
	return true
}

// Resting on another tab of the window shows it after a moment; it must not move the tab marked selection.
// A drag from a linked window never arms the switch: pane_links_sync shows a linked window only while its own
// tab is on screen, so switching away would hide the window being dragged from.
pane_drag_hover :: proc(
	app: ^App,
	source_window: ^Window,
	carry: ^Pane_Carry,
	w: ^Window,
	destination: ^Tab,
	on_tab: int,
	swap: bool,
	now: time.Tick,
) {
	visit := &carry.visit
	if destination == nil ||
	   destination == selected_tab(w.workspace) ||
	   on_tab < 0 ||
	   swap ||
	   window_linked(source_window) {
		visit.hover = nil
		return
	}
	hover, armed := visit.hover.?
	if !armed || hover.tab != destination {
		visit.hover = Drag_Hover{destination, time.tick_add(now, DRAG_HOVER_DELAY)}
	} else if time.tick_diff(now, hover.at) <= 0 {
		tab_select(app, w, on_tab, true)
		visit.hover = nil
	}
}

// A pane drop's destination, resolved for the procs that carry it out.
@(private)
Pane_Drop :: struct {
	window:              platform.Window_Id,
	tab:                 ^Tab,
	target:              layout.Node_Id,
	direction:           layout.Direction,
	root, swap, new_tab: bool,
	fit:                 Drop_Fit,
}

@(private)
pane_drop_resolve :: proc(carry: ^Pane_Carry, destination: Drag_Destination) -> (Pane_Drop, bool) {
	#partial switch d in destination {
	case Drop_Pane:
		return {window = d.window, tab = d.tab, target = d.target, direction = d.direction, fit = d.fit}, true
	case Drop_Swap:
		return {window = d.window, tab = carry.source, target = d.target, swap = true, fit = d.fit}, true
	case Drop_Dock_Root:
		return {
				window = d.window,
				tab = d.tab,
				target = d.target,
				direction = d.direction,
				root = true,
				fit = d.fit,
			},
			true
	case Drop_New_Tab:
		return {window = d.window, tab = d.tab, target = layout.INVALID_NODE, new_tab = true, fit = d.fit}, true
	}
	return {}, false
}

// Finishes a header drag; a drop outside another pane leaves the layout unchanged.
pane_drag_release :: proc(app: ^App, w: ^Window) -> bool {
	if _, held := pane_drag_grab(w); !held {return false}
	d := drag_end(w)
	a, active := &d.(Drag_Active)
	if !active {return false}
	carry := &a.carry.(Pane_Carry)
	drag_thumbnail_destroy(&a.thumbnail)
	#partial switch held in a.destination {
	case Drop_Workspace_Dropdown:
		pane_workspace_drag_release(app, w, a, held)
		return true
	case Drop_Tear_Off:
		_, ready := a.preview.(Preview_Ready)
		if ready && tear_off_commit(app, w, a) {
			drag_free(app, a)
			return true
		}
		drag_let_go(app, w, a)
		pane_drag_restore(app, w, carry)
		if ready {notify(app, .Error, "Could not move the pane. The source was preserved.")}
		return true
	}
	drop, placed := pane_drop_resolve(carry, a.destination)
	drag_let_go(app, w, a)
	destination_window := placed ? window_find(app, drop.window) : nil
	if destination_window == nil {pane_drag_restore(app, w, carry); return true}
	destination_window.dirty = true
	if destination_window != w {pane_drag_show_source(app, w, carry.source)}
	if drop.fit != .Fits {
		if drop.fit == .Too_Small {
			notify(
				app,
				.Warning,
				fmt.tprintf(
					"Can't dock: minimum %d × %d content cells. " +
					"Change Minimum Pane Width and Height in Settings.",
					app.settings.pane.minimum_columns,
					app.settings.pane.minimum_rows,
				),
			)
		}
		pane_drag_restore(app, w, carry)
		return true
	}
	if drop.new_tab {
		if window_linked(w) {
			if !pane_link_new_tab(app, w, destination_window, carry.grab) {pane_drag_restore(app, w, carry)}
		} else if !pane_to_tab(app, destination_window, carry.source, carry.node) {
			pane_drag_restore(app, w, carry)
		}
		return true
	}
	if (window_linked(w) || window_linked(destination_window)) && destination_window != w {
		if pane_link_drag_release(app, w, destination_window, carry.grab, drop) {return true}
		pane_drag_restore(app, w, carry)
		notify(app, .Error, "Could not move the pane. The source was preserved.")
		return true
	}
	if drop.tab != carry.source {
		if !pane_transfer(
			app,
			destination_window,
			carry.source,
			drop.tab,
			carry.node,
			drop.target,
			drop.direction,
			drop.root,
		) {
			pane_drag_restore(app, w, carry)
			notify(app, .Error, "Could not move the pane. Both tabs were preserved.")
		}
		return true
	}
	pane_rearrange(app, w, carry.node, drop.target, drop.direction, drop.swap, drop.root)
	return true
}

// A rest on another tab switches to it when its moment is up.
pane_drag_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	at, armed := drag_hover_deadline(w)
	if !armed || time.tick_diff(now, at) > 0 {return}
	a := drag_active(w)
	_ = pane_drag_move(app, w, a.pointer.x, a.pointer.y, false)
}

pane_drag_animating :: proc(w: ^Window) -> bool {
	_, carry := pane_drag_state(w)
	if carry == nil {return false}
	if ui.motion_active(carry.reveal) {return true}
	for m in carry.ghost {if ui.motion_active(m) {return true}}
	return false
}

pane_drag_animate :: proc(app: ^App, w: ^Window, enabled: bool, now: time.Tick) {
	_, carry := pane_drag_state(w)
	if carry == nil {return}
	if !enabled && pane_drag_animating(w) {
		for &m in carry.ghost {m.value = m.target}
		carry.reveal.value = carry.reveal.target
		w.dirty = true
		return
	}
	if ui.motion_update(&carry.reveal, now) {w.dirty = true}
	for &m in carry.ghost {if ui.motion_update(&m, now) {w.dirty = true}}
	if w.dirty {
		if target := window_find(app, carry.visit.window); target != nil {target.dirty = true}
	}
}

// The label a drop would produce, independent of its drawing.
@(require_results)
pane_drag_label :: proc(grab: Pane_Grab, destination: Drag_Destination) -> string {
	#partial switch d in destination {
	case Drop_New_Tab:
		if d.tab == grab.source && grab.node == grab.source.tree.root {
			return "Move tab to end"
		}
		return "+ New tab"
	case Drop_Swap:
		return "Swap panes"
	case Drop_Dock_Root:
		return "Dock to workspace edge"
	}
	return "Move pane here"
}

// The outline of a pane drop: in the window it lands in, or around the pane a tear-off takes from its own.
pane_drag_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	a, carry := pane_drag_state(w)
	if a != nil {
		if _, tear_off := a.destination.(Drop_Tear_Off); !tear_off {a = nil}
	}
	for source in app.windows {
		if sa, sc := pane_drag_state(source); sa != nil && drag_destination_window(sa.destination) == w.id {
			a, carry = sa, sc
			break
		}
	}
	if a == nil || !pane_drag_ghost_shown(a) {return .Ok}
	r := render.Rect{carry.ghost[0].value, carry.ghost[1].value, carry.ghost[2].value, carry.ghost[3].value}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	radius := f32(app.settings.pane.corner_radius) * w.scale
	// The thumbnail copies this pane live, so a tear-off marks it with an outline and nothing over its text.
	if _, tear_off := a.destination.(Drop_Tear_Off); tear_off {
		_ = render.push_rect(
			&w.list,
			{rect = r, color = app.theme.accent, radius = radius, stroke = 2 * w.scale},
		)
		return .Ok
	}
	opacity := carry.reveal.value
	fill := app.theme.accent
	fill.a = 0.16 * opacity
	if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None {return .Ok}
	r = {carry.ghost[0].target, carry.ghost[1].target, carry.ghost[2].target, carry.ghost[3].target}
	accent := app.theme.accent
	accent.a *= opacity
	if render.push_rect(
		   &w.list,
		   {rect = r, color = accent, radius = radius, stroke = 2 * w.scale},
	   ) !=
	   .None {return .Ok}
	label := pane_drag_label(carry.grab, a.destination)
	text := ui.text_styled(&w.ui_text, .Strong)
	width := ui.text_width(&text, label)
	label_color := app.theme.text
	label_color.a *= opacity
	return ui.draw_text(
		&text,
		&w.list,
		label,
		r.x + (r.width - width) / 2,
		r.y + (r.height - text.line_height) / 2 + text.ascent,
		label_color,
		max(1, r.width - 16 * w.scale),
	)
}

// Ends every pointer arrangement gesture, restoring a dragged tab to its starting position. A drag from
// another window that reaches w ends too.
arrange_cancel :: proc(app: ^App, w: ^Window) {
	id := w.id
	// Cancellation may destroy a preview and remove it from the registry.
	for i := len(app.windows) - 1; i >= 0; i -= 1 {
		if i >= len(app.windows) {continue}
		other := app.windows[i]
		if other != w && drag_involves(other, id) {
			gesture_clear(app, other)
			pane_drag_cancel(app, other)
			tab_drag_cancel(app, other)
		}
	}
	if window_find(app, id) == nil {return}
	w.dragging = {}
	tab_drag_cancel(app, w)
	pane_drag_cancel(app, w)
}
