package layout_test

import "aio:layout"
import "core:testing"

@(private = "file")
AREA :: layout.Rect{0, 0, 100, 50}

@(private = "file")
pane_of :: proc(id: u32) -> layout.Content {return {.Terminal, id}}

// One pane split right, then the new pane split down: 1 | (2 / 3).
@(private = "file")
three_panes :: proc(t: ^testing.T, l: ^layout.Layout) -> (a, b, c: layout.Node_Id) {
	testing.expect_value(t, layout.init(l, pane_of(1)), nil)
	a = l.root
	b, _ = layout.split(l, a, .Horizontal, 0.5, pane_of(2))
	c, _ = layout.split(l, b, .Vertical, 0.5, pane_of(3))
	return
}

@(private = "file")
shown :: proc(l: ^layout.Layout, gap: f32 = 0) -> [dynamic]layout.Pane_Rect {
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(l, AREA, gap, &rects)
	return rects
}

@(test)
linked_pane_gives_its_space_to_its_sibling :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b, c := three_panes(t, &l)
	testing.expect(t, layout.set_linked(&l, c, true))
	rects := shown(&l)
	testing.expect_value(t, len(rects), 2)
	testing.expect_value(t, rects[0].node, a)
	testing.expect_value(t, rects[1].node, b)
	testing.expect_value(t, rects[1].rect.height, AREA.height)
	dividers := make([dynamic]layout.Divider, context.temp_allocator)
	layout.dividers(&l, AREA, 0, &dividers)
	testing.expect_value(t, len(dividers), 1)
	testing.expect_value(t, dividers[0].axis, layout.Axis.Horizontal)
}

@(test)
linked_pane_returns_to_its_exact_slot :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	_, b, c := three_panes(t, &l)
	before := shown(&l)
	testing.expect(t, layout.set_linked(&l, b, true))
	testing.expect(t, layout.set_linked(&l, b, false))
	after := shown(&l)
	testing.expect_value(t, len(after), len(before))
	for rect, i in after {testing.expect_value(t, rect, before[i])}
	testing.expect(t, !layout.set_linked(&l, c, false), "a shown pane is already home")
}

@(test)
linked_pane_cannot_hold_focus :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b, c := three_panes(t, &l)
	l.focus = c
	testing.expect(t, layout.set_linked(&l, c, true))
	testing.expect_value(t, l.focus, b)
	testing.expect(t, layout.set_linked(&l, b, true))
	testing.expect_value(t, l.focus, a)
	rects := shown(&l)
	testing.expect_value(t, layout.focus_cycle(rects[:], l.focus, 1), a)
	testing.expect_value(t, layout.focus_direction(rects[:], l.focus, .Right), a)
}

@(test)
last_shown_pane_cannot_leave :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, pane_of(1)), nil)
	testing.expect(t, !layout.set_linked(&l, l.root, true), "a lone pane has nowhere to leave from")
	second, _ := layout.split(&l, l.root, .Horizontal, 0.5, pane_of(2))
	first := layout.Node_Id(0)
	testing.expect(t, layout.set_linked(&l, second, true))
	testing.expect(t, !layout.set_linked(&l, first, true))
	testing.expect_value(t, len(shown(&l)), 1)
}

@(test)
removing_the_last_shown_pane_brings_linked_panes_back :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b, c := three_panes(t, &l)
	testing.expect(t, layout.set_linked(&l, b, true))
	testing.expect(t, layout.set_linked(&l, c, true))
	l.focus = a
	testing.expect(t, layout.remove(&l, a))
	rects := shown(&l)
	testing.expect_value(t, len(rects), 2)
	pane, is_pane := l.nodes[l.focus].(layout.Pane)
	testing.expect(t, is_pane && !pane.linked)
}

@(test)
removing_a_linked_pane_collapses_its_slot :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b, c := three_panes(t, &l)
	testing.expect(t, layout.set_linked(&l, c, true))
	l.focus = a
	testing.expect(t, layout.remove(&l, c))
	testing.expect_value(t, l.focus, a)
	rects := shown(&l)
	testing.expect_value(t, len(rects), 2)
	testing.expect_value(t, rects[1].node, b)
}

