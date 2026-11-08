package layout_test

import "aio:layout"
import "core:testing"

@(private = "file")
AREA :: layout.Rect{0, 0, 100, 50}

@(private = "file")
pane_of :: proc(id: u32) -> layout.Content {return {.Terminal, id}}

// Tiled panes first, then the shown floating panes, bottom first, as a window lays them out.
@(private = "file")
shown :: proc(l: ^layout.Layout, solo := false) -> [dynamic]layout.Pane_Rect {
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.place_shown(l, {tiled = AREA, floating = AREA}, solo, &rects)
	return rects
}

@(private = "file")
two_tiled :: proc(t: ^testing.T, l: ^layout.Layout) -> (a, b: layout.Node_Id) {
	testing.expect_value(t, layout.init(l, pane_of(1)), nil)
	a = l.root
	b, _ = layout.split(l, a, .Horizontal, 0.5, pane_of(2))
	return
}

@(test)
floating_pane_leaves_tiled_panes_and_zoom_alone :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b := two_tiled(t, &l)
	l.focus = b
	l.zoomed = true
	l.panes_changed = false
	before := shown(&l, true)
	f, err := layout.float_new(&l, pane_of(3), {0.5, 0.2, 0.4, 0.6})
	testing.expect_value(t, err, nil)
	testing.expect(t, l.zoomed && !l.panes_changed, "a new floating pane is no tiling change")
	testing.expect_value(t, l.focus, b)
	after := shown(&l, true)
	testing.expect_value(t, len(after), len(before) + 1)
	for rect, i in before {testing.expect_value(t, after[i], rect)}
	testing.expect_value(t, after[len(after) - 1].node, f)
	testing.expect(t, after[len(after) - 1].floating)
	testing.expect_value(t, after[len(after) - 1].rect, layout.Rect{50, 10, 40, 30})
	l.zoomed = false
	unzoomed := shown(&l)
	testing.expect_value(t, len(unzoomed), 3)
	testing.expect_value(t, unzoomed[0].node, a)
	testing.expect_value(t, unzoomed[1].node, b)
	testing.expect_value(t, unzoomed[1].rect.width, f32(50))
}

@(test)
focus_returns_to_the_tiled_pane_a_floating_pane_was_opened_over :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b := two_tiled(t, &l)
	l.focus = a
	f, _ := layout.float_new(&l, pane_of(3), {0.2, 0.2, 0.5, 0.5})
	testing.expect(t, !layout.focus_set(&l, f), "the newest floating pane is already on top")
	testing.expect_value(t, l.focus, f)
	testing.expect_value(t, layout.focus_tiled(&l), a)
	l.zoomed = true
	zoomed := shown(&l, true)
	testing.expect_value(t, zoomed[0].node, a)
	testing.expect_value(t, zoomed[0].rect, AREA)
	testing.expect(t, layout.float_minimize(&l, f, true))
	testing.expect_value(t, l.focus, a)
	testing.expect_value(t, len(shown(&l, true)), 1)
	testing.expect(t, layout.focus_set(&l, f), "focus brings a minimized pane back")
	testing.expect_value(t, l.focus, f)
	testing.expect(t, layout.remove(&l, f))
	testing.expect_value(t, l.focus, a)
	testing.expect(t, l.zoomed, "closing a floating pane keeps the tiled zoom")
	_ = b
}

@(test)
focus_raises_a_floating_pane_above_the_others :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	two_tiled(t, &l)
	lower, _ := layout.float_new(&l, pane_of(3), {0.1, 0.1, 0.5, 0.5})
	upper, _ := layout.float_new(&l, pane_of(4), {0.3, 0.3, 0.5, 0.5})
	rects := shown(&l)
	testing.expect_value(t, rects[len(rects) - 1].node, upper)
	top, found := layout.hit_test(rects[:], 40, 20)
	testing.expect(t, found && top.node == upper, "the upper pane takes the overlap")
	testing.expect(t, layout.focus_set(&l, lower))
	rects = shown(&l)
	testing.expect_value(t, rects[len(rects) - 1].node, lower)
	top, _ = layout.hit_test(rects[:], 40, 20)
	testing.expect_value(t, top.node, lower)
	under, _ := layout.hit_test(rects[:], 90, 45)
	testing.expect(t, !under.floating, "outside every card the tiled pane takes the point")
}

@(test)
floated_pane_docks_back_into_its_exact_slot :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b := two_tiled(t, &l)
	c, _ := layout.split(&l, b, .Vertical, 0.5, pane_of(3))
	before := shown(&l)
	layout.focus_set(&l, c)
	testing.expect(t, layout.set_floating(&l, c, true, {0.25, 0.25, 0.5, 0.5}))
	testing.expect_value(t, l.focus, c)
	testing.expect_value(t, layout.focus_tiled(&l), b)
	floated := shown(&l)
	testing.expect_value(t, len(floated), 3)
	testing.expect_value(t, floated[1].node, b)
	testing.expect_value(t, floated[1].rect.height, AREA.height)
	testing.expect(t, floated[2].floating && floated[2].node == c)
	dividers := make([dynamic]layout.Divider, context.temp_allocator)
	layout.dividers(&l, AREA, 0, &dividers)
	testing.expect_value(t, len(dividers), 1)
	testing.expect(t, layout.set_floating(&l, c, false))
	after := shown(&l)
	testing.expect_value(t, len(after), len(before))
	for rect, i in after {testing.expect_value(t, rect, before[i])}
	_ = a
}

