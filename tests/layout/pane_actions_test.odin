package layout_test

import "core:testing"
import "aio:layout"

@(test)
directional_splits_size_the_new_pane_and_preserve_focus :: proc(t: ^testing.T) {
	for direction in layout.Direction {
		l: layout.Layout
		testing.expect_value(t, layout.init(&l, terminal(1)), nil)
		rects := make([dynamic]layout.Pane_Rect)
		added, err := layout.split_direction(&l, l.focus, direction, 0.25, terminal(2))
		testing.expect_value(t, err, nil)
		testing.expect_value(t, l.focus, layout.Node_Id(0))
		layout.compute(&l, {0, 0, 400, 400}, 0, &rects)
		for r in rects {
			if r.node != added { continue }
			switch direction {
			case .Left: testing.expect_value(t, r.rect, layout.Rect{0, 0, 100, 400})
			case .Right: testing.expect_value(t, r.rect, layout.Rect{300, 0, 100, 400})
			case .Up: testing.expect_value(t, r.rect, layout.Rect{0, 0, 400, 100})
			case .Down: testing.expect_value(t, r.rect, layout.Rect{0, 300, 400, 100})
			}
		}
		delete(rects)
		layout.destroy(&l)
	}
}

@(test)
zoom_preserves_tree_and_navigation_geometry :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.focus, .Horizontal, 0.7, terminal(2))
	testing.expect_value(t, err, nil)
	l.focus = right
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	bars := make([dynamic]layout.Divider)
	defer delete(bars)
	l.zoomed = true
	layout.compute(&l, {0, 30, 401, 200}, 1, &rects)
	testing.expect_value(t, len(rects), 1)
	testing.expect_value(t, rects[0].node, right)
	testing.expect_value(t, rects[0].rect, layout.Rect{0, 30, 401, 200})
	layout.dividers(&l, {0, 30, 401, 200}, 1, &bars)
	testing.expect_value(t, len(bars), 0)
	layout.compute(&l, {0, 30, 401, 200}, 1, &rects, false)
	testing.expect_value(t, len(rects), 2)
	testing.expect_value(t, layout.focus_direction(rects[:], right, .Left), layout.Node_Id(0))
	l.zoomed = false
	layout.compute(&l, {0, 30, 401, 200}, 1, &rects)
	testing.expect_value(t, rects[0].rect.width, f32(280))
	l.zoomed = true
	testing.expect(t, layout.remove(&l, right))
	testing.expect(t, !l.zoomed)
	l.zoomed = true
	_, split_error := layout.split_direction(&l, l.focus, .Up, 0.5, terminal(3))
	testing.expect_value(t, split_error, nil)
	testing.expect(t, !l.zoomed)
}

@(test)
swap_moves_content_while_focus_follows :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.focus, .Horizontal, 0.7, terminal(2))
	testing.expect_value(t, err, nil)
	l.zoomed = true
	testing.expect(t, layout.swap(&l, 0, right))
	testing.expect_value(t, l.focus, right)
	testing.expect_value(t, l.nodes[right].(layout.Pane).content.id, u32(1))
	testing.expect_value(t, l.nodes[0].(layout.Pane).content.id, u32(2))
	testing.expect_value(t, l.nodes[0].(layout.Pane).order, u64(1))
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.7))
	testing.expect(t, l.zoomed)
	testing.expect(t, !layout.swap(&l, 0, 0))
	testing.expect(t, !layout.swap(&l, 0, l.root))
	testing.expect(t, !layout.swap(&l, layout.INVALID_NODE, right))
	testing.expect(t, layout.swap(&l, right, 0))
	testing.expect_value(t, l.focus, layout.Node_Id(0))
}

@(test)
balance_resets_nested_ratios_without_changing_panes :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split(&l, l.focus, .Horizontal, 0.7, terminal(2))
	testing.expect_value(t, err, nil)
	bottom, nested_error := layout.split(&l, right, .Vertical, 0.2, terminal(3))
	testing.expect_value(t, nested_error, nil)
	l.focus = bottom
	layout.balance(&l)
	for node in l.nodes {
		if split, ok := node.(layout.Split); ok { testing.expect_value(t, split.ratio, f32(0.5)) }
	}
	testing.expect_value(t, l.focus, bottom)
	testing.expect_value(t, l.nodes[bottom].(layout.Pane).content.id, u32(3))
	testing.expect(t, layout.remove(&l, bottom))
	layout.balance(&l)
}

@(test)
split_direction_clamps_ratios_and_background_removal_keeps_zoom :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, err := layout.split_direction(&l, l.focus, .Right, 2, terminal(2))
	testing.expect_value(t, err, nil)
	testing.expect(t, abs(l.nodes[l.root].(layout.Split).ratio-0.05) < 0.00001)
	l.zoomed = true
	testing.expect(t, layout.remove(&l, right))
	testing.expect(t, l.zoomed)
	_, next_error := layout.split_direction(&l, l.focus, .Left, -2, terminal(3))
	testing.expect_value(t, next_error, nil)
	testing.expect_value(t, l.nodes[l.root].(layout.Split).ratio, f32(0.05))
}
