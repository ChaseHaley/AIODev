package caret_test

import "aio:caret"
import "aio:render"
import "core:testing"

@(private)
overlaps :: proc(a, b: render.Rect) -> bool {
	return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
}

// A cursor that jumps column 40, then 10, then 30 on successive lines, faster than the trail settles:
// the trail runs through column 10 on the way, not straight from its old end to column 30.
@(test)
trail_follows_the_path_the_cursor_took :: proc(t: ^testing.T) {
	a := render.Rect{400, 0, 10, 20}
	b := render.Rect{100, 20, 10, 20}
	c := render.Rect{300, 40, 10, 20}
	e := caret.Effects{preset = .Trail, duration = 1, strength = 1}
	m := caret.Motion{effects = e, target = a, head = a, tail = a, drawn_head = a, drawn_tail = a}
	caret.motion_retarget(&m, b)
	caret.motion_place(&m, 0.5)
	caret.motion_drawn(&m)
	caret.motion_retarget(&m, c)
	caret.motion_place(&m, 0.5)
	corners := caret.motion_corners(&m)
	testing.expect_value(t, len(corners), 1)
	if len(corners) == 1 {testing.expect_value(t, corners[0], b)}
	// Straight toward column 30 the tail would stay right of it; along the path it swings left.
	testing.expect(t, m.tail.x < c.x)

	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	_ = render.push_layer(&list, {0, 0, 500, 100})
	caret.body_draw(&list, m.tail, corners, m.head, e, {1, 1, 1, 1}, 0.5)
	testing.expect_value(t, list.error, render.Error.None)
	through_b := false
	for r in list.rects {through_b ||= overlaps(r.rect, b)}
	testing.expect(t, through_b)

	// Once the tail passes column 10 it drops that corner and closes in on the cursor.
	caret.motion_place(&m, 0.9)
	testing.expect_value(t, len(caret.motion_corners(&m)), 0)
	testing.expect(t, m.tail.x > b.x && m.tail.x < c.x)
}

// A shape fills the part of its cell it names; a bar and an underline are as thick as two strokes, and a
// smear or trail stretches those parts, not the whole cell.
@(test)
shapes_fill_the_part_of_the_cell_they_name :: proc(t: ^testing.T) {
	cell := render.Rect{10, 20, 9, 19}
	testing.expect_value(t, caret.shape_box(.Block, 1, cell), cell)
	testing.expect_value(t, caret.shape_box(.Bar, 1, cell), render.Rect{10, 20, 2, 19})
	testing.expect_value(t, caret.shape_box(.Underline, 2, cell), render.Rect{10, 35, 9, 4})

	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	_ = render.push_layer(&list, {0, 0, 100, 100})
	caret.shape_draw(&list, .Bar, 1, cell, {1, 0, 0, 1})
	testing.expect_value(t, len(list.rects), 1)
	testing.expect_value(t, list.rects[0].rect, render.Rect{10, 20, 2, 19})
	// Hollow is an outline of four strokes, whatever the shape.
	caret.shape_draw(&list, .Bar, 1, cell, {1, 0, 0, 1}, hollow = true)
	testing.expect_value(t, len(list.rects), 5)
}

// A cursor that goes to another surface turns into that surface's colour and shape on the way.
@(test)
a_travelling_cursor_turns_its_colour_and_shape :: proc(t: ^testing.T) {
	testing.expect_value(t, caret.smooth(0), f32(0))
	testing.expect_value(t, caret.smooth(1), f32(1))
	testing.expect_value(t, caret.smooth(0.5), f32(0.5))
	testing.expect_value(t, caret.smooth(-3), f32(0))
	red, blue := render.Color{1, 0, 0, 1}, render.Color{0, 0, 1, 1}
	testing.expect_value(t, caret.mix_colors(red, blue, 0), red)
	testing.expect_value(t, caret.mix_colors(red, blue, 1), blue)
	testing.expect_value(t, caret.mix_colors(red, blue, 0.5), render.Color{0.5, 0, 0.5, 1})
	block := caret.shape_box(.Block, 1, {0, 0, 9, 19})
	bar := caret.shape_box(.Bar, 1, {0, 0, 9, 19})
	testing.expect_value(t, caret.mix_rects(block, bar, 1), bar)
	testing.expect_value(t, caret.mix_rects(block, bar, 0.5), render.Rect{0, 0, 5.5, 19})
}
