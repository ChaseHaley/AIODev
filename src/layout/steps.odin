package layout

// What the keyboard's pane moves read from a tree (WORK-477): the step a move takes, whether a pane already
// runs along an edge, and the split a rotation turns. A split whose other side takes no space here, such as
// a slot shown in its own window, is invisible to them all, so none of them plans a change that shows
// nothing.

// The step a keyboard move takes: one place along the move, smallest change first. Nil: the pane is already
// that half of its tiling or float, so only another window can take it further.
Step :: union {
	Step_Neighbour,
	Step_Beside,
	Step_Region,
}

// Another pane lies that way, past the split the pane's row ends at: the neighbour focus finds there takes
// it. When that neighbour is the pane's own sibling the pane `passes` it, trading places; otherwise the
// pane enters the neighbour's region at the side it comes from, joining that neighbour on its facing side.
Step_Neighbour :: struct {
	passes: bool,
}

// The pane's own split runs across the move, so the pane turns to sit beside `target`, its neighbour across
// that split, on the move's side, sharing the place that neighbour held.
Step_Beside :: struct {
	target: Node_Id,
}

// The pane docks along the move's edge of `region`, a split holding it: one running across the move around a
// row the pane already ends, or at the edge of the whole tiling or float, its top split, so the pane takes
// that half.
Step_Region :: struct {
	region: Node_Id,
}

// The step the pane at `node` takes toward `direction`, walking out from the pane through the splits that
// divide. A split along the move with room past the pane gives a Step_Neighbour; one across the move
// holding the pane itself, a Step_Beside; one across the move holding a row the pane ends, a Step_Region.
// Past every split the pane is at the edge, and docks as that half unless it already is it. So in a row of
// A and B a quarter each and C a half, A moving right passes B, enters C's half beside C, passes C, and
// then becomes the right half; and in a column of three the bottom pane moving right first turns beside
// its neighbour above.
@(require_results)
step_plan :: proc(l: ^Layout, node: Node_Id, direction: Direction) -> Step {
	if int(node) >= len(l.nodes) {return nil}
	axis, before := direction_parts(direction)
	top := INVALID_NODE
	// No split that divides lies between the pane and x yet, so x stands for the pane alone.
	alone := true
	for x := node; !float_is_root(l, x) && !node_linked(l, x); {
		parent := parent_of(l, x)
		if parent == INVALID_NODE {break}
		s := l.nodes[parent].(Split)
		switch {
		case !split_divides(l, s):
		case s.axis == axis:
			if (s.first == x) != before {
				ahead := before ? s.first : s.second
				return Step_Neighbour{passes = alone && shown_count(l, ahead) == 1}
			}
			top, alone = parent, false
		case alone:
			sibling := s.first == x ? s.second : s.first
			// The sibling's side facing the pane: its first side when the pane comes first.
			return Step_Beside{edge_pane(l, sibling, direction_of(s.axis, s.first == x), direction)}
		case:
			return Step_Region{parent}
		}
		x = parent
	}
	if top == INVALID_NODE {return nil}
	s := l.nodes[top].(Split)
	if shown_count(l, before ? s.first : s.second) == 1 {return nil}
	return Step_Region{top}
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