@(test)
removing_a_focused_pane_skips_a_linked_sibling :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b, c := three_panes(t, &l)
	testing.expect(t, layout.set_linked(&l, c, true))
	l.focus = b
	testing.expect(t, layout.remove(&l, b))
	testing.expect_value(t, l.focus, a)
}

@(test)
resize_skips_a_split_with_a_linked_side :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, pane_of(1)), nil)
	a := l.root
	b, _ := layout.split(&l, a, .Horizontal, 0.5, pane_of(2))
	c, _ := layout.split(&l, b, .Horizontal, 0.5, pane_of(3))
	testing.expect(t, layout.set_linked(&l, c, true))
	inner := l.nodes[l.root].(layout.Split).second
	outer_before := l.nodes[l.root].(layout.Split).ratio
	inner_before := l.nodes[inner].(layout.Split).ratio
	dividers := make([dynamic]layout.Divider, context.temp_allocator)
	layout.dividers(&l, AREA, 0, &dividers)
	testing.expect(t, layout.resize_pixels(&l, b, .Horizontal, 10, dividers[:]))
	testing.expect_value(t, l.nodes[inner].(layout.Split).ratio, inner_before)
	testing.expect(t, l.nodes[l.root].(layout.Split).ratio != outer_before)
}

@(test)
balance_counts_only_shown_panes_and_keeps_the_linked_share :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, pane_of(1)), nil)
	a := l.root
	b, _ := layout.split(&l, a, .Horizontal, 0.3, pane_of(2))
	c, _ := layout.split(&l, b, .Horizontal, 0.25, pane_of(3))
	testing.expect(t, layout.set_linked(&l, c, true))
	inner := l.nodes[l.root].(layout.Split).second
	testing.expect(t, layout.balance_related(&l, l.root))
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.5))
	testing.expect_value(t, l.nodes[inner].(layout.Split).ratio, f32(0.25))
}

@(test)
docking_refuses_the_only_shown_pane :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, pane_of(1)), nil)
	first := l.root
	second, _ := layout.split(&l, first, .Horizontal, 0.5, pane_of(2))
	testing.expect(t, layout.set_linked(&l, second, true))
	_, docked := layout.dock_pane(&l, first, .Left)
	testing.expect(t, !docked)
	linked, is_pane := l.nodes[second].(layout.Pane)
	testing.expect(t, is_pane && linked.linked)
}

@(test)
linking_ends_a_view_that_hides_panes :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	_, _, c := three_panes(t, &l)
	l.zoomed, l.panes_changed = true, false
	testing.expect(t, layout.set_linked(&l, c, true))
	testing.expect(t, !l.zoomed && l.panes_changed)
}

@(test)
repair_recovers_damaged_saved_links :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	a, b, c := three_panes(t, &l)
	for node in ([?]layout.Node_Id{a, b, c}) {
		pane := l.nodes[node].(layout.Pane)
		pane.linked = true
		l.nodes[node] = pane
	}
	l.focus = b
	layout.links_repair(&l)
	testing.expect_value(t, len(shown(&l)), 3)
	testing.expect_value(t, l.focus, b)
	pane := l.nodes[a].(layout.Pane)
	pane.linked = true
	l.nodes[a] = pane
	l.focus = a
	layout.links_repair(&l)
	testing.expect_value(t, l.focus, b)
}

// A linked pane, split in its window and stored back, as the window does: 1 | [2 / 3].
@(private = "file")
linked_split :: proc(t: ^testing.T, home, view: ^layout.Layout) -> (slot: layout.Node_Id) {
	testing.expect_value(t, layout.init(home, pane_of(1)), nil)
	b, _ := layout.split(home, home.root, .Horizontal, 0.5, pane_of(2))
	testing.expect(t, layout.set_linked(home, b, true))
	testing.expect_value(t, layout.link_view_load(view, home, b), nil)
	_, _ = layout.split(view, view.root, .Vertical, 0.5, pane_of(3))
	stored, ok := layout.link_view_store(home, b, view)
	testing.expect(t, ok)
	return stored
}

