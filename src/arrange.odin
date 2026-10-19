package main

import "core:math"
import "core:fmt"
import "core:time"
import "aio:glyphs"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:ui"

@(private) DOUBLE_CLICK_NS :: i64(500_000_000)
@(private) DRAG_THRESHOLD :: 5
@(private) GHOST_DURATION :: 120*time.Millisecond

// Splits whose dividers meet under the pointer move together, outermost first.
Divider_Drag :: struct {
	nodes: [4]layout.Node_Id,
	count: int,
}

// A header press that becomes a pane move, or a swap while Shift is held, once it passes the threshold.
Pane_Drag :: struct {
	source, destination, hover: ^Tab,
	hover_until: time.Tick,
	node, target: layout.Node_Id,
	direction: layout.Direction,
	start, pointer: [2]f32,
	pressed, active, swap, shown, root, new_tab: bool,
	minimum_rejected: bool,
	destination_window, preview_window: platform.Window_Id,
	destination_original: ^Tab,
	new_window, preview_failed: bool,
	ghost: [4]ui.Motion,
	reveal: ui.Motion,
}

// A tab press that reorders the strip once it passes the threshold.
Tab_Drag :: struct {
	grabbed: ^Tab,
	order: [dynamic]^Tab,
	start, offset: f32,
	rank: int,
	pressed, active, modified: bool,
}

@(private)
divider_hits :: proc(w: ^Window, x, y: f32, out: []layout.Divider) -> int {
	return layout.divider_hit_all(w.dividers[:], x, y, 3*w.scale, out, 10*w.scale, 2*w.scale)
}

// Starts a divider drag, or on a second click of the same divider balances the splits it belongs to.
divider_press :: proc(app: ^App, w: ^Window, x, y: f32, time_ns: i64) -> bool {
	hits: [4]layout.Divider
	n := divider_hits(w, x, y, hits[:])
	if n == 0 { return false }
	w.selecting, w.autoscrolling = false, false
	if hits[0].node == w.divider_click_node && time_ns-w.divider_click_ns <= DOUBLE_CLICK_NS {
		w.divider_click_node = layout.INVALID_NODE
		balanced := false
		for d in hits[:n] { balanced = layout.balance_related(w.tree, d.node) || balanced }
		if balanced { window_relayout(app, w) }
		return true
	}
	w.divider_click_node, w.divider_click_ns = hits[0].node, time_ns
	w.dragging = {count = n}
	for d, i in hits[:n] { w.dragging.nodes[i] = d.node }
	return true
}

// Each split takes the pointer position on its own axis. Divider areas are refreshed after every move,
// because an outer split resizes the region of the splits nested inside it.
divider_drag :: proc(app: ^App, w: ^Window, x, y: f32) {
	gap := window_gap(app, w)
	area := window_content_area(app, w)
	moved := false
	for node in w.dragging.nodes[:w.dragging.count] {
		for d in w.dividers {
			if d.node != node { continue }
			if layout.drag_divider(w.tree, d, x, y, gap) {
				moved = true
				layout.dividers(w.tree, area, gap, &w.dividers)
			}
			break
		}
	}
	if moved { window_relayout(app, w) }
}

divider_cursor :: proc(w: ^Window, x, y: f32) -> (platform.Cursor_Shape, bool) {
	hits: [4]layout.Divider
	n := divider_hits(w, x, y, hits[:])
	if n == 0 { return .Arrow, false }
	axes: bit_set[layout.Axis]
	for d in hits[:n] { axes += {d.axis} }
	if axes == {.Horizontal, .Vertical} { return .Resize_All, true }
	return .Horizontal in axes ? .Resize_Horizontal : .Resize_Vertical, true
}

tab_press :: proc(w: ^Window, index: int, x, width: f32, modified: bool) {
	if !w.workspace.tabs[index].marked { return }
	w.tab_drag = {grabbed = w.workspace.tabs[index], start = x,
		offset = x-workspace_button_width(w)-tab_position(w, index)*width, pressed = true, modified = modified}
}

