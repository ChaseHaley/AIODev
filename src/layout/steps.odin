package layout

// What the keyboard's pane moves read from a tree (WORK-477): the step a move takes, whether it passes a
// neighbour or joins it, whether a pane already runs along an edge, and the split a rotation turns. A
// split whose other side takes no space here, such as a slot shown in its own window, is invisible to them
// all, so none of them plans a change that shows nothing.

// The step a keyboard move takes, smallest change first. Nil: the pane already runs along that edge of its
// tiling or float, so only another window can take it further.
Step :: union {
	Step_Neighbour,
	Step_Beside,
	Step_Region,
}

// A pane lies that way inside the split the move leaves by: the neighbour focus finds there takes it, as
// step_passes says.
Step_Neighbour :: struct {}

// The pane's own split runs across the move, so the pane turns to sit beside `target`, its neighbour across
// that split, on the move's side, sharing the place that neighbour held.
Step_Beside :: struct {
	target: Node_Id,
}

// The pane already sits at that end of the row it is in, so it docks along that edge of `region`, the next
// split around the row, which runs across the move.
Step_Region :: struct {
	region: Node_Id,
}

// The step the pane at `node` takes toward `direction`. Walking out from the pane: a split along the move
// with room past the pane is a Step_Neighbour; a split across the move holding the pane itself is a
// Step_Beside; one holding a row the pane ends is a Step_Region. So a pane in a column of three first joins
// its neighbour above, a press later passes it, and only then docks along the tab's whole edge.
@(require_results)
step_plan :: proc(l: ^Layout, node: Node_Id, direction: Direction) -> Step {
	if int(node) >= len(l.nodes) {return nil}
	axis, before := direction_parts(direction)
	for x := node; !float_is_root(l, x) && !node_linked(l, x); {
		parent := parent_of(l, x)
		if parent == INVALID_NODE {return nil}
		s := l.nodes[parent].(Split)
		switch {
		case !split_divides(l, s):
		case s.axis == axis:
			if (s.first == x) != before {return Step_Neighbour{}}
		case x == node:
			sibling := s.first == x ? s.second : s.first
			// The sibling's side facing the pane: its first side when the pane comes first.
			return Step_Beside{edge_pane(l, sibling, direction_of(s.axis, s.first == x), direction)}
		case:
			return Step_Region{parent}
		}
		x = parent
	}
	return nil
}

// The shown pane of `region` along its `facing` side, furthest toward `along`.
@(private, require_results)
edge_pane :: proc(l: ^Layout, region: Node_Id, facing, along: Direction) -> Node_Id {
	x := region
	for {
		s, is_split := l.nodes[x].(Split)
		if !is_split {return x}
		if !split_divides(l, s) {
			x = first_shown(l, s.first) != INVALID_NODE ? s.first : s.second
			continue
		}
		toward := along
		if axis, _ := direction_parts(facing); s.axis == axis {toward = facing}
		_, before := direction_parts(toward)
		x = before ? s.first : s.second
	}
}

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