@(test)
a_stored_view_keeps_every_pane_in_the_tree_and_out_of_its_view :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	slot := linked_split(t, &home, &view)
	testing.expect_value(t, layout.pane_count(&home), 3)
	testing.expect(t, home.nodes[slot].(layout.Split).linked)
	rects := shown(&home)
	testing.expect_value(t, len(rects), 1)
	testing.expect_value(t, rects[0].content, pane_of(1))
	testing.expect_value(t, rects[0].rect, AREA)
	testing.expect(t, layout.same_arrangement(&home, slot, &view, view.root))
	testing.expect_value(t, layout.link_root(&home, layout.find_content(&home, pane_of(3))), slot)
	testing.expect_value(t, layout.link_root(&home, layout.find_content(&home, pane_of(1))), layout.INVALID_NODE)
	view_rects := shown(&view)
	testing.expect_value(t, len(view_rects), 2)
}

@(test)
returning_a_stored_slot_restores_its_arrangement :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	slot := linked_split(t, &home, &view)
	testing.expect(t, layout.set_linked(&home, slot, false))
	rects := shown(&home)
	testing.expect_value(t, len(rects), 3)
	testing.expect_value(t, rects[1].rect, layout.Rect{50, 0, 50, 25})
	testing.expect_value(t, rects[2].rect, layout.Rect{50, 25, 50, 25})
}

@(test)
a_slot_survives_losing_panes :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	_ = linked_split(t, &home, &view)
	testing.expect(t, layout.remove(&home, layout.find_content(&home, pane_of(3))))
	remaining := layout.find_content(&home, pane_of(2))
	testing.expect_value(t, layout.link_root(&home, remaining), remaining)
	testing.expect_value(t, len(shown(&home)), 1)
	testing.expect(t, !layout.same_panes(&home, remaining, &view, view.root))
	testing.expect_value(t, layout.link_view_load(&view, &home, remaining), nil)
	testing.expect_value(t, layout.pane_count(&view), 1)
	testing.expect(t, view.panes_changed, "a change of panes ends a view that hides panes")
}

@(test)
one_pane_returning_takes_the_slots_area :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	_ = linked_split(t, &home, &view)
	returned, ok := layout.link_return_pane(&home, layout.find_content(&home, pane_of(3)))
	testing.expect(t, ok)
	testing.expect_value(t, home.nodes[returned].(layout.Pane).content, pane_of(3))
	testing.expect_value(t, layout.link_root(&home, returned), layout.INVALID_NODE)
	rects := shown(&home)
	testing.expect_value(t, len(rects), 2)
	testing.expect_value(t, rects[1].content, pane_of(3))
	testing.expect_value(t, rects[1].rect, layout.Rect{50, 0, 50, 50})
	still := layout.find_content(&home, pane_of(2))
	testing.expect_value(t, layout.link_root(&home, still), still)
}

@(test)
storing_a_view_keeps_the_focus_order_of_panes_the_tab_knew :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	slot := linked_split(t, &home, &view)
	before := home.nodes[layout.find_content(&home, pane_of(2))].(layout.Pane).order
	testing.expect(t, layout.swap(&view, layout.find_content(&view, pane_of(2)), layout.find_content(&view, pane_of(3))))
	testing.expect(t, !layout.same_arrangement(&home, slot, &view, view.root))
	testing.expect(t, layout.same_panes(&home, slot, &view, view.root))
	stored, ok := layout.link_view_store(&home, slot, &view)
	testing.expect(t, ok)
	testing.expect_value(t, home.nodes[layout.find_content(&home, pane_of(2))].(layout.Pane).order, before)
	testing.expect(t, layout.same_arrangement(&home, stored, &view, view.root))
}

@(test)
balance_leaves_a_slots_arrangement_to_its_window :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	testing.expect_value(t, layout.init(&view, pane_of(2)), nil)
	testing.expect_value(t, layout.init(&home, pane_of(1)), nil)
	b, _ := layout.split(&home, home.root, .Horizontal, 0.3, pane_of(2))
	testing.expect(t, layout.set_linked(&home, b, true))
	_, _ = layout.split(&view, view.root, .Vertical, 0.25, pane_of(3))
	slot, ok := layout.link_view_store(&home, b, &view)
	testing.expect(t, ok)
	layout.balance(&home)
	testing.expect_value(t, home.nodes[slot].(layout.Split).ratio, f32(0.25))
	testing.expect_value(t, home.nodes[home.root].(layout.Split).ratio, f32(0.5))
}

