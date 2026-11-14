package layout_test

import "aio:layout"
import "core:testing"

@(private = "file")
AREA :: layout.Rect{0, 0, 400, 400}

@(private = "file")
placed :: proc(l: ^layout.Layout, id: u32) -> layout.Rect {
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(l, AREA, 0, &rects)
	return rect_of(rects[:], id)
}

// A beside B: B moving left passes A, its sibling, and is then the left half, which a further press leaves.
@(test)
a_move_passes_its_sibling :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	b, _ := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	plan, neighbour := layout.step_plan(&l, b, .Left).(layout.Step_Neighbour)
	testing.expect(t, neighbour && plan.passes)
	testing.expect(t, step(&l, 2, .Left))
	testing.expect_value(t, placed(&l, 2), layout.Rect{0, 0, 200, 400})
	testing.expect_value(t, placed(&l, 1), layout.Rect{200, 0, 200, 400})
	testing.expect(t, !step(&l, 2, .Left))
	testing.expect(t, layout.step_plan(&l, layout.Node_Id(99), .Left) == nil)
}

// P beside a row of N and M nested along the same axis: P moving right enters that row at its near end,
// beside N, keeping its place in the order while the row's room shifts.
@(test)
a_move_enters_a_nested_row_at_its_near_end :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	n, _ := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	_, _ = layout.split(&l, n, .Horizontal, 0.5, terminal(3))
	plan, neighbour := layout.step_plan(&l, layout.find_content(&l, terminal(1)), .Right).(layout.Step_Neighbour)
	testing.expect(t, neighbour && !plan.passes)
	testing.expect(t, step(&l, 1, .Right))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 100, 400})
	testing.expect_value(t, placed(&l, 2), layout.Rect{100, 0, 100, 400})
	testing.expect_value(t, placed(&l, 3), layout.Rect{200, 0, 200, 400})
}

// A over C beside B: B moving left joins A's column beside its neighbour there, then passes it.
@(test)
a_move_joins_a_neighbour_in_another_branch :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	b, _ := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	_, _ = layout.split(&l, layout.find_content(&l, terminal(1)), .Vertical, 0.5, terminal(3))
	plan, neighbour := layout.step_plan(&l, b, .Left).(layout.Step_Neighbour)
	testing.expect(t, neighbour && !plan.passes)
	testing.expect(t, step(&l, 2, .Left))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 200, 200})
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 0, 200, 200})
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 200, 400, 200})
	testing.expect(t, step(&l, 2, .Left))
	testing.expect_value(t, placed(&l, 2), layout.Rect{0, 0, 200, 200})
}

// Which edges a pane already runs along, so docking it there changes nothing.
@(test)
spans_edge_reads_the_edges_a_pane_runs_along :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	a := l.root
	testing.expect(t, layout.spans_edge(&l, a, .Left))
	b, _ := layout.split(&l, a, .Horizontal, 0.5, terminal(2))
	c, _ := layout.split(&l, a, .Vertical, 0.5, terminal(3))
	a = layout.find_content(&l, terminal(1))
	testing.expect(t, layout.spans_edge(&l, b, .Right))
	testing.expect(t, !layout.spans_edge(&l, b, .Left))
	testing.expect(t, !layout.spans_edge(&l, b, .Up))
	testing.expect(t, !layout.spans_edge(&l, a, .Left))
	testing.expect(t, !layout.spans_edge(&l, a, .Up))
	testing.expect(t, !layout.spans_edge(&l, c, .Down))
	testing.expect(t, !layout.spans_edge(&l, layout.Node_Id(99), .Down))
}

// A split whose other side is a slot shown in its own window takes no space, so it neither stops a move
// passing nor counts against an edge.
@(test)
a_linked_slot_beside_a_pane_is_invisible_to_steps :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	a := l.root
	b, _ := layout.split(&l, a, .Horizontal, 0.5, terminal(2))
	linked, _ := layout.split(&l, b, .Vertical, 0.5, terminal(3))
	testing.expect(t, layout.set_linked(&l, linked, true))
	a = layout.find_content(&l, terminal(1))
	b = layout.find_content(&l, terminal(2))
	plan, neighbour := layout.step_plan(&l, a, .Right).(layout.Step_Neighbour)
	testing.expect(t, neighbour && plan.passes)
	plan, neighbour = layout.step_plan(&l, b, .Left).(layout.Step_Neighbour)
	testing.expect(t, neighbour && plan.passes)
	testing.expect(t, layout.step_plan(&l, b, .Right) == nil)
	testing.expect(t, layout.spans_edge(&l, b, .Right))
	testing.expect(t, !layout.spans_edge(&l, b, .Down))
	// The rotation skips the split with the slot and turns the one between A and B.
	testing.expect(t, layout.rotate_split(&l, b))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 400, 200})
	testing.expect_value(t, placed(&l, 2), layout.Rect{0, 200, 400, 200})
}

