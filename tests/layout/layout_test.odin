package layout_test

import "core:testing"
import "aio:layout"

terminal :: proc(id: u32) -> layout.Content {
	return {.Terminal, id}
}

@(test)
single_pane_fills_the_area :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(7)), nil)
	defer layout.destroy(&l)
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(&l, {10, 20, 300, 200}, 4, &rects)
	testing.expect_value(t, len(rects), 1)
	testing.expect_value(t, rects[0].content, terminal(7))
	testing.expect_value(t, rects[0].rect, layout.Rect{10, 20, 300, 200})
}

@(test)
splits_divide_space_with_gaps :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.root, .Horizontal, 0.25, terminal(2))
	testing.expect_value(t, err, nil)
	_, err = layout.split(&l, right, .Vertical, 0.5, terminal(3))
	testing.expect_value(t, err, nil)
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(&l, {0, 0, 404, 204}, 4, &rects)
	testing.expect_value(t, len(rects), 3)
	testing.expect_value(t, rects[0].rect, layout.Rect{0, 0, 100, 204})
	testing.expect_value(t, rects[1].rect, layout.Rect{104, 0, 300, 100})
	testing.expect_value(t, rects[2].rect, layout.Rect{104, 104, 300, 100})
	testing.expect_value(t, rects[2].content, terminal(3))
	hit, found := layout.hit_test(rects[:], 200, 150)
	testing.expect(t, found)
	testing.expect_value(t, hit.content, terminal(3))
	_, gap := layout.hit_test(rects[:], 102, 50)
	testing.expect(t, !gap)
	testing.expect_value(t, l.nodes[l.focus].(layout.Pane).content, terminal(1))
}

@(test)
ratios_are_clamped :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	_, err := layout.split(&l, l.root, .Horizontal, 2, terminal(2))
	testing.expect_value(t, err, nil)
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.95))
}

@(test)
removal_preserves_survivors_and_reuses_vacant_slots :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	left := l.root
	right, err := layout.split(&l, left, .Horizontal, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	bottom, nested_error := layout.split(&l, right, .Vertical, 0.5, terminal(3))
	testing.expect_value(t, nested_error, nil)
	testing.expect_value(t, l.nodes[left].(layout.Pane).content, terminal(1))
	testing.expect_value(t, l.nodes[right].(layout.Pane).content, terminal(2))
	l.focus = bottom
	capacity := len(l.nodes)
	testing.expect(t, layout.remove(&l, bottom))
	testing.expect_value(t, l.focus, right)
	testing.expect_value(t, l.nodes[right].(layout.Pane).content, terminal(2))
	testing.expect(t, !layout.remove(&l, bottom))
	testing.expect(t, !layout.remove(&l, layout.INVALID_NODE))
	again, split_error := layout.split(&l, right, .Vertical, 0.5, terminal(4))
	testing.expect_value(t, split_error, nil)
	testing.expect_value(t, len(l.nodes), capacity)
	testing.expect(t, l.nodes[again].(layout.Pane).order > l.nodes[right].(layout.Pane).order)
	testing.expect_value(t, l.nodes[again].(layout.Pane).content, terminal(4))
	l.focus = left
	testing.expect(t, layout.remove(&l, right))
	testing.expect_value(t, l.focus, left)
	testing.expect_value(t, l.nodes[again].(layout.Pane).content, terminal(4))
	testing.expect(t, layout.remove(&l, left))
	testing.expect_value(t, l.root, again)
	testing.expect_value(t, l.focus, again)
	testing.expect(t, layout.remove(&l, again))
	testing.expect_value(t, l.root, layout.INVALID_NODE)
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(&l, {0, 0, 100, 100}, 1, &rects)
	testing.expect_value(t, len(rects), 0)
}

@(test)
directional_focus_uses_nested_geometry_and_stops_at_edges :: proc(t: ^testing.T) {
	rects := []layout.Pane_Rect{
		{node = 0, rect = {0, 0, 100, 204}},
		{node = 1, rect = {104, 0, 100, 100}},
		{node = 2, rect = {104, 104, 100, 100}},
	}
	testing.expect_value(t, layout.focus_direction(rects, 0, .Right), layout.Node_Id(1))
	testing.expect_value(t, layout.focus_direction(rects, 1, .Down), layout.Node_Id(2))
	testing.expect_value(t, layout.focus_direction(rects, 2, .Up), layout.Node_Id(1))
	testing.expect_value(t, layout.focus_direction(rects, 2, .Left), layout.Node_Id(0))
	testing.expect_value(t, layout.focus_direction(rects, 0, .Left), layout.Node_Id(0))
	testing.expect_value(t, layout.focus_direction(rects, 1, .Right), layout.Node_Id(1))
	testing.expect_value(t, layout.focus_direction(rects, 2, .Down), layout.Node_Id(2))
	testing.expect_value(t, layout.focus_direction(rects, layout.INVALID_NODE, .Up), layout.INVALID_NODE)
}

