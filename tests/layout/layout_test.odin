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