// A floating group is its own tiling: its panes pass each other inside it and never leave it by a move, and
// a tiled pane beside the group's slot still passes its tiled neighbour.
@(test)
a_move_stays_inside_a_floating_group :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	b, _ := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	c, _ := layout.split(&l, b, .Horizontal, 0.5, terminal(3))
	testing.expect(t, layout.set_floating(&l, c, true, {0.1, 0.1, 0.5, 0.5}))
	c = layout.find_content(&l, terminal(3))
	testing.expect(t, layout.step_plan(&l, c, .Left) == nil)
	plan, neighbour := layout.step_plan(&l, layout.find_content(&l, terminal(2)), .Left).(layout.Step_Neighbour)
	testing.expect(t, neighbour && plan.passes)
	d, _ := layout.split(&l, c, .Horizontal, 0.5, terminal(4))
	plan, neighbour = layout.step_plan(&l, d, .Left).(layout.Step_Neighbour)
	testing.expect(t, neighbour && plan.passes)
	testing.expect(t, layout.step_plan(&l, d, .Right) == nil)
	testing.expect(t, layout.step_plan(&l, layout.find_content(&l, terminal(3)), .Left) == nil)
	testing.expect(t, layout.spans_edge(&l, d, .Right))
	testing.expect(t, !layout.spans_edge(&l, d, .Left))
}

// Rotation turns the pane's nearest dividing split, keeping its share, and turns it back; a lone pane or
// a lone floating pane has nothing to turn.
@(test)
rotate_split_turns_the_nearest_split_a_quarter :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	testing.expect(t, !layout.rotate_split(&l, l.root))
	a := l.root
	b, _ := layout.split(&l, a, .Horizontal, 0.25, terminal(2))
	c, _ := layout.split(&l, b, .Vertical, 0.5, terminal(3))
	testing.expect(t, layout.rotate_split(&l, c))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 100, 400})
	testing.expect_value(t, placed(&l, 2), layout.Rect{100, 0, 150, 400})
	testing.expect_value(t, placed(&l, 3), layout.Rect{250, 0, 150, 400})
	a = layout.find_content(&l, terminal(1))
	testing.expect(t, layout.rotate_split(&l, a))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 400, 100})
	testing.expect(t, layout.rotate_split(&l, a))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 100, 400})
	f, _ := layout.float_new(&l, terminal(5), {0.1, 0.1, 0.5, 0.5})
	testing.expect(t, !layout.rotate_split(&l, f))
	testing.expect(t, !layout.rotate_split(&l, layout.Node_Id(99)))
}

// One keyboard move of the pane showing `id` toward `direction`, as pane_move_toward makes it within one
// window: the plan's step, or for a neighbour, passing it or joining it on its facing side. Returns whether
// anything moved.
@(private = "file")
step :: proc(l: ^layout.Layout, id: u32, direction: layout.Direction) -> bool {
	node := layout.find_content(l, terminal(id))
	switch plan in layout.step_plan(l, node, direction) {
	case layout.Step_Beside:
		_, moved := layout.move_pane(l, node, plan.target, direction)
		return moved
	case layout.Step_Region:
		_, moved := layout.dock_pane(l, node, direction, plan.region)
		return moved
	case layout.Step_Neighbour:
		rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
		layout.compute(l, AREA, 0, &rects)
		target := layout.focus_direction(rects[:], node, direction)
		if target == node {return false}
		_, moved := layout.move_pane(l, node, target, plan.passes ? direction : layout.opposite(direction))
		return moved
	case nil:
	}
	return false
}

// A column of three: A over the top half, B and C a quarter each below.
@(private = "file")
column_of_three :: proc(t: ^testing.T, l: ^layout.Layout, axis: layout.Axis) {
	testing.expect_value(t, layout.init(l, terminal(1)), nil)
	b, _ := layout.split(l, l.root, axis, 0.5, terminal(2))
	_, _ = layout.split(l, b, axis, 0.5, terminal(3))
}