@(test)
a_pane_can_join_a_slot_from_its_tab :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	testing.expect_value(t, layout.init(&home, pane_of(1)), nil)
	slot, _ := layout.split(&home, home.root, .Horizontal, 0.5, pane_of(2))
	testing.expect(t, layout.set_linked(&home, slot, true))
	added, ok := layout.slot_insert_pane(
		&home,
		slot,
		layout.Pane{content = pane_of(3), order = 3},
		layout.INVALID_NODE,
		.Down,
		true,
	)
	if !testing.expect(t, ok) {return}
	root := layout.link_root(&home, slot)
	testing.expect(t, root != layout.INVALID_NODE)
	testing.expect_value(t, layout.link_root(&home, added), root)
	testing.expect(t, home.nodes[root].(layout.Split).linked)
	testing.expect_value(t, layout.pane_count(&home), 3)
	testing.expect_value(t, len(shown(&home)), 1)
	testing.expect_value(t, layout.link_view_load(&view, &home, root), nil)
	testing.expect_value(t, layout.pane_count(&view), 2)
}

@(test)
a_pane_can_join_inside_a_slot_beside_its_panes :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	slot := linked_split(t, &home, &view)
	target := layout.find_content(&home, pane_of(3))
	added, ok := layout.slot_insert_pane(
		&home,
		slot,
		layout.Pane{content = pane_of(4), order = 4},
		target,
		.Right,
		false,
	)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, layout.link_root(&home, added), slot)
	testing.expect(t, !home.nodes[added].(layout.Pane).linked)
	testing.expect_value(t, layout.pane_count(&home), 4)
	testing.expect_value(t, layout.link_view_load(&view, &home, slot), nil)
	testing.expect_value(t, layout.pane_count(&view), 3)
}

@(test)
a_shown_pane_can_join_a_slot_in_its_tab :: proc(t: ^testing.T) {
	home, view: layout.Layout
	defer layout.destroy(&home)
	defer layout.destroy(&view)
	a, b, c := three_panes(t, &home)
	testing.expect(t, layout.set_linked(&home, c, true))
	added, ok := layout.slot_take_pane(&home, b, c, layout.INVALID_NODE, .Down, true)
	if !testing.expect(t, ok) {return}
	root := layout.link_root(&home, c)
	testing.expect(t, root != layout.INVALID_NODE)
	testing.expect_value(t, layout.link_root(&home, added), root)
	testing.expect(t, !home.nodes[added].(layout.Pane).linked)
	testing.expect_value(t, len(shown(&home)), 1)
	testing.expect_value(t, shown(&home)[0].node, a)
	testing.expect_value(t, layout.pane_count(&home), 3)
	testing.expect_value(t, layout.link_view_load(&view, &home, root), nil)
	testing.expect_value(t, layout.pane_count(&view), 2)
}

@(test)
a_slot_cannot_take_the_only_shown_pane_or_one_of_its_own :: proc(t: ^testing.T) {
	home: layout.Layout
	defer layout.destroy(&home)
	testing.expect_value(t, layout.init(&home, pane_of(1)), nil)
	first := home.root
	slot, _ := layout.split(&home, first, .Horizontal, 0.5, pane_of(2))
	testing.expect(t, layout.set_linked(&home, slot, true))
	_, taken := layout.slot_take_pane(&home, first, slot, layout.INVALID_NODE, .Right, true)
	testing.expect(t, !taken)
	testing.expect_value(t, layout.pane_count(&home), 2)
	testing.expect(t, !home.nodes[first].(layout.Pane).linked)

	_, taken = layout.slot_take_pane(&home, slot, slot, layout.INVALID_NODE, .Right, true)
	testing.expect(t, !taken)
}

