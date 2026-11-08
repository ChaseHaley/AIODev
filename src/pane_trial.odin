package main

import "aio:layout"

Pane_Trial_Error :: enum {
	None,
	Allocation,
	Invalid,
	Minimum,
}

// The content geometry trials measure in place of a pane that does not exist yet. It is used only for
// measurement and names no session: session ids are allocated upward from 1 and never reach it, so
// it never matches a real pane's content or looks up a session's header.
PANE_MEASUREMENT_CONTENT :: layout.Content{.Terminal, max(u32)}

// Geometry is copied out; all detached storage belongs to the evaluation's scratch allocator.
Pane_Trial_Result :: struct {
	rect:  layout.Rect,
	error: Pane_Trial_Error,
}

@(private, require_results)
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
	// Judged by the split view panes return to once the change has ended any fill.
	g := window_geometry(app, w, .None)
	layout.place_shown(trial, g, false, &rects)
	layout.place_shown(original, g, false, &before)
	if !pane_minimum_allows(app, w, rects[:], before[:], notify_failure) {return {error = .Minimum}}
	for pane in rects {if pane.node == added {return {rect = pane.rect}}}
	return {error = .Invalid}
}

// Splits a copy of `tree` at `node` in w's content area. A nil tree means w's own tree at its focus;
// any other tree belongs to a tab of w's workspace.
@(require_results)
pane_trial_split :: proc(
	app: ^App,
	w: ^Window,
	direction: layout.Direction,
	ratio: f32,
	allocator := context.temp_allocator,
	tree: ^layout.Layout = nil,
	node := layout.INVALID_NODE,
	notify_failure := true,
) -> Pane_Trial_Result {
	original, target := tree, node
	if original == nil {
		original = window_tree(w)
		target = original.focus
	}
	if _, ok := layout.pane_content(original, target); !ok {return {error = .Invalid}}
	trial, copy_error := layout.clone(original, allocator)
	if copy_error != nil {return {error = .Allocation}}
	defer layout.destroy(&trial)
	added, err := layout.split_direction(&trial, target, direction, ratio, PANE_MEASUREMENT_CONTENT)
	if err != nil {return {error = .Allocation}}
	return pane_trial_evaluate(app, w, original, &trial, added, notify_failure)
}

// Measures `op` on copies of its trees as w would show the result: the destination tab's tree, or for a
// linked window the copy of the slot the pane joins.
@(require_results)
pane_trial_operation :: proc(
	app: ^App,
	w: ^Window,
	op: Pane_Operation,
	allocator := context.temp_allocator,
) -> Pane_Trial_Result {
	content, is_pane := layout.pane_content(&op.source.tree, op.node)
	if !is_pane {return {error = .Invalid}}
	trial, copy_error := layout.clone(&op.destination.tree, allocator)
	if copy_error != nil {return {error = .Allocation}}
	defer layout.destroy(&trial)
	added := layout.INVALID_NODE
	moved := false
	if op.source != op.destination {
		detached, source_error := layout.clone(&op.source.tree, allocator)
		if source_error != nil {return {error = .Allocation}}
		defer layout.destroy(&detached)
		added, moved = pane_operation_apply(op, &detached, &trial)
	} else {
		added, moved = pane_operation_apply(op, &trial, &trial)
	}
	if !moved {return {error = .Invalid}}
	if op.slot == layout.INVALID_NODE {
		return pane_trial_evaluate(app, w, &op.destination.tree, &trial, added, false)
	}
	before := layout.Layout{nodes = make([dynamic]layout.Node, allocator)}
	defer layout.destroy(&before)
	after := layout.Layout{nodes = make([dynamic]layout.Node, allocator)}
	defer layout.destroy(&after)
	if layout.link_view_load(&before, &op.destination.tree, op.slot) != nil {return {error = .Allocation}}
	if layout.link_view_load(&after, &trial, layout.link_root(&trial, added)) != nil {
		return {error = .Allocation}
	}
	return pane_trial_evaluate(app, w, &before, &after, layout.find_content(&after, content), false)
}