@(test)
refloated_pane_returns_focus_to_the_pane_it_opened_over :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	_, b := two_tiled(t, &l)
	layout.focus_set(&l, b)
	f, _ := layout.float_new(&l, pane_of(3), {0.2, 0.2, 0.5, 0.5})
	layout.focus_set(&l, f)
	testing.expect(t, layout.set_floating(&l, f, false), "dock")
	testing.expect(t, layout.set_floating(&l, f, true, {0.2, 0.2, 0.5, 0.5}), "float again")
	testing.expect(t, layout.remove(&l, f))
	testing.expect_value(t, l.focus, b)
}

@(test)
tiling_keeps_one_pane_it_can_show :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, pane_of(1)), nil)
	only := l.root
	testing.expect(t, !layout.set_floating(&l, only, true, {0.2, 0.2, 0.5, 0.5}), "the lone tiled pane stays")
	f, _ := layout.float_new(&l, pane_of(2), {0.2, 0.2, 0.5, 0.5})
	testing.expect(t, !layout.set_linked(&l, f, true), "a floating pane has no linked window")
	testing.expect(t, layout.remove(&l, only))
	rects := shown(&l)
	testing.expect_value(t, len(rects), 1)
	testing.expect(t, !rects[0].floating, "the floating pane fills the tab once nothing else is left")
	testing.expect_value(t, rects[0].rect, AREA)
	testing.expect_value(t, l.focus, f)
}

@(test)
floating_bounds_stay_inside_the_area :: proc(t: ^testing.T) {
	b := layout.float_bounds_clamp({0.9, -0.5, 0.5, 2})
	testing.expect_value(t, b, layout.Rect{0.5, 0, 0.5, 1})
	tiny := layout.float_bounds_clamp({0.5, 0.5, 0.001, 0.001})
	testing.expect_value(t, tiny.width, layout.FLOAT_MINIMUM)
	testing.expect_value(t, tiny.height, layout.FLOAT_MINIMUM)
}

@(test)
floating_group_splits_minimizes_and_docks_as_one_window :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b := two_tiled(t, &l)
	testing.expect(t, layout.set_floating(&l, b, true, {0.2, 0.2, 0.6, 0.6}))
	c, err := layout.split_direction(&l, b, .Right, 0.5, pane_of(3))
	testing.expect_value(t, err, nil)
	root := layout.float_root(&l, b)
	testing.expect(t, root != layout.INVALID_NODE && root == layout.float_root(&l, c))
	_, split_root := l.nodes[root].(layout.Split)
	testing.expect(t, split_root, "splitting transfers the floating frame to the new branch")

	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(&l, AREA, 2, &rects)
	layout.floats_place(&l, AREA, 2, 0, &rects)
	if testing.expect_value(t, len(rects), 3) {
		testing.expect(t, rects[1].floating && rects[2].floating)
		testing.expect_value(t, rects[0].node, a)
		testing.expect_value(t, rects[0].rect, AREA)
	}
	frame, framed := layout.float_rect(&l, c, AREA)
	testing.expect(t, framed)
	testing.expect_value(t, frame, layout.Rect{20, 10, 60, 30})
	dividers := make([dynamic]layout.Divider, context.temp_allocator)
	layout.floats_dividers(&l, AREA, 2, 0, &dividers)
	testing.expect_value(t, len(dividers), 1)
	outer_ratio := l.nodes[l.root].(layout.Split).ratio
	testing.expect(t, layout.balance_related(&l, root))
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, outer_ratio)

	shown_count, minimized_count := layout.float_counts(&l)
	testing.expect_value(t, shown_count, 1)
	testing.expect_value(t, minimized_count, 0)
	testing.expect(t, layout.float_minimize(&l, c, true))
	testing.expect_value(t, len(shown(&l)), 1)
	testing.expect(t, layout.focus_set(&l, b), "focus restores the whole group")
	testing.expect(t, layout.set_floating(&l, c, false))
	testing.expect_value(t, layout.float_root(&l, b), layout.INVALID_NODE)
	testing.expect_value(t, layout.float_root(&l, c), layout.INVALID_NODE)
	testing.expect_value(t, len(shown(&l)), 3)
}