@(test)
a_pane_can_join_another_tabs_slot :: proc(t: ^testing.T) {
	source, destination, view: layout.Layout
	defer layout.destroy(&source)
	defer layout.destroy(&destination)
	defer layout.destroy(&view)
	testing.expect_value(t, layout.init(&source, pane_of(1)), nil)
	moved, _ := layout.split(&source, source.root, .Horizontal, 0.5, pane_of(2))
	testing.expect_value(t, layout.init(&destination, pane_of(3)), nil)
	slot, _ := layout.split(&destination, destination.root, .Horizontal, 0.5, pane_of(4))
	testing.expect(t, layout.set_linked(&destination, slot, true))
	added, ok := layout.transfer_pane_to_slot(
		&source,
		&destination,
		moved,
		slot,
		layout.INVALID_NODE,
		.Down,
		true,
	)
	if !testing.expect(t, ok) {return}
	root := layout.link_root(&destination, slot)
	testing.expect(t, root != layout.INVALID_NODE)
	testing.expect_value(t, layout.link_root(&destination, added), root)
	testing.expect(t, !destination.nodes[added].(layout.Pane).linked)
	testing.expect_value(t, layout.pane_count(&source), 1)
	testing.expect_value(t, layout.pane_count(&destination), 3)
	testing.expect_value(t, layout.find_content(&source, pane_of(2)), layout.INVALID_NODE)
	testing.expect_value(t, layout.link_view_load(&view, &destination, root), nil)
	testing.expect_value(t, layout.pane_count(&view), 2)
}

@(test)
a_slot_transfer_refuses_a_target_outside_the_slot :: proc(t: ^testing.T) {
	source, destination: layout.Layout
	defer layout.destroy(&source)
	defer layout.destroy(&destination)
	testing.expect_value(t, layout.init(&source, pane_of(1)), nil)
	moved, _ := layout.split(&source, source.root, .Horizontal, 0.5, pane_of(2))
	testing.expect_value(t, layout.init(&destination, pane_of(3)), nil)
	slot, _ := layout.split(&destination, destination.root, .Horizontal, 0.5, pane_of(4))
	testing.expect(t, layout.set_linked(&destination, slot, true))
	_, outside := layout.transfer_pane_to_slot(
		&source,
		&destination,
		moved,
		slot,
		destination.root,
		.Right,
		false,
	)
	testing.expect(t, !outside)
	testing.expect_value(t, layout.pane_count(&source), 2)
	testing.expect_value(t, layout.pane_count(&destination), 2)
}

@(test)
a_slot_transfer_refuses_content_the_destination_already_shows :: proc(t: ^testing.T) {
	source, destination: layout.Layout
	defer layout.destroy(&source)
	defer layout.destroy(&destination)
	testing.expect_value(t, layout.init(&source, pane_of(1)), nil)
	moved, _ := layout.split(&source, source.root, .Horizontal, 0.5, pane_of(2))
	testing.expect_value(t, layout.init(&destination, pane_of(3)), nil)
	slot, _ := layout.split(&destination, destination.root, .Horizontal, 0.5, pane_of(2))
	testing.expect(t, layout.set_linked(&destination, slot, true))
	_, copied := layout.transfer_pane_to_slot(
		&source,
		&destination,
		moved,
		slot,
		layout.INVALID_NODE,
		.Down,
		true,
	)
	testing.expect(t, !copied)
	testing.expect_value(t, layout.pane_count(&source), 2)
	testing.expect_value(t, layout.pane_count(&destination), 2)
}

@(test)
a_slot_transfer_refuses_the_last_shown_pane_of_a_linked_tab :: proc(t: ^testing.T) {
	source, destination: layout.Layout
	defer layout.destroy(&source)
	defer layout.destroy(&destination)
	testing.expect_value(t, layout.init(&source, pane_of(1)), nil)
	shown := source.root
	slot, _ := layout.split(&source, shown, .Horizontal, 0.5, pane_of(2))
	testing.expect(t, layout.set_linked(&source, slot, true))
	testing.expect_value(t, layout.init(&destination, pane_of(3)), nil)
	destination_slot, _ := layout.split(&destination, destination.root, .Horizontal, 0.5, pane_of(4))
	testing.expect(t, layout.set_linked(&destination, destination_slot, true))
	_, drained := layout.transfer_pane_to_slot(
		&source,
		&destination,
		shown,
		destination_slot,
		layout.INVALID_NODE,
		.Down,
		true,
	)
	testing.expect(t, !drained)
	testing.expect_value(t, layout.link_root(&source, shown), layout.INVALID_NODE)
	testing.expect_value(t, layout.pane_count(&source), 2)
}