// Moves a tab and everything indexed by tab position, keeping the selected tab selected.
tab_move :: proc(app: ^App, w: ^Window, from, to: int) {
	tabs := &w.workspace.tabs
	if from == to || from < 0 || to < 0 || from >= len(tabs) || to >= len(tabs) { return }
	tab := tabs[from]
	ordered_remove(tabs, from)
	inject_at(tabs, to, tab)
	if from < len(w.tab_controls) && to < len(w.tab_controls) {
		control := w.tab_controls[from]
		ordered_remove(&w.tab_controls, from)
		inject_at(&w.tab_controls, to, control)
	}
	if from < len(w.tab_positions) && to < len(w.tab_positions) {
		position := w.tab_positions[from]
		ordered_remove(&w.tab_positions, from)
		inject_at(&w.tab_positions, to, position)
	}
	selected := w.workspace.selected
	switch {
	case selected == from: selected = to
	case from < selected && selected <= to: selected -= 1
	case to <= selected && selected < from: selected += 1
	}
	w.workspace.selected = selected
	w.tree = &selected_tab(w.workspace).tree
	ui.motion_target(&w.tab_underline, f32(selected), 0, .Linear, false, time.tick_now())
	mark_all_dirty(app)
}

tab_drag_move :: proc(app: ^App, w: ^Window, x: f32) -> bool {
	d := &w.tab_drag
	if !d.pressed { return false }
	if !d.active && abs(x-d.start) < DRAG_THRESHOLD*w.scale { return false }
	if !d.active {
		order, err := make([dynamic]^Tab, len(w.workspace.tabs))
		if err != nil {
			w.tab_drag = {}
			notify(app, .Error, "Could not begin tab dragging.")
			return true
		}
		copy(order[:], w.workspace.tabs[:])
		d.order = order
		for tab in order { if tab == d.grabbed { break }; if tab.marked { d.rank += 1 } }
		d.active = true
	}
	bar := window_tab_bar(app, w)
	if bar.tab_width <= 0 { return true }
	marked, mark_error := make([]bool, len(d.order), context.temp_allocator)
	if mark_error != nil { tab_drag_cancel(app, w); notify(app, .Error, "Could not move tabs."); return true }
	count := 0
	for tab, i in d.order { marked[i] = tab.marked; if tab.marked { count += 1 } }
	first := clamp((x-bar.x-d.offset)/bar.tab_width-f32(d.rank), 0, f32(len(d.order)-count))
	slot := int(math.floor(first+0.5))
	order, order_error := make([]int, len(d.order), context.temp_allocator)
	if order_error != nil { tab_drag_cancel(app, w); notify(app, .Error, "Could not move tabs."); return true }
	if !ui.tab_group_order(marked, slot, order) { return true }
	for original, to in order {
		for tab, from in w.workspace.tabs {
			if tab == d.order[original] { tab_move(app, w, from, to); break }
		}
	}
	rank := 0
	now := time.tick_now()
	for tab, i in w.workspace.tabs {
		if !tab.marked { continue }
		if i < len(w.tab_positions) {
			ui.motion_target(&w.tab_positions[i], first+f32(rank), 0, .Linear, false, now)
		}
		rank += 1
	}
	w.dirty = true
	return true
}

tab_drag_cancel :: proc(app: ^App, w: ^Window) {
	if w.tab_drag.pressed { w.dirty = true }
	for tab, to in w.tab_drag.order {
		for current, from in w.workspace.tabs { if current == tab { tab_move(app, w, from, to); break } }
	}
	delete(w.tab_drag.order)
	w.tab_drag = {}
}

tab_drag_release :: proc(w: ^Window) {
	if !w.tab_drag.active && !w.tab_drag.modified { tab_select_one(w.workspace, w.workspace.selected) }
	delete(w.tab_drag.order)
	w.tab_drag = {}
	w.dirty = true
}

pane_drag_press :: proc(app: ^App, w: ^Window, node: layout.Node_Id, x, y: f32) {
	for i := len(app.windows)-1; i >= 0; i -= 1 {
		if i < len(app.windows) && app.windows[i] != w { pane_drag_cancel(app, app.windows[i]) }
	}
	source := selected_tab(w.workspace)
	w.pane_drag = {source = source, destination = source, node = node,
		destination_window = w.id, target = layout.INVALID_NODE, start = {x, y}, pressed = true}
}

