package main

import "aio:layout"
import "aio:platform"


// How the pointer grabs dividers and dock edges, in DIPs: the band either side of a bar, the reach of a
// junction where bars meet, and how far apart meeting bars may lie.
@(private)
DIVIDER_GRAB :: 3
@(private = "file")
DIVIDER_JUNCTION_REACH :: 10
@(private = "file")
DIVIDER_JUNCTION_ALIGNMENT :: 2

// The most bars one press drags: a junction where splits and dock edges meet. Hit gathering keeps twice
// as many before filtering out those of other floating groups.
DIVIDER_HITS_MAX :: 4
@(private = "file")
DIVIDER_HITS_GATHERED :: 2 * DIVIDER_HITS_MAX

// What a divider press acts on: a split of the window's tree, or a dock edge.
Divider_Target :: union {
	layout.Node_Id,
	Dock_Edge,
}

Divider_Hit :: struct {
	target: Divider_Target,
	axis:   layout.Axis,
}

// A Left press on a divider, dock edge or rail edge; nil is Idle. First_Click remembers the last press,
// so a second press on the same divider within DOUBLE_CLICK_NS balances what it divides. Dragging moves
// the splits whose dividers meet under the pointer, outermost first, and keeps its press as the first
// click for the release. The procs below are the only writers.
Divider_Gesture :: union {
	Divider_First_Click,
	Divider_Drag,
}

Divider_First_Click :: struct {
	target:  Divider_Target,
	time_ns: i64,
}

Divider_Drag :: struct {
	targets: [DIVIDER_HITS_MAX]Divider_Target,
	offsets: [DIVIDER_HITS_MAX]f32,
	count:   int,
	click:   Divider_First_Click,
}

divider_dragging :: proc(w: ^Window) -> ^Divider_Drag {
	drag, ok := &w.divider.(Divider_Drag)
	return ok ? drag : nil
}

when AIO_CONTROL {
	// How many dividers the window's drag holds; zero while none is dragged.
	divider_state_report :: proc(r: ^State_Report, w: ^Window) {
		drag := divider_dragging(w)
		state_value(r, "dividers.dragging", drag == nil ? 0 : drag.count)
	}
}

// The rail edge is among the dragged dividers.
rail_resizing :: proc(w: ^Window) -> bool {
	drag := divider_dragging(w)
	if drag == nil {return false}
	rail: Divider_Target = Dock_Edge.Rail_Width
	for target in drag.targets[:drag.count] {if target == rail {return true}}
	return false
}

// The drag ends at the release point; its press stays the first click of a double-click.
divider_drag_release :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if divider_dragging(w) == nil {return false}
	divider_drag(app, w, x, y)
	if drag := divider_dragging(w); drag != nil {
		click := drag.click
		w.divider = click
	}
	return true
}

// A drag or first click that was interrupted: a later press starts over.
divider_cancel :: proc(w: ^Window) {
	w.divider = nil
}