@(test)
closing_one_pane_keeps_the_remaining_split_pane_floating :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	_, b := two_tiled(t, &l)
	bounds := layout.Rect{0.25, 0.15, 0.5, 0.7}
	testing.expect(t, layout.set_floating(&l, b, true, bounds))
	c, err := layout.split_direction(&l, b, .Down, 0.5, pane_of(3))
	testing.expect_value(t, err, nil)
	testing.expect(t, layout.remove(&l, c))
	testing.expect_value(t, layout.float_root(&l, b), b)
	floating, ok := layout.float_of(&l, b)
	testing.expect(t, ok)
	testing.expect_value(t, floating.bounds, bounds)
}

// Panes in one floating group share its name, which survives a split or close inside it; tiled panes have
// none, and another group has its own.
@(test)
floating_group_keeps_its_name_through_splits_and_closes :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	_, b := two_tiled(t, &l)
	testing.expect(t, layout.set_floating(&l, b, true, {0.25, 0.15, 0.5, 0.7}))
	group := shown(&l)[1].group
	testing.expect(t, group != 0 && shown(&l)[0].group == 0)
	_, err := layout.split_direction(&l, b, .Down, 0.5, pane_of(3))
	testing.expect_value(t, err, nil)
	split := shown(&l)
	if !testing.expect_value(t, len(split), 3) {return}
	testing.expect(t, split[1].group == group && split[2].group == group)
	testing.expect(t, layout.remove(&l, b))
	testing.expect_value(t, shown(&l)[1].group, group)
	_, other_error := layout.float_new(&l, pane_of(4), {0.1, 0.1, 0.3, 0.3})
	testing.expect_value(t, other_error, nil)
	placed := shown(&l)
	if !testing.expect_value(t, len(placed), 3) {return}
	testing.expect(t, placed[2].group != 0 && placed[2].group != group)
}

@(test)
panes_move_into_and_out_of_a_floating_window :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b := two_tiled(t, &l)
	bounds := layout.Rect{0.2, 0.2, 0.6, 0.6}
	f, _ := layout.float_new(&l, pane_of(3), bounds)
	l.focus = b

	// Beside a lone floating pane, the moved pane joins it and the frame moves to the new split.
	moved, ok := layout.move_pane(&l, b, f, .Right)
	testing.expect(t, ok)
	root := layout.float_root(&l, moved)
	testing.expect(t, root != layout.INVALID_NODE && root == layout.float_root(&l, f))
	_, split_root := l.nodes[root].(layout.Split)
	testing.expect(t, split_root)
	floating, _ := layout.float_of(&l, f)
	testing.expect_value(t, floating.bounds, bounds)
	testing.expect_value(t, l.focus, moved)
	shown_count, _ := layout.float_counts(&l)
	testing.expect_value(t, shown_count, 1)

	_, refused := layout.move_pane(&l, a, f, .Down)
	testing.expect(t, !refused, "the tiling keeps its last pane")

	// Out beside a tiled pane, it leaves the group, which keeps its frame around the pane that stays.
	out, out_ok := layout.move_pane(&l, moved, a, .Left)
	testing.expect(t, out_ok)
	testing.expect_value(t, layout.float_root(&l, out), layout.INVALID_NODE)
	testing.expect_value(t, layout.float_root(&l, f), f)
	floating, _ = layout.float_of(&l, f)
	testing.expect_value(t, floating.bounds, bounds)
	testing.expect_value(t, len(shown(&l)), 3)

	// Docking along an edge of the tiling takes the last floating pane out too.
	docked, docked_ok := layout.dock_pane(&l, f, .Right)
	testing.expect(t, docked_ok)
	testing.expect_value(t, layout.float_root(&l, docked), layout.INVALID_NODE)
	shown_count, _ = layout.float_counts(&l)
	testing.expect_value(t, shown_count, 0)
}

@(test)
swapping_with_a_floating_pane_trades_contents_not_slots :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, _ := two_tiled(t, &l)
	f, _ := layout.float_new(&l, pane_of(3), {0.2, 0.2, 0.6, 0.6})
	testing.expect(t, layout.swap(&l, a, f))
	testing.expect_value(t, l.nodes[f].(layout.Pane).content, pane_of(1))
	testing.expect_value(t, l.nodes[a].(layout.Pane).content, pane_of(3))
	testing.expect(t, layout.is_floating(&l, f) && !layout.is_floating(&l, a))
}

@(test)
every_float_keeps_a_header_strip_above_its_panes :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	two_tiled(t, &l)
	lone, _ := layout.float_new(&l, pane_of(3), {0.2, 0.2, 0.6, 0.6})
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.floats_place(&l, AREA, 0, 5, &rects)
	testing.expect_value(t, rects[0].rect, layout.Rect{20, 15, 60, 25})
	_, err := layout.split_direction(&l, lone, .Right, 0.5, pane_of(4))
	testing.expect_value(t, err, nil)
	clear(&rects)
	layout.floats_place(&l, AREA, 0, 5, &rects)
	if testing.expect_value(t, len(rects), 2) {
		for pane in rects {
			testing.expect_value(t, pane.rect.y, f32(15))
			testing.expect_value(t, pane.rect.height, f32(25))
		}
	}
}
