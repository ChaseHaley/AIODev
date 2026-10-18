package main

import "core:math"
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
	node, target: layout.Node_Id,
	direction: layout.Direction,
	start: [2]f32,
	pressed, active, swap, shown: bool,
	ghost: [4]ui.Motion,
}

// A tab press that reorders the strip once it passes the threshold.
Tab_Drag :: struct {
	index, origin: int,
	start: f32,
	pressed, active: bool,
}

@(private)
divider_hits :: proc(w: ^Window, x, y: f32, out: []layout.Divider) -> int {
	return layout.divider_hit_all(w.dividers[:], x, y, 3*w.scale, out)
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

tab_press :: proc(w: ^Window, index: int, x: f32) {
	w.tab_drag = {index = index, origin = index, start = x, pressed = true}
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
	d.active = true
	bar := window_tab_bar(app, w)
	if bar.tab_width <= 0 { return true }
	target := clamp(int(x/bar.tab_width), 0, len(w.workspace.tabs)-1)
	if target != d.index {
		tab_move(app, w, d.index, target)
		d.index = target
	}
	return true
}

tab_drag_cancel :: proc(app: ^App, w: ^Window) {
	if w.tab_drag.active { tab_move(app, w, w.tab_drag.index, w.tab_drag.origin) }
	w.tab_drag = {}
}

pane_drag_press :: proc(w: ^Window, node: layout.Node_Id, x, y: f32) {
	if len(w.panes) < 2 { return }
	w.pane_drag = {node = node, target = layout.INVALID_NODE, start = {x, y}, pressed = true}
}

pane_drag_cancel :: proc(w: ^Window) {
	if w.pane_drag.active { w.dirty = true }
	w.pane_drag = {}
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
pane_drag_preview :: proc(app: ^App, w: ^Window) -> (layout.Rect, bool) {
	d := &w.pane_drag
	if d.target == layout.INVALID_NODE { return {}, false }
	if d.swap {
		for pane in w.panes { if pane.node == d.target { return pane.rect, true } }
		return {}, false
	}
	trial := w.tree^
	trial.nodes = make([dynamic]layout.Node, len(w.tree.nodes), len(w.tree.nodes)+2, context.temp_allocator)
	copy(trial.nodes[:], w.tree.nodes[:])
	content := w.tree.nodes[d.node].(layout.Pane).content
	if _, moved := layout.move_pane(&trial, d.node, d.target, d.direction); !moved { return {}, false }
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(&trial, window_content_area(app, w), window_gap(app, w), &rects)
	for r in rects { if r.content == content { return r.rect, true } }
	return {}, false
}

// Tracks a header drag; returns whether the drag owns the pointer.
pane_drag_move :: proc(app: ^App, w: ^Window, x, y: f32, swap: bool) -> bool {
	d := &w.pane_drag
	if !d.pressed { return false }
	if !d.active && math.hypot(x-d.start.x, y-d.start.y) < DRAG_THRESHOLD*w.scale { return false }
	d.active = true
	target, direction := layout.INVALID_NODE, layout.Direction.Left
	if pane, found := layout.hit_test(w.panes[:], x, y); found && pane.node != d.node {
		target, direction = pane.node, nearest_side(pane.rect, x, y)
	}
	if target == d.target && direction == d.direction && swap == d.swap { return true }
	d.target, d.direction, d.swap = target, direction, swap
	w.dirty = true
	rect, shown := pane_drag_preview(app, w)
	values := [4]f32{rect.x, rect.y, rect.width, rect.height}
	now := time.tick_now()
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
	if d.target == layout.INVALID_NODE { return true }
	changed := false
	if d.swap {
		changed = layout.swap(w.tree, d.node, d.target)
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

pane_drag_animating :: proc(w: ^Window) -> bool {
	if !w.pane_drag.active { return false }
	for m in w.pane_drag.ghost { if ui.motion_active(m) { return true } }
	return false
}

pane_drag_animate :: proc(w: ^Window, now: time.Tick) {
	if !w.pane_drag.active { return }
	for &m in w.pane_drag.ghost { if ui.motion_update(&m, now) { w.dirty = true } }
}

pane_drag_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	d := &w.pane_drag
	if !d.active || !d.shown { return .Ok }
	r := render.Rect{d.ghost[0].value, d.ghost[1].value, d.ghost[2].value, d.ghost[3].value}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None { return .Ok }
	radius := f32(app.settings.pane.corner_radius)*w.scale
	fill := app.theme.accent
	fill.a = 0.16
	if render.push_rect(&w.list, {rect = r, color = fill, radius = radius}) != .None { return .Ok }
	if render.push_rect(&w.list, {rect = r, color = app.theme.accent, radius = radius,
		stroke = 2*w.scale}) != .None { return .Ok }
	label := d.swap ? "Swap panes" : "Move pane here"
	text := ui.text_styled(&app.ui_text, .Strong)
	width := ui.text_width(&text, label)
	return ui.draw_text(&text, &w.list, label, r.x+(r.width-width)/2,
		r.y+(r.height-text.line_height)/2+text.ascent, app.theme.text, max(1, r.width-16*w.scale))
}

// Ends every pointer arrangement gesture, restoring a dragged tab to its starting position.
arrange_cancel :: proc(app: ^App, w: ^Window) {
	w.dragging = {}
	tab_drag_cancel(app, w)
	pane_drag_cancel(w)
}