// The owner's column (WORK-477): C moving right first turns beside B, so A spans the top and B and C share
// the bottom; B moving right then passes C; moving right again, at the end of its row, docks along the
// tab's right edge at full height; and a fourth press has nowhere left to go.
@(test)
a_move_from_a_column_turns_beside_then_passes_then_docks :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	column_of_three(t, &l, .Vertical)
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 300, 400, 100})
	testing.expect(t, step(&l, 3, .Right))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 400, 200})
	testing.expect_value(t, placed(&l, 2), layout.Rect{0, 200, 200, 200})
	testing.expect_value(t, placed(&l, 3), layout.Rect{200, 200, 200, 200})
	testing.expect(t, step(&l, 2, .Right))
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 200, 200, 200})
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 200, 200, 200})
	testing.expect(t, step(&l, 2, .Right))
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 0, 200, 400})
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 200, 200})
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 200, 200, 200})
	testing.expect(t, !step(&l, 2, .Right))
	testing.expect(t, layout.step_plan(&l, layout.find_content(&l, terminal(2)), .Right) == nil)
}

// The mirror: C moving left turns beside B on its left, and from there docks along the left edge.
@(test)
a_move_left_from_a_column_turns_beside_on_the_left :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	column_of_three(t, &l, .Vertical)
	testing.expect(t, step(&l, 3, .Left))
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 200, 200, 200})
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 200, 200, 200})
	testing.expect(t, step(&l, 3, .Left))
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 0, 200, 400})
}

// The same across a row of three, A on the left half and B and C a quarter each to the right: C moving down
// turns beside B below it, B moving down passes C, and moving down again docks along the bottom edge; up
// from the original row puts C above B.
@(test)
a_move_from_a_row_turns_beside_then_passes_then_docks :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	column_of_three(t, &l, .Horizontal)
	testing.expect(t, step(&l, 3, .Down))
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 200, 400})
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 0, 200, 200})
	testing.expect_value(t, placed(&l, 3), layout.Rect{200, 200, 200, 200})
	testing.expect(t, step(&l, 2, .Down))
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 200, 200, 200})
	testing.expect(t, step(&l, 2, .Down))
	testing.expect_value(t, placed(&l, 2), layout.Rect{0, 200, 400, 200})
	testing.expect(t, !step(&l, 2, .Down))

	up: layout.Layout
	defer layout.destroy(&up)
	column_of_three(t, &up, .Horizontal)
	testing.expect(t, step(&up, 3, .Up))
	testing.expect_value(t, placed(&up, 3), layout.Rect{200, 0, 200, 200})
	testing.expect_value(t, placed(&up, 2), layout.Rect{200, 200, 200, 200})
}

// Across a split, the pane turns beside the neighbour that touches it at the far end of the move: under a
// row of two, C moving right joins the right one of the pair, not the left.
@(test)
a_move_turns_beside_the_neighbour_at_the_far_end :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	c, _ := layout.split(&l, l.root, .Vertical, 0.5, terminal(3))
	_, _ = layout.split(&l, layout.find_content(&l, terminal(1)), .Horizontal, 0.5, terminal(2))
	plan, beside := layout.step_plan(&l, c, .Right).(layout.Step_Beside)
	testing.expect(t, beside)
	testing.expect_value(t, plan.target, layout.find_content(&l, terminal(2)))
	plan, beside = layout.step_plan(&l, c, .Left).(layout.Step_Beside)
	testing.expect(t, beside)
	testing.expect_value(t, plan.target, layout.find_content(&l, terminal(1)))
}

// Docking into a region keeps the rest of the tree, and refuses a region that does not hold the pane.
@(test)
dock_pane_docks_along_a_region :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	column_of_three(t, &l, .Vertical)
	b := layout.find_content(&l, terminal(2))
	c := layout.find_content(&l, terminal(3))
	_, refused := layout.dock_pane(&l, b, .Right, c)
	testing.expect(t, !refused)
	_, outside := layout.dock_pane(&l, b, .Right, layout.Node_Id(99))
	testing.expect(t, !outside)
	region := layout.find_content(&l, terminal(1))
	_, pane := layout.dock_pane(&l, b, .Right, region)
	testing.expect(t, !pane)
	_, docked := layout.dock_pane(&l, b, .Right, l.root)
	testing.expect(t, docked)
	testing.expect_value(t, placed(&l, 2), layout.Rect{200, 0, 200, 400})
}