@(private)
pane_drag_restore :: proc(app: ^App, w: ^Window, d: Pane_Drag) {
	if destination := window_find(app, d.destination_window); destination != nil && destination != w {
		for tab, i in destination.workspace.tabs {
			if tab == d.destination_original { tab_select(app, destination, i, true); break }
		}
		destination.dirty = true
	}
	for tab, i in w.workspace.tabs { if tab == d.source { tab_select(app, w, i, true); break } }
}

pane_drag_cancel :: proc(app: ^App, w: ^Window) {
	d := w.pane_drag
	w.pane_drag = {}
	if !d.pressed { return }
	w.dirty = true
	if d.preview_window != 0 { pane_window_preview_discard(app, d.preview_window) }
	pane_drag_restore(app, w, d)
}

// The edge of `r` nearest to the point, as the side the dragged pane will take.
@(private)
nearest_side :: proc(r: layout.Rect, x, y: f32) -> layout.Direction {
	left, right := (x-r.x)/max(1, r.width), (r.x+r.width-x)/max(1, r.width)
	top, bottom := (y-r.y)/max(1, r.height), (r.y+r.height-y)/max(1, r.height)
	nearest := min(left, right, top, bottom)
	switch nearest {
	case left: return .Left
	case right: return .Right
	case top: return .Up
	}
	return .Down
}

// Where the dragged pane would land: the target's card for a swap, otherwise its card in a trial layout.
@(private)
pane_drag_preview :: proc(app: ^App, source_window: ^Window) -> (layout.Rect, bool) {
	d := &source_window.pane_drag
	if d.new_window {
		for pane in source_window.panes { if pane.node == d.node { return pane.rect, d.preview_window != 0 } }
		return {}, false
	}
	destination := window_find(app, d.destination_window)
	if destination == nil { return {}, false }
	w := destination
	if d.new_tab {
		pane := d.source.tree.nodes[d.node].(layout.Pane)
		panes := [?]layout.Pane_Rect{{content = pane.content, rect = window_content_area(app, w)}}
		reorders_tab := pane_source_workspace(app, d.source) == w.workspace && d.node == d.source.tree.root
		d.minimum_rejected = !reorders_tab && !pane_minimum_allows(app, w, panes[:], nil, false)
		if d.minimum_rejected { return {}, false }
		r := ui.tab_drop_region(window_tab_bar(app, w), f32(w.width), w.scale)
		return {r.x+2*w.scale, 6*w.scale, max(0, min(180*w.scale, r.width)-4*w.scale), 28*w.scale}, true
	}
	if d.destination == nil || (d.target == layout.INVALID_NODE && !d.root) { return {}, false }
	if d.swap {
		if d.destination != d.source { return {}, false }
		for pane in w.panes { if pane.node == d.target { return pane.rect, true } }
		return {}, false
	}
	trial := d.destination.tree
	trial.zoomed = false
	trial.nodes = make([dynamic]layout.Node, len(trial.nodes), len(trial.nodes)+2, context.temp_allocator)
	copy(trial.nodes[:], d.destination.tree.nodes[:])
	content := d.source.tree.nodes[d.node].(layout.Pane).content
	moved := false
	if d.destination != d.source {
		source := d.source.tree
		source.nodes = make([dynamic]layout.Node, len(source.nodes), context.temp_allocator)
		copy(source.nodes[:], d.source.tree.nodes[:])
		_, moved = layout.transfer_pane(&source, &trial, d.node, d.target, d.direction, d.root)
	} else if d.root { _, moved = layout.dock_pane(&trial, d.node, d.direction) }
	else { _, moved = layout.move_pane(&trial, d.node, d.target, d.direction) }
	if !moved { return {}, false }
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(&trial, window_content_area(app, w), window_gap(app, w), &rects)
	before := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	original := d.destination.tree
	original.zoomed = false
	layout.compute(&original, window_content_area(app, w), window_gap(app, w), &before)
	d.minimum_rejected = !pane_minimum_allows(app, w, rects[:], before[:], false)
	if d.minimum_rejected { return {}, false }
	for r in rects { if r.content == content { return r.rect, true } }
	return {}, false
}

