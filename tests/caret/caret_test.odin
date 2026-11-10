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