// Builds the owner's row of three along `axis`: two quarters and a half. With `half_first`, the half comes
// first and the quarters after it, the moving pane last.
@(private = "file")
quarters_and_half :: proc(t: ^testing.T, l: ^layout.Layout, axis: layout.Axis, half_first: bool) {
	if half_first {
		testing.expect_value(t, layout.init(l, terminal(3)), nil)
		b, _ := layout.split(l, l.root, axis, 0.5, terminal(2))
		_, _ = layout.split(l, b, axis, 0.5, terminal(1))
		return
	}
	testing.expect_value(t, layout.init(l, terminal(1)), nil)
	_, _ = layout.split(l, l.root, axis, 0.5, terminal(3))
	_, _ = layout.split(l, layout.find_content(l, terminal(1)), axis, 0.5, terminal(2))
}

// Moves the pane showing `id` once, focused as in Arrange mode, and requires focus to stay on it.
@(private = "file")
step_focused :: proc(t: ^testing.T, l: ^layout.Layout, id: u32, direction: layout.Direction) -> bool {
	l.focus = layout.find_content(l, terminal(id))
	moved := step(l, id, direction)
	content, ok := layout.focused_content(l)
	testing.expect(t, ok && content == terminal(id))
	return moved
}

// Rects of A, B and C, in that order, along `axis` in a 400 square: each given as its start and length.
@(private = "file")
expect_row :: proc(t: ^testing.T, l: ^layout.Layout, axis: layout.Axis, a, b, c: [2]f32, loc := #caller_location) {
	want :: proc(axis: layout.Axis, span: [2]f32) -> layout.Rect {
		if axis == .Horizontal {return {span[0], 0, span[1], 400}}
		return {0, span[0], 400, span[1]}
	}
	testing.expect_value(t, placed(l, 1), want(axis, a), loc)
	testing.expect_value(t, placed(l, 2), want(axis, b), loc)
	testing.expect_value(t, placed(l, 3), want(axis, c), loc)
}

// The owner's row (WORK-477), A and B a quarter each and C the right half, A moving right with each press
// taking it one place: past B; into C's half at its near end, still the middle pane; past C; then, at the
// edge, the right half of the tab with B and C sharing the left half; then nothing. Focus stays on A.
@(test)
a_move_across_a_row_goes_one_place_per_press :: proc(t: ^testing.T) {
	for axis in layout.Axis {
		toward: layout.Direction = axis == .Horizontal ? .Right : .Down
		l: layout.Layout
		quarters_and_half(t, &l, axis, false)
		expect_row(t, &l, axis, {0, 100}, {100, 100}, {200, 200})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {100, 100}, {0, 100}, {200, 200})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {200, 100}, {0, 200}, {300, 100})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {300, 100}, {0, 200}, {200, 100})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {200, 200}, {0, 100}, {100, 100})
		testing.expect(t, !step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {200, 200}, {0, 100}, {100, 100})
		layout.destroy(&l)
	}
}

// The mirror, C the left half and B and A a quarter each, A moving left: past B, into C's half beside C,
// past C, then the left half of the tab. Up mirrors it in a column.
@(test)
a_move_back_across_a_row_goes_one_place_per_press :: proc(t: ^testing.T) {
	for axis in layout.Axis {
		toward: layout.Direction = axis == .Horizontal ? .Left : .Up
		l: layout.Layout
		quarters_and_half(t, &l, axis, true)
		expect_row(t, &l, axis, {300, 100}, {200, 100}, {0, 200})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {200, 100}, {300, 100}, {0, 200})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {100, 100}, {200, 200}, {0, 100})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {0, 100}, {200, 200}, {100, 100})
		testing.expect(t, step_focused(t, &l, 1, toward))
		expect_row(t, &l, axis, {0, 200}, {300, 100}, {200, 100})
		testing.expect(t, !step_focused(t, &l, 1, toward))
		layout.destroy(&l)
	}
}

// Docking up or down makes a full-width top or bottom half, as left and right make full-height halves.
@(test)
dock_pane_makes_a_top_or_bottom_half :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	quarters_and_half(t, &l, .Horizontal, false)
	_, up := layout.dock_pane(&l, layout.find_content(&l, terminal(1)), .Up)
	testing.expect(t, up)
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 400, 200})
	testing.expect_value(t, placed(&l, 2), layout.Rect{0, 200, 200, 200})
	_, down := layout.dock_pane(&l, layout.find_content(&l, terminal(3)), .Down)
	testing.expect(t, down)
	testing.expect_value(t, placed(&l, 3), layout.Rect{0, 200, 400, 200})
	testing.expect_value(t, placed(&l, 1), layout.Rect{0, 0, 400, 100})
}