// Tracks a header drag; returns whether the drag owns the pointer.
pane_drag_move :: proc(app: ^App, w: ^Window, x, y: f32, swap: bool) -> bool {
	d := &w.pane_drag
	if !d.pressed { return false }
	if !d.active && math.hypot(x-d.start.x, y-d.start.y) < DRAG_THRESHOLD*w.scale { return false }
	d.active = true
	d.pointer = {x, y}
	sx, sy, screen_error := platform.window_to_screen(&app.platform, w.id, i32(x), i32(y))
	if screen_error != .None { pane_drag_cancel(app, w); return true }
	if preview := window_find(app, d.preview_window); preview != nil && preview.preview_visible {
		if !pane_window_preview_position(app, preview, sx, sy) { pane_drag_cancel(app, w); return true }
	}
	id, tx, ty, hit_error := platform.window_at_point(&app.platform, sx, sy)
	if hit_error != .None { pane_drag_cancel(app, w); return true }
	destination := window_find(app, id)
	// Controller-driven client events may be delivered to an inactive, occluded source.
	if app.options.inactive && destination == nil && x >= 0 && y >= 0 && x < f32(w.width) && y < f32(w.height) {
		destination, tx, ty = w, i32(x), i32(y)
	}
	if destination != nil && destination.preparing { destination = nil }
	previous := d.destination_window
	if previous == w.id && destination != w && selected_tab(w.workspace) != d.source {
		for tab, i in w.workspace.tabs { if tab == d.source { tab_select(app, w, i, true); break } }
	}
	if destination == nil || destination.id != previous {
		if old := window_find(app, previous); old != nil && old != w {
			for tab, i in old.workspace.tabs {
				if tab == d.destination_original { tab_select(app, old, i, true); break }
			}
			old.dirty = true
		}
		d.destination_original = nil
		d.hover, d.hover_until = nil, {}
	}
	if destination == nil {
		d.destination_window, d.destination, d.target = 0, nil, layout.INVALID_NODE
		d.new_tab, d.new_window, d.swap = false, !swap, swap
		if !swap && d.preview_window == 0 && !d.preview_failed {
			if preview := pane_window_preview_create(app, d.source, d.node, sx, sy); preview != nil {
				d.preview_window = preview.id
			} else {
				d.preview_failed = true
				notify(app, .Error, "Could not prepare a new window. The pane was preserved.")
			}
		}
		if !swap {
			if preview := window_find(app, d.preview_window); preview != nil && !preview.preview_visible {
				if !pane_window_preview_position(app, preview, sx, sy) || !window_show_prepared(app, preview) {
					pane_drag_cancel(app, w)
					return true
				}
			}
		}
		if swap && d.preview_window != 0 {
			if !pane_window_preview_hide(app, d.preview_window) { pane_drag_cancel(app, w); return true }
		}
		rect, shown := pane_drag_preview(app, w)
		d.shown = shown
		values := [4]f32{rect.x, rect.y, rect.width, rect.height}
		for &m, i in d.ghost { ui.motion_target(&m, values[i], 0, .Linear, false, time.tick_now()) }
		w.dirty = true
		return true
	}
	if d.preview_window != 0 {
		if !pane_window_preview_hide(app, d.preview_window) { pane_drag_cancel(app, w); return true }
	}
	if destination.id != previous && destination != w { d.destination_original = selected_tab(destination.workspace) }
	d.destination_window = destination.id
	d.new_window, d.preview_failed = false, false
	return pane_drag_target_move(app, w, destination, f32(tx), f32(ty), swap, previous != destination.id)
}

