package layout_test

import "aio:layout"
import "core:testing"

@(private = "file")
AREA :: layout.Rect{0, 0, 100, 50}

@(private = "file")
pane_of :: proc(id: u32) -> layout.Content {return {.Terminal, id}}

// Tiled panes first, then the shown floating panes, bottom first, as a window lays them out.
@(private = "file")
shown :: proc(l: ^layout.Layout) -> [dynamic]layout.Pane_Rect {
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(l, AREA, 0, &rects)
	layout.floats_place(l, AREA, &rects)
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
	before := shown(&l)
	f, err := layout.float_new(&l, pane_of(3), {0.5, 0.2, 0.4, 0.6})
	testing.expect_value(t, err, nil)
	testing.expect(t, l.zoomed && !l.panes_changed, "a new floating pane is no tiling change")
	testing.expect_value(t, l.focus, b)
	after := shown(&l)
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
	zoomed := shown(&l)
	testing.expect_value(t, zoomed[0].node, a)
	testing.expect_value(t, zoomed[0].rect, AREA)
	testing.expect(t, layout.float_minimize(&l, f, true))
	testing.expect_value(t, l.focus, a)
	testing.expect_value(t, len(shown(&l)), 1)
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
