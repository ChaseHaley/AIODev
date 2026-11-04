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
