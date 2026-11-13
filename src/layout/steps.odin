package layout

// What the keyboard's pane moves read from a tree (WORK-477): whether a step passes a neighbour or joins
// it, whether a pane already runs along an edge, and the split a rotation turns. A split whose other side
// takes no space here, such as a slot shown in its own window, is invisible to all three, so none of them
// plans a change that shows nothing.

// The direction pointing back the way `direction` points.
@(require_results)
opposite :: proc(direction: Direction) -> Direction {
	axis, before := direction_parts(direction)
	return direction_of(axis, !before)
}

// Whether a pane stepping from `node` toward `direction` passes `target`, its neighbour that way, rather
// than joining it: the two sit in one row along the direction's axis, so every split between them that
// divides runs along that axis, and neither is in a floating group or slot the other is outside.
@(require_results)
step_passes :: proc(l: ^Layout, node, target: Node_Id, direction: Direction) -> bool {
	if node == target || int(node) >= len(l.nodes) || int(target) >= len(l.nodes) {return false}
	axis, _ := direction_parts(direction)
	common := common_ancestor(l, node, target)
	if common == INVALID_NODE {return false}
	s, is_split := l.nodes[common].(Split)
	return is_split && s.axis == axis && in_row(l, node, common, axis) && in_row(l, target, common, axis)
}

// Whether the pane at `node` already runs along the whole `direction` edge of the panes it shares its
// tiling or floating group with, so docking it to that edge would change nothing on screen.
@(require_results)
spans_edge :: proc(l: ^Layout, node: Node_Id, direction: Direction) -> bool {
	if int(node) >= len(l.nodes) {return false}
	axis, before := direction_parts(direction)
	for x := node; !float_is_root(l, x) && !node_linked(l, x); {
		parent := parent_of(l, x)
		if parent == INVALID_NODE {break}
		s := l.nodes[parent].(Split)
		if split_divides(l, s) && (s.axis != axis || (s.first == x) != before) {return false}
		x = parent
	}
	return true
}

// Turns the nearest split that divides the pane at `node` from a neighbour a quarter turn, side by side to
// one above the other and back, each side keeping its share, as Hyprland's togglesplit does. False when
// the pane has no neighbour in its tiling or floating group.
@(require_results)
rotate_split :: proc(l: ^Layout, node: Node_Id) -> bool {
	if int(node) >= len(l.nodes) {return false}
	for x := node; !float_is_root(l, x) && !node_linked(l, x); {
		parent := parent_of(l, x)
		if parent == INVALID_NODE {return false}
		s := &l.nodes[parent].(Split)
		if split_divides(l, s^) {
			s.axis = s.axis == .Horizontal ? .Vertical : .Horizontal
			return true
		}
		x = parent
	}
	return false
}

@(private, require_results)
common_ancestor :: proc(l: ^Layout, a, b: Node_Id) -> Node_Id {
	for x := a; x != INVALID_NODE; x = parent_of(l, x) {
		for y := b; y != INVALID_NODE; y = parent_of(l, y) {
			if x == y {return x}
		}
	}
	return INVALID_NODE
}

// Whether every dividing split from `node` up to `top`, which holds it, runs along `axis`, with no
// floating group or slot boundary on the way.
@(private, require_results)
in_row :: proc(l: ^Layout, node, top: Node_Id, axis: Axis) -> bool {
	for x := node; x != top; {
		if float_is_root(l, x) || node_linked(l, x) {return false}
		parent := parent_of(l, x)
		if parent == INVALID_NODE {return false}
		if s := l.nodes[parent].(Split); parent != top && split_divides(l, s) && s.axis != axis {return false}
		x = parent
	}
	return true
}
