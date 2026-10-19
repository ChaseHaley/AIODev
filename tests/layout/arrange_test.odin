package layout_test

import "core:testing"
import "aio:layout"

@(private)
rect_of :: proc(rects: []layout.Pane_Rect, id: u32) -> layout.Rect {
	for r in rects { if r.content.id == id { return r.rect } }
	return {}
}

@(test)
balance_related_equalizes_one_axis_run_only :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	b, _ := layout.split(&l, l.focus, .Horizontal, 0.5, terminal(2))
	c, _ := layout.split(&l, b, .Horizontal, 0.8, terminal(3))
	_, _ = layout.split(&l, c, .Vertical, 0.2, terminal(4))
	bars := make([dynamic]layout.Divider)
	defer delete(bars)
	layout.dividers(&l, {0, 0, 300, 300}, 0, &bars)
	inner := layout.INVALID_NODE
	vertical := layout.INVALID_NODE
	for d in bars {
		if d.axis == .Vertical { vertical = d.node }
		else if d.rect.x > 150 { inner = d.node }
	}
	testing.expect(t, layout.balance_related(&l, inner))
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(&l, {0, 0, 300, 300}, 0, &rects)
	testing.expect_value(t, rect_of(rects[:], 1).width, 100)
	testing.expect_value(t, rect_of(rects[:], 2).width, 100)
	testing.expect_value(t, rect_of(rects[:], 3).width, 100)
	testing.expect_value(t, rect_of(rects[:], 3).height, 60)
	testing.expect(t, layout.balance_related(&l, vertical))
	layout.compute(&l, {0, 0, 300, 300}, 0, &rects)
	testing.expect_value(t, rect_of(rects[:], 3).height, 150)
	testing.expect_value(t, rect_of(rects[:], 1).width, 100)
	testing.expect(t, !layout.balance_related(&l, l.focus))
	testing.expect(t, !layout.balance_related(&l, layout.Node_Id(99)))
}

@(test)
move_pane_relocates_content_and_keeps_focus_and_order :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	b, _ := layout.split(&l, l.focus, .Horizontal, 0.5, terminal(2))
	c, _ := layout.split(&l, b, .Vertical, 0.5, terminal(3))
	first := l.focus
	l.focus = c
	order := l.nodes[c].(layout.Pane).order
	moved, ok := layout.move_pane(&l, c, first, .Up)
	testing.expect(t, ok)
	testing.expect_value(t, l.focus, moved)
	testing.expect_value(t, l.nodes[moved].(layout.Pane).order, order)
	testing.expect_value(t, l.nodes[moved].(layout.Pane).content, terminal(3))
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(&l, {0, 0, 400, 400}, 0, &rects)
	testing.expect_value(t, len(rects), 3)
	testing.expect_value(t, rect_of(rects[:], 3), layout.Rect{0, 0, 200, 200})
	testing.expect_value(t, rect_of(rects[:], 1), layout.Rect{0, 200, 200, 200})
	testing.expect_value(t, rect_of(rects[:], 2), layout.Rect{200, 0, 200, 400})
	_, same := layout.move_pane(&l, moved, moved, .Left)
	testing.expect(t, !same)
	_, root := layout.move_pane(&l, l.root, moved, .Left)
	testing.expect(t, !root)
	nodes := len(l.nodes)
	for _ in 0..<8 {
		next, again := layout.move_pane(&l, l.focus, first, .Right)
		testing.expect(t, again)
		next, again = layout.move_pane(&l, next, first, .Left)
		testing.expect(t, again)
	}
	testing.expect_value(t, len(l.nodes), nodes)
}

@(test)
divider_hit_all_finds_junctions :: proc(t: ^testing.T) {
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	right, _ := layout.split(&l, l.focus, .Horizontal, 0.5, terminal(2))
	_, _ = layout.split(&l, right, .Vertical, 0.5, terminal(3))
	_, _ = layout.split(&l, l.focus, .Vertical, 0.5, terminal(4))
	bars := make([dynamic]layout.Divider)
	defer delete(bars)
	layout.dividers(&l, {0, 0, 400, 400}, 4, &bars)
	out: [4]layout.Divider
	testing.expect_value(t, layout.divider_hit_all(bars[:], 200, 200, 3, out[:]), 3)
	testing.expect_value(t, layout.divider_hit_all(bars[:], 200, 50, 3, out[:]), 1)
	testing.expect_value(t, layout.divider_hit_all(bars[:], 50, 50, 3, out[:]), 0)
	testing.expect_value(t, layout.divider_hit_all(bars[:], 200, 200, 3, out[:1]), 1)
}

@(test)
junction_hot_zone_keeps_aligned_halves_together :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		for gap in ([?]f32{0, 5, 24}) {
			g := gap*scale
			bars := [?]layout.Divider{
				{node = 0, axis = .Horizontal, rect = {100*scale, 0, g, 300*scale}},
				{node = 1, axis = .Vertical, rect = {0, 140*scale, 100*scale, g}},
				{node = 2, axis = .Vertical, rect = {100*scale+g, 140*scale, 100*scale, g}},
			}
			hits: [4]layout.Divider
			for dx in ([?]f32{-9, 0, 9}) {
				for dy in ([?]f32{-9, 0, 9}) {
					n := layout.divider_hit_all(bars[:], 100*scale+g/2+dx*scale,
						140*scale+g/2+dy*scale, 3*scale, hits[:], 10*scale, 2*scale)
					testing.expect_value(t, n, 3)
				}
			}
			bars[2].rect.y += scale
			testing.expect_value(t, layout.divider_hit_all(bars[:], 100*scale+g/2-8*scale,
				140*scale+g/2, 3*scale, hits[:], 10*scale, 2*scale), 3)
			bars[2].rect.y += 20*scale
			testing.expect_value(t, layout.divider_hit_all(bars[:], 100*scale+g/2,
				140*scale+g/2, 3*scale, hits[:], 10*scale, 2*scale), 2)
		}
	}
}
