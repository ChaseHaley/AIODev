package main

import "aio:layout"
import "base:runtime"

Pane_Trial_Error :: enum {
	None,
	Allocation,
	Invalid,
	Minimum,
}

// Geometry is copied out; all detached storage belongs to the evaluation's scratch allocator.
Pane_Trial_Result :: struct {
	rect:  layout.Rect,
	error: Pane_Trial_Error,
}

@(private)
pane_trial_copy :: proc(original: ^layout.Layout, allocator: runtime.Allocator) -> (layout.Layout, bool) {
	trial := original^
	nodes, err := make([dynamic]layout.Node, len(original.nodes), len(original.nodes) + 2, allocator)
	if err != nil {return {}, false}
	copy(nodes[:], original.nodes[:])
	trial.nodes, trial.zoomed = nodes, false
	return trial, true
}

@(private)
pane_trial_evaluate :: proc(
	app: ^App,
	w: ^Window,
	original, trial: ^layout.Layout,
	added: layout.Node_Id,
	notify_failure: bool,
) -> Pane_Trial_Result {
	allocator := trial.nodes.allocator
	rects, rect_error := make([dynamic]layout.Pane_Rect, 0, len(trial.nodes), allocator)
	if rect_error != nil {return {error = .Allocation}}
	defer delete(rects)
	before, before_error := make([dynamic]layout.Pane_Rect, 0, len(original.nodes), allocator)
	if before_error != nil {return {error = .Allocation}}
	defer delete(before)
	area, gap := window_content_area(app, w), window_gap(app, w)
	layout.compute(trial, area, gap, &rects, false)
	layout.compute(original, area, gap, &before, false)
	if !pane_minimum_allows(app, w, rects[:], before[:], notify_failure) {return {error = .Minimum}}
	for pane in rects {if pane.node == added {return {rect = pane.rect}}}
	return {error = .Invalid}
}

@(require_results)
pane_trial_split :: proc(
	app: ^App,
	w: ^Window,
	direction: layout.Direction,
	ratio: f32,
	allocator := context.temp_allocator,
) -> Pane_Trial_Result {
	if int(w.tree.focus) >= len(w.tree.nodes) {return {error = .Invalid}}
	if _, ok := w.tree.nodes[w.tree.focus].(layout.Pane); !ok {return {error = .Invalid}}
	trial, copied := pane_trial_copy(w.tree, allocator)
	if !copied {return {error = .Allocation}}
	defer layout.destroy(&trial)
	added, err := layout.split_direction(
		&trial,
		trial.focus,
		direction,
		ratio,
		{.Terminal, app.next_session_id + 1},
	)
	if err != nil {return {error = .Allocation}}
	return pane_trial_evaluate(app, w, w.tree, &trial, added, true)
}

@(require_results)
pane_trial_move :: proc(
	app: ^App,
	w: ^Window,
	source, destination: ^layout.Layout,
	node, target: layout.Node_Id,
	direction: layout.Direction,
	root: bool,
	allocator := context.temp_allocator,
) -> Pane_Trial_Result {
	trial, copied := pane_trial_copy(destination, allocator)
	if !copied {return {error = .Allocation}}
	defer layout.destroy(&trial)
	added := layout.INVALID_NODE
	moved := false
	if source != destination {
		detached, source_copied := pane_trial_copy(source, allocator)
		if !source_copied {return {error = .Allocation}}
		defer layout.destroy(&detached)
		added, moved = layout.transfer_pane(&detached, &trial, node, target, direction, root)
	} else if root {
		added, moved = layout.dock_pane(&trial, node, direction)
	} else {
		added, moved = layout.move_pane(&trial, node, target, direction)
	}
	if !moved {return {error = .Invalid}}
	return pane_trial_evaluate(app, w, destination, &trial, added, false)
}