@(test)
resize_uses_nearest_matching_ancestor_and_clamps :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	left := l.root
	right, err := layout.split(&l, left, .Horizontal, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	bottom, nested_error := layout.split(&l, right, .Vertical, 0.5, terminal(3))
	testing.expect_value(t, nested_error, nil)
	testing.expect(t, layout.resize(&l, bottom, .Horizontal, 0.1))
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.6))
	testing.expect(t, layout.resize(&l, bottom, .Vertical, -2))
	branch := l.nodes[l.root].(layout.Split).second
	testing.expect_value(t, l.nodes[branch].(layout.Split).ratio, f32(0.05))
	testing.expect(t, layout.resize(&l, bottom, .Vertical, 2))
	testing.expect_value(t, l.nodes[branch].(layout.Split).ratio, f32(0.95))
	testing.expect(t, !layout.resize(&l, left, .Vertical, 0.1))
}

@(test)
dividers_hit_drag_and_reject_stale_nodes :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	_, nested_error := layout.split(&l, right, .Vertical, 0.5, terminal(3))
	testing.expect_value(t, nested_error, nil)
	dividers := make([dynamic]layout.Divider)
	defer delete(dividers)
	layout.dividers(&l, {0, 0, 204, 204}, 4, &dividers)
	testing.expect_value(t, len(dividers), 2)
	testing.expect_value(t, dividers[0].rect, layout.Rect{100, 0, 4, 204})
	testing.expect_value(t, dividers[1].rect, layout.Rect{104, 100, 100, 4})
	d, hit := layout.divider_hit_test(dividers[:], 99, 50, 2)
	testing.expect(t, hit)
	testing.expect_value(t, d.node, l.root)
	_, outside := layout.divider_hit_test(dividers[:], 10, 10, 2)
	testing.expect(t, !outside)
	testing.expect(t, layout.drag_divider(&l, d, 152, 0, 4))
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.75))
	testing.expect(t, layout.drag_divider(&l, d, 500, 0, 4))
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.95))
	testing.expect(t, !layout.drag_divider(&l, {node = layout.INVALID_NODE}, 0, 0, 4))
	testing.expect(t, !layout.drag_divider(&l, {node = right}, 0, 0, 4))
	testing.expect(t, !layout.drag_divider(&l, {node = l.root, area = {}}, 0, 0, 4))
	tiny := make([dynamic]layout.Pane_Rect)
	defer delete(tiny)
	layout.compute(&l, {0, 0, 0, 0}, 4, &tiny)
	for pane in tiny { testing.expect(t, pane.rect.width >= 0 && pane.rect.height >= 0) }
}

@(test)
pane_and_divider_edges_share_whole_pixels :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	_, nested_error := layout.split(&l, right, .Vertical, 0.5, terminal(3))
	testing.expect_value(t, nested_error, nil)
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	dividers := make([dynamic]layout.Divider)
	defer delete(dividers)
	layout.compute(&l, {0, 30, 1096, 594}, 1, &rects)
	layout.dividers(&l, {0, 30, 1096, 594}, 1, &dividers)
	for pane in rects {
		testing.expect_value(t, pane.rect.x, f32(int(pane.rect.x)))
		testing.expect_value(t, pane.rect.y, f32(int(pane.rect.y)))
	}
	testing.expect_value(t, rects[0].rect.width, dividers[0].rect.x)
	testing.expect_value(t, rects[1].rect.y+rects[1].rect.height, dividers[1].rect.y)
	testing.expect_value(t, rects[2].rect.y, dividers[1].rect.y+1)
}

@(test)
focus_cycles_in_creation_order_and_wraps :: proc(t: ^testing.T) {
	rects := []layout.Pane_Rect{{node = 7, order = 1}, {node = 3, order = 3}, {node = 9, order = 2}}
	testing.expect_value(t, layout.focus_cycle(rects, 7, 1), layout.Node_Id(9))
	testing.expect_value(t, layout.focus_cycle(rects, 7, -1), layout.Node_Id(3))
	testing.expect_value(t, layout.focus_cycle(rects, 3, 1), layout.Node_Id(7))
	testing.expect_value(t, layout.focus_cycle(rects, 7, 6), layout.Node_Id(7))
	testing.expect_value(t, layout.focus_cycle(nil, 7, 1), layout.Node_Id(7))
	testing.expect_value(t, layout.focus_cycle(rects, layout.INVALID_NODE, -1), layout.INVALID_NODE)
}

@(test)
pixel_resize_uses_the_matching_divider_extent :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.root, .Horizontal, 0.5, terminal(2))
	testing.expect_value(t, err, nil)
	_, nested_error := layout.split(&l, right, .Vertical, 0.5, terminal(3))
	testing.expect_value(t, nested_error, nil)
	dividers := make([dynamic]layout.Divider)
	defer delete(dividers)
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.dividers(&l, {0, 0, 401, 201}, 1, &dividers)
	testing.expect(t, layout.resize_pixels(&l, right, .Horizontal, 10, dividers[:]))
	testing.expect(t, layout.resize_pixels(&l, right, .Vertical, -10, dividers[:]))
	layout.compute(&l, {0, 0, 401, 201}, 1, &rects)
	testing.expect_value(t, rects[0].rect.width, f32(210))
	testing.expect_value(t, rects[1].rect.height, f32(90))
	testing.expect(t, !layout.resize_pixels(&l, l.root, .Horizontal, 10, dividers[:]))
	testing.expect(t, !layout.resize_pixels(&l, right, .Vertical, 10, nil))
}