@(private)
pane_drag_target_move :: proc(app: ^App, source_window, w: ^Window, x, y: f32, swap, changed_window: bool) -> bool {
	d := &source_window.pane_drag
	bar := window_tab_bar(app, w)
	destination := selected_tab(w.workspace)
	now := time.tick_now()
	on_tab := window_tab_hit(w, bar, x, y)
	new_tab := !swap && ui.tab_drop_hit(bar, f32(w.width), w.scale, x, y)
	if on_tab >= 0 && on_tab < bar.count {
		tab := w.workspace.tabs[on_tab]
		if root, settings := tab.tree.nodes[tab.tree.root].(layout.Pane); settings && root.content.kind == .Settings {
			destination = nil
		} else { destination = tab }
	}
	if destination != nil && destination != selected_tab(w.workspace) && on_tab >= 0 && !swap {
		if d.hover != destination {
			d.hover, d.hover_until = destination, time.tick_add(now, 350*time.Millisecond)
		} else if time.tick_diff(now, d.hover_until) <= 0 {
			tab_select(app, w, on_tab)
			d.hover_until = {}
		}
	} else { d.hover, d.hover_until = nil, {} }
	target, direction := layout.INVALID_NODE, layout.Direction.Left
	root := false
	area := window_content_area(app, w)
	band := min(24*w.scale, area.width/5, area.height/5)
	if destination != nil && on_tab >= 0 && on_tab < bar.count {
		if destination != d.source && !swap { target, direction = destination.tree.focus, .Right }
	} else if destination != nil && x >= 0 && x < f32(w.width) && y >= bar.height && y < f32(w.height) {
		if !swap && (x < area.x+band || x >= area.x+area.width-band ||
		   y < area.y+band || y >= area.y+area.height-band) {
			root, direction, target = true, nearest_side(area, x, y), destination.tree.focus
			if destination == d.source && d.node == destination.tree.root { target, root = layout.INVALID_NODE, false }
		} else if pane, found := layout.hit_test(w.panes[:], x, y);
		          found && (destination != d.source || pane.node != d.node) {
			target, direction = pane.node, nearest_side(pane.rect, x, y)
		}
	}
	if swap && destination != d.source { target = layout.INVALID_NODE }
	if target == d.target && direction == d.direction && swap == d.swap && root == d.root &&
	   destination == d.destination && new_tab == d.new_tab && !changed_window { return true }
	d.target, d.direction, d.swap, d.root, d.destination = target, direction, swap, root, destination
	d.new_tab = new_tab
	d.minimum_rejected = false
	ui.motion_target(&d.reveal, new_tab ? 1 : 0, GHOST_DURATION, .Decelerate, app.animations, now)
	w.dirty = true
	source_window.dirty = true
	rect, shown := pane_drag_preview(app, source_window)
	values := [4]f32{rect.x, rect.y, rect.width, rect.height}
	for &m, i in d.ghost {
		ui.motion_target(&m, values[i], GHOST_DURATION, .Decelerate, app.animations && d.shown, now)
	}
	d.shown = shown
	return true
}

// Finishes a header drag; a drop outside another pane leaves the layout unchanged.
pane_drag_release :: proc(app: ^App, w: ^Window) -> bool {
	d := w.pane_drag
	w.pane_drag = {}
	if !d.active { return false }
	w.dirty = true
	if d.new_window {
		if d.shown && pane_to_window(app, w, d.source, d.node, d.preview_window) { return true }
		pane_window_preview_discard(app, d.preview_window)
		pane_drag_restore(app, w, d)
		return true
	}
	if d.preview_window != 0 { pane_window_preview_discard(app, d.preview_window) }
	destination_window := window_find(app, d.destination_window)
	if destination_window != nil { destination_window.dirty = true }
	if destination_window == nil { pane_drag_restore(app, w, d); return true }
	if destination_window != w {
		for tab, i in w.workspace.tabs { if tab == d.source { tab_select(app, w, i, true); break } }
	}
	if d.new_tab && d.shown {
		if !pane_to_tab(app, destination_window, d.source, d.node) { pane_drag_restore(app, w, d) }
		return true
	}
	if d.target == layout.INVALID_NODE || !d.shown {
		if d.minimum_rejected {
			notify(app, .Info, fmt.tprintf("Can't dock: minimum %d × %d content cells. "+
				"Change Minimum Pane Width and Height in Settings.",
				app.settings.pane.minimum_columns, app.settings.pane.minimum_rows))
		}
		pane_drag_restore(app, w, d)
		return true
	}
	changed := false
	if d.destination != d.source {
		if !pane_transfer(app, destination_window, d.source, d.destination, d.node, d.target, d.direction, d.root) {
			pane_drag_restore(app, w, d)
			notify(app, .Error, "Could not move the pane. Both tabs were preserved.")
		}
		return true
	}
	if d.swap {
		changed = layout.swap(w.tree, d.node, d.target)
	} else if d.root {
		_, changed = layout.dock_pane(w.tree, d.node, d.direction)
	} else {
		_, changed = layout.move_pane(w.tree, d.node, d.target, d.direction)
	}
	if changed {
		window_relayout(app, w)
		window_update_title(app, w)
		reset_blink(w)
	}
	return true
}