// The dividers and dock edges under the pointer, outermost first. Over a floating group only its own
// dividers; over an overlay rail only the dock edges; elsewhere the dock edges and the tiled dividers.
@(private)
divider_hits :: proc(w: ^Window, x, y: f32, out: []Divider_Hit) -> int {
	tree := window_tree(w)
	docks := &w.dock_edges
	tolerance := DIVIDER_GRAB * w.scale
	root, _, covered := floating_frame_at(w, x, y)
	if !covered && rail_overlay(w) {
		area := rail_area(w)
		for edge, i in docks.edges[:docks.count] {
			if edge != .Rail_Width {continue}
			rail := docks.bars[i].rect
			beside := x >= area.x && x < rail.x + rail.width + tolerance
			if !beside || y < area.y || y >= area.y + area.height {break}
			indices: [len(Dock_Edge)]int
			n := layout.divider_hit_all(docks.bars[:docks.count], nil, x, y, tolerance, indices[:])
			count := min(n, len(out))
			for index, k in indices[:count] {out[k] = {docks.edges[index], docks.bars[index].axis}}
			return count
		}
	}
	indices: [DIVIDER_HITS_GATHERED]int
	n := layout.divider_hit_all(
		docks.bars[:docks.count],
		w.dividers[:],
		x,
		y,
		tolerance,
		indices[:],
		DIVIDER_JUNCTION_REACH * w.scale,
		DIVIDER_JUNCTION_ALIGNMENT * w.scale,
	)
	group := covered ? root : layout.INVALID_NODE
	count := 0
	for index in indices[:n] {
		hit: Divider_Hit
		if index < docks.count {
			if covered {continue}
			hit = {docks.edges[index], docks.bars[index].axis}
		} else {
			d := w.dividers[index - docks.count]
			if layout.float_root(tree, d.node) != group {continue}
			hit = {d.node, d.axis}
		}
		if count >= len(out) {break}
		out[count] = hit
		count += 1
	}
	return count
}

// Starts a divider drag, or on a second click of the same divider balances the splits it belongs to.
divider_press :: proc(app: ^App, w: ^Window, x, y: f32, time_ns: i64) -> bool {
	hits: [DIVIDER_HITS_MAX]Divider_Hit
	n := divider_hits(w, x, y, hits[:])
	if n == 0 {return false}
	selection_cancel(w)
	if click, ok := w.divider.(Divider_First_Click);
	   ok && hits[0].target == click.target && time_ns > click.time_ns &&
	   time_ns - click.time_ns <= DOUBLE_CLICK_NS {
		w.divider = nil
		balanced := false
		tree := window_tree(w)
		for hit in hits[:n] {
			switch target in hit.target {
			case Dock_Edge:
				dock_edge_reset(w, target)
				balanced = true
			case layout.Node_Id:
				balanced = layout.balance_related(tree, target) || balanced
			}
		}
		if balanced {window_relayout(app, w)}
		return true
	}
	drag := Divider_Drag {
		count = n,
		click = {hits[0].target, time_ns},
	}
	for hit, i in hits[:n] {
		drag.targets[i] = hit.target
		if edge, is_edge := hit.target.(Dock_Edge); is_edge {
			drag.offsets[i] = dock_edge_along(edge, x, y) - dock_edge_position(app, w, edge)
		}
	}
	w.divider = drag
	return true
}

// Each split takes the pointer position on its own axis. Divider areas are refreshed after every move,
// because an outer split resizes the region of the splits nested inside it.
divider_drag :: proc(app: ^App, w: ^Window, x, y: f32) {
	drag := divider_dragging(w)
	if drag == nil {return}
	gap := window_gap(app, w)
	tree := window_tree(w)
	moved := false
	for target, i in drag.targets[:drag.count] {
		switch t in target {
		case Dock_Edge:
			dock_edge_drag(app, w, t, dock_edge_along(t, x, y) - drag.offsets[i])
			window_dock_reserve(app, w)
			window_dividers(app, w)
			moved = true
		case layout.Node_Id:
			for d in w.dividers {
				if d.node != t {continue}
				if layout.drag_divider(tree, d, x, y, gap) {
					moved = true
					window_dividers(app, w)
				}
				break
			}
		}
	}
	if moved {window_relayout(app, w)}
}

divider_cursor :: proc(w: ^Window, x, y: f32) -> (platform.Cursor_Shape, bool) {
	hits: [DIVIDER_HITS_MAX]Divider_Hit
	n := divider_hits(w, x, y, hits[:])
	if n == 0 {return .Arrow, false}
	axes: bit_set[layout.Axis]
	for hit in hits[:n] {axes += {hit.axis}}
	if axes == {.Horizontal, .Vertical} {return .Resize_All, true}
	return .Horizontal in axes ? .Resize_Horizontal : .Resize_Vertical, true
}
