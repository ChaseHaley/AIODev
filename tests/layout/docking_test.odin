package layout_test

import "core:testing"
import "base:runtime"
import "aio:layout"

@(test)
separating_a_pane_preserves_the_remaining_tree_and_content :: proc(t: ^testing.T) {
	source: layout.Layout
	testing.expect_value(t, layout.init(&source, terminal(1)), nil)
	defer layout.destroy(&source)
	right, _ := layout.split_direction(&source, 0, .Right, 0.5, terminal(2))
	bottom, _ := layout.split_direction(&source, right, .Down, 0.5, terminal(3))
	source.focus, source.zoomed = bottom, true
	failed, separated := layout.separate_pane(&source, bottom, runtime.nil_allocator())
	testing.expect(t, !separated)
	defer layout.destroy(&failed)
	testing.expect_value(t, source.focus, bottom)
	testing.expect(t, source.zoomed)
	for invalid in ([?]layout.Node_Id{layout.INVALID_NODE, source.root}) {
		_, ok := layout.separate_pane(&source, invalid)
		testing.expect(t, !ok)
	}
	destination, ok := layout.separate_pane(&source, bottom)
	testing.expect(t, ok)
	defer layout.destroy(&destination)
	testing.expect_value(t, destination.nodes[destination.root].(layout.Pane).content, terminal(3))
	testing.expect(t, !source.zoomed)
	testing.expect_value(t, source.nodes[source.focus].(layout.Pane).content, terminal(2))
	count := 0
	for n in source.nodes {
		if pane, is_pane := n.(layout.Pane); is_pane {
			count += 1
			testing.expect(t, pane.content.id == 1 || pane.content.id == 2)
		}
	}
	testing.expect_value(t, count, 2)
}

@(test)
root_docking_gives_each_pane_a_full_half :: proc(t: ^testing.T) {
	for mirrored in ([?]bool{false, true}) {
		for source in 1..=3 {
			for direction in layout.Direction {
				for scale in ([?]f32{1, 1.5, 1.75}) {
					for gap in ([?]f32{0, 5, 24}) {
						l: layout.Layout
						testing.expect_value(t, layout.init(&l, terminal(1)), nil)
						defer layout.destroy(&l)
						right, _ := layout.split_direction(&l, 0, .Right, 0.5, terminal(2))
						_, _ = layout.split_direction(&l, mirrored ? right : 0, .Down, 0.5, terminal(3))
						node := layout.INVALID_NODE
						for n, i in l.nodes { if p, ok := n.(layout.Pane); ok && p.content.id == u32(source) { node = layout.Node_Id(i) } }
						l.focus = node
						order := l.nodes[node].(layout.Pane).order
						moved, ok := layout.dock_pane(&l, node, direction)
						testing.expect(t, ok)
						testing.expect_value(t, l.focus, moved)
						testing.expect_value(t, l.nodes[moved].(layout.Pane).order, order)
						rects := make([dynamic]layout.Pane_Rect)
						defer delete(rects)
						area := layout.Rect{5*scale, 45*scale, 1000*scale, 600*scale}
						layout.compute(&l, area, gap*scale, &rects)
						testing.expect_value(t, len(rects), 3)
						r := rect_of(rects[:], u32(source))
						if direction == .Left || direction == .Right {
							testing.expect_value(t, r.height, area.height)
							testing.expect(t, abs(r.width-(area.width-gap*scale)/2) <= 1)
							testing.expect_value(t, r.y, area.y)
							testing.expect(t, abs(r.x-(direction == .Left ? area.x : area.x+(area.width+gap*scale)/2)) <= 1)
						} else {
							testing.expect_value(t, r.width, area.width)
							testing.expect(t, abs(r.height-(area.height-gap*scale)/2) <= 1)
							testing.expect_value(t, r.x, area.x)
							testing.expect(t, abs(r.y-(direction == .Up ? area.y : area.y+(area.height+gap*scale)/2)) <= 1)
						}
					}
				}
			}
		}
	}
}

@(test)
failed_transfer_preserves_both_layouts :: proc(t: ^testing.T) {
	a, b: layout.Layout
	testing.expect_value(t, layout.init(&a, terminal(1)), nil)
	defer layout.destroy(&a)
	testing.expect_value(t, layout.init(&b, terminal(2)), nil)
	defer layout.destroy(&b)
	tight := make([dynamic]layout.Node, len(b.nodes), len(b.nodes))
	copy(tight[:], b.nodes[:])
	delete(b.nodes)
	b.nodes = tight
	allocator := b.nodes.allocator
	b.nodes.allocator = runtime.nil_allocator()
	_, moved := layout.transfer_pane(&a, &b, 0, 0, .Down, true)
	b.nodes.allocator = allocator
	testing.expect(t, !moved)
	testing.expect_value(t, a.root, layout.Node_Id(0))
	testing.expect_value(t, b.root, layout.Node_Id(0))
	testing.expect_value(t, a.nodes[0].(layout.Pane).content, terminal(1))
	testing.expect_value(t, b.nodes[0].(layout.Pane).content, terminal(2))
}

@(test)
transfer_preserves_content_and_handles_sole_source :: proc(t: ^testing.T) {
	for root in ([?]bool{false, true}) {
		for sole in ([?]bool{false, true}) {
			for direction in layout.Direction {
				a, b: layout.Layout
				testing.expect_value(t, layout.init(&a, terminal(1)), nil)
				defer layout.destroy(&a)
				testing.expect_value(t, layout.init(&b, terminal(2)), nil)
				defer layout.destroy(&b)
				if !sole { _, _ = layout.split_direction(&a, 0, .Down, 0.5, terminal(3)) }
				_, _ = layout.split_direction(&b, 0, .Right, 0.5, terminal(4))
				moved, ok := layout.transfer_pane(&a, &b, 0, 0, direction, root)
				testing.expect(t, ok)
				testing.expect_value(t, b.focus, moved)
				testing.expect_value(t, b.nodes[moved].(layout.Pane).content, terminal(1))
				testing.expect_value(t, a.root == layout.INVALID_NODE, sole)
				for n in a.nodes { if p, is_pane := n.(layout.Pane); is_pane { testing.expect_value(t, p.content, terminal(3)) } }
				for n in b.nodes { if p, is_pane := n.(layout.Pane); is_pane { testing.expect(t, p.content.id == 1 || p.content.id == 2 || p.content.id == 4) } }
			}
		}
	}
	l: layout.Layout
	testing.expect_value(t, layout.init(&l, terminal(1)), nil)
	defer layout.destroy(&l)
	_, valid := layout.dock_pane(&l, 0, .Down)
	testing.expect(t, !valid)
	settings: layout.Layout
	testing.expect_value(t, layout.init(&settings, {.Settings, 0}), nil)
	defer layout.destroy(&settings)
	_, transferred := layout.transfer_pane(&l, &settings, 0, 0, .Down, true)
	testing.expect(t, !transferred)
	testing.expect_value(t, l.root, layout.Node_Id(0))
	_, invalid := layout.transfer_pane(&l, &l, 0, 0, .Right, false)
	testing.expect(t, !invalid)
}