pane_drag_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	d := &w.pane_drag
	if d.active && d.hover_until != {} && time.tick_diff(now, d.hover_until) <= 0 {
		pane_drag_move(app, w, d.pointer.x, d.pointer.y, d.swap)
	}
}

pane_drag_animating :: proc(w: ^Window) -> bool {
	if !w.pane_drag.active { return false }
	if ui.motion_active(w.pane_drag.reveal) { return true }
	for m in w.pane_drag.ghost { if ui.motion_active(m) { return true } }
	return false
}

pane_drag_animate :: proc(app: ^App, w: ^Window, enabled: bool, now: time.Tick) {
	if !w.pane_drag.active { return }
	if !enabled && pane_drag_animating(w) {
		for &m in w.pane_drag.ghost { m.value = m.target }
		w.pane_drag.reveal.value = w.pane_drag.reveal.target
		w.dirty = true
		return
	}
	if ui.motion_update(&w.pane_drag.reveal, now) { w.dirty = true }
	for &m in w.pane_drag.ghost { if ui.motion_update(&m, now) { w.dirty = true } }
	if w.dirty {
		if target := window_find(app, w.pane_drag.destination_window); target != nil { target.dirty = true }
	}
}

pane_drag_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	d := &w.pane_drag
	for source in app.windows {
		if source.pane_drag.active && source.pane_drag.destination_window == w.id {
			d = &source.pane_drag
			break
		}
	}
	if !d.active || !d.shown { return .Ok }
	if d.destination_window != w.id && !d.new_window { return .Ok }
	r := render.Rect{d.ghost[0].value, d.ghost[1].value, d.ghost[2].value, d.ghost[3].value}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	radius := f32(app.settings.pane.corner_radius)*w.scale
	opacity := d.new_tab ? d.reveal.value : 1
	fill := app.theme.accent
	fill.a = 0.16*opacity
	if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None { return .Ok }
	r = {d.ghost[0].target, d.ghost[1].target, d.ghost[2].target, d.ghost[3].target}
	accent := app.theme.accent
	accent.a *= opacity
	if render.push_rect(&w.list, {rect = r, color = accent, radius = radius,
		stroke = 2*w.scale}) != .None { return .Ok }
	label := d.new_window ? "+ New window" :
		d.new_tab ? (d.destination == d.source && d.node == d.source.tree.root ? "Move tab to end" : "+ New tab") :
		d.swap ? "Swap panes" : d.root ? "Dock to workspace edge" : "Move pane here"
	text := ui.text_styled(&w.ui_text, .Strong)
	width := ui.text_width(&text, label)
	label_color := app.theme.text
	label_color.a *= opacity
	return ui.draw_text(&text, &w.list, label, r.x+(r.width-width)/2,
		r.y+(r.height-text.line_height)/2+text.ascent, label_color, max(1, r.width-16*w.scale))
}

// Ends every pointer arrangement gesture, restoring a dragged tab to its starting position.
arrange_cancel :: proc(app: ^App, w: ^Window) {
	id := w.id
	// Cancellation may destroy a preview and remove it from the registry.
	for i := len(app.windows)-1; i >= 0; i -= 1 {
		if i >= len(app.windows) { continue }
		other := app.windows[i]
		if other != w && (other.pane_drag.destination_window == w.id || other.pane_drag.preview_window == w.id) {
			pane_drag_cancel(app, other)
		}
	}
	if window_find(app, id) == nil { return }
	w.dragging = {}
	tab_drag_cancel(app, w)
	pane_drag_cancel(app, w)
}
