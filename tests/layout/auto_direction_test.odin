package layout_test

import "aio:layout"
import "core:testing"

@(private = "file")
content_of :: proc(id: u32) -> layout.Content {return {.Terminal, id}}

// A window's geometry at `scale`: a 1200 by 800 content area, as wide as the floating area, with the gap and
// float header a window scales by its DPI.
@(private = "file")
geometry_at :: proc(scale: f32) -> layout.Geometry {
	area := layout.Rect{0, 40 * scale, 1200 * scale, 800 * scale}
	return {tiled = area, floating = area, gap = 2 * scale, header = 28 * scale}
}

// Every pane pane_rect can find is where place_shown puts it.
@(private = "file")
expect_rects_match :: proc(t: ^testing.T, l: ^layout.Layout, g: layout.Geometry) {
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.place_shown(l, g, false, &rects)
	for pane in rects {
		rect, found := layout.pane_rect(l, g, pane.node)
		testing.expectf(t, found, "pane %v was not found", pane.node)
		testing.expect_value(t, rect, pane.rect)
	}
}

@(test)
auto_direction_splits_the_longer_side :: proc(t: ^testing.T) {
	testing.expect_value(t, layout.auto_direction({0, 0, 300, 800}), layout.Direction.Down)
	testing.expect_value(t, layout.auto_direction({0, 0, 800, 300}), layout.Direction.Right)
	testing.expect_value(t, layout.auto_direction({10, 20, 401, 400}), layout.Direction.Right)
	testing.expect_value(t, layout.auto_direction({10, 20, 400, 401}), layout.Direction.Down)
}

@(test)
auto_direction_takes_right_for_a_square :: proc(t: ^testing.T) {
	testing.expect_value(t, layout.auto_direction({0, 0, 400, 400}), layout.Direction.Right)
	testing.expect_value(t, layout.auto_direction({}), layout.Direction.Right)
}

// Pixels at any DPI keep a pane's proportions, so its side does not change with scale.
@(test)
auto_direction_ignores_dpi :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2, 3.5}) {
		testing.expect_value(t, layout.auto_direction({0, 0, 300 * scale, 800 * scale}), layout.Direction.Down)
		testing.expect_value(t, layout.auto_direction({0, 0, 800 * scale, 300 * scale}), layout.Direction.Right)
		testing.expect_value(t, layout.auto_direction({0, 0, 500 * scale, 500 * scale}), layout.Direction.Right)
	}
}

// Side by side panes of a wide window are tall, so each splits down; the halves of a pane split down are
// wide again and split right.
@(test)
pane_rect_gives_tall_and_wide_tiled_panes :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, content_of(1)), nil)
	left := l.root
	right, right_error := layout.split(&l, left, .Horizontal, 0.5, content_of(2))
	testing.expect_value(t, right_error, nil)
	g := geometry_at(1)
	expect_rects_match(t, &l, g)
	for node in ([?]layout.Node_Id{left, right}) {
		rect, found := layout.pane_rect(&l, g, node)
		testing.expect(t, found)
		testing.expect_value(t, layout.auto_direction(rect), layout.Direction.Down)
	}
	below, below_error := layout.split(&l, right, .Vertical, 0.5, content_of(3))
	testing.expect_value(t, below_error, nil)
	expect_rects_match(t, &l, g)
	for node in ([?]layout.Node_Id{right, below}) {
		rect, _ := layout.pane_rect(&l, g, node)
		testing.expect_value(t, layout.auto_direction(rect), layout.Direction.Right)
	}
	left_rect, _ := layout.pane_rect(&l, g, left)
	testing.expect_value(t, layout.auto_direction(left_rect), layout.Direction.Down)
}

// A pane in a float splits inside it, so the float's own pane decides, not the tiling beneath.
@(test)
pane_rect_uses_the_float_pane :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, content_of(1)), nil)
	tiled := l.root
	tall, tall_error := layout.float_new(&l, content_of(2), {0.1, 0.05, 0.2, 0.9})
	testing.expect_value(t, tall_error, nil)
	wide, wide_error := layout.float_new(&l, content_of(3), {0.3, 0.1, 0.6, 0.3})
	testing.expect_value(t, wide_error, nil)
	g := geometry_at(1)
	expect_rects_match(t, &l, g)
	tall_rect, tall_found := layout.pane_rect(&l, g, tall)
	testing.expect(t, tall_found)
	testing.expect_value(t, layout.auto_direction(tall_rect), layout.Direction.Down)
	wide_rect, _ := layout.pane_rect(&l, g, wide)
	testing.expect_value(t, layout.auto_direction(wide_rect), layout.Direction.Right)
	tiled_rect, _ := layout.pane_rect(&l, g, tiled)
	testing.expect_value(t, tiled_rect, g.tiled)
	// A split inside the tall float leaves two panes that are still taller than wide.
	inner, inner_error := layout.split_direction(&l, tall, .Down, 0.5, content_of(4))
	testing.expect_value(t, inner_error, nil)
	expect_rects_match(t, &l, g)
	inner_rect, inner_found := layout.pane_rect(&l, g, inner)
	testing.expect(t, inner_found)
	testing.expect_value(t, layout.auto_direction(inner_rect), layout.Direction.Down)
}

// The same tree at another DPI gives every pane the same side.
@(test)
pane_rect_side_holds_across_dpi :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, content_of(1)), nil)
	right, _ := layout.split(&l, l.root, .Horizontal, 0.5, content_of(2))
	_, _ = layout.split(&l, right, .Vertical, 0.5, content_of(3))
	_, _ = layout.float_new(&l, content_of(4), {0.1, 0.1, 0.25, 0.7})
	base := geometry_at(1)
	for scale in ([?]f32{1.25, 1.5, 2}) {
		scaled := geometry_at(scale)
		expect_rects_match(t, &l, scaled)
		for _, i in l.nodes {
			node := layout.Node_Id(i)
			at_base, found := layout.pane_rect(&l, base, node)
			if !found {continue}
			at_scale, _ := layout.pane_rect(&l, scaled, node)
			testing.expect_value(t, layout.auto_direction(at_scale), layout.auto_direction(at_base))
		}
	}
}

@(test)
pane_rect_refuses_what_is_not_a_shown_pane :: proc(t: ^testing.T) {
	l: layout.Layout
	defer layout.destroy(&l)
	testing.expect_value(t, layout.init(&l, content_of(1)), nil)
	first := l.root
	second, _ := layout.split(&l, first, .Horizontal, 0.5, content_of(2))
	g := geometry_at(1)
	_, split_found := layout.pane_rect(&l, g, l.root)
	testing.expect(t, !split_found, "a split is no pane")
	_, invalid_found := layout.pane_rect(&l, g, layout.INVALID_NODE)
	testing.expect(t, !invalid_found)
	_, beyond_found := layout.pane_rect(&l, g, layout.Node_Id(len(l.nodes)))
	testing.expect(t, !beyond_found)
	testing.expect(t, layout.set_linked(&l, second, true))
	_, linked_found := layout.pane_rect(&l, g, second)
	testing.expect(t, !linked_found, "a linked pane shows in its own window")
	first_rect, first_found := layout.pane_rect(&l, g, first)
	testing.expect(t, first_found)
	testing.expect_value(t, first_rect, g.tiled)
}
