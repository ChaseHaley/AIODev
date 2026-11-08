package ui_test

import "core:testing"
import "core:time"
import "aio:render"
import "aio:ui"

@(private = "file")
LAYOUT_DURATION :: 160 * time.Millisecond

// Starts a linear layout motion from `shown` to `targets` and draws its first frame.
@(private = "file")
layout_motion_first_frame :: proc(m: ^ui.Layout_Motion, shown, targets: []ui.Layout_Place) -> ui.Frame_Time {
	ui.layout_motion_begin(m, shown, targets, LAYOUT_DURATION, .Linear, true)
	first := test_frame(time.tick_now())
	ui.layout_motion_update(m, first)
	return first
}

@(test)
layout_split_opens_the_new_item_from_the_side_it_divides :: proc(t: ^testing.T) {
	old := render.Rect{0, 0, 100, 40}
	cases := [?]struct {
		kept, added, grows_from: render.Rect,
	} {
		// Split right: the new item grows out of the old item's right edge.
		{{0, 0, 48, 40}, {52, 0, 48, 40}, {100, 0, 0, 40}},
		// Split left: out of its left edge.
		{{52, 0, 48, 40}, {0, 0, 48, 40}, {0, 0, 0, 40}},
		// Split down: out of its bottom edge.
		{{0, 0, 100, 18}, {0, 22, 100, 18}, {0, 40, 100, 0}},
	}
	for c in cases {
		m: ui.Layout_Motion
		defer ui.layout_motion_destroy(&m)
		shown := []ui.Layout_Place{{1, old, 0}}
		targets := []ui.Layout_Place{{1, c.kept, 0}, {2, c.added, 0}}
		ui.layout_motion_begin(&m, shown, targets, LAYOUT_DURATION, .Linear, true)
		testing.expect(t, ui.layout_motion_active(&m))
		testing.expect_value(t, ui.layout_motion_rect(&m, 1, c.kept), old)
		testing.expect_value(t, ui.layout_motion_rect(&m, 2, c.added), c.grows_from)
		first := test_frame(time.tick_now())
		testing.expect(t, ui.layout_motion_update(&m, first))
		kept, added := ui.layout_motion_rect(&m, 1, c.kept), ui.layout_motion_rect(&m, 2, c.added)
		testing.expect(t, kept.width * kept.height < old.width * old.height, "the divided item shrinks")
		testing.expect(t, added.width * added.height > 0, "the new item opens on the first frame")
		for r in ([?]render.Rect{kept, added}) {
			testing.expect_value(t, r.x, f32(int(r.x)))
			testing.expect_value(t, r.width, f32(int(r.width)))
		}
		last := test_frame(time.tick_add(first.display, LAYOUT_DURATION - first.period))
		testing.expect(t, ui.layout_motion_update(&m, last))
		testing.expect(t, !ui.layout_motion_active(&m))
		testing.expect_value(t, ui.layout_motion_rect(&m, 1, c.kept), c.kept)
		testing.expect_value(t, ui.layout_motion_rect(&m, 2, c.added), c.added)
	}
}

@(test)
layout_close_collapses_the_closed_item_under_its_growing_neighbour :: proc(t: ^testing.T) {
	m: ui.Layout_Motion
	defer ui.layout_motion_destroy(&m)
	shown := []ui.Layout_Place{{1, {10.5, 0, 40, 30}, 0}, {2, {54.5, 0, 40, 30}, 0}}
	targets := []ui.Layout_Place{{2, {10.5, 0, 84, 30}, 0}}
	layout_motion_first_frame(&m, shown, targets)
	r := ui.layout_motion_rect(&m, 2, targets[0].rect)
	testing.expect(t, r.x > 10.5 && r.x < 54.5, "the neighbour's left edge moves into the space left")
	testing.expect_value(t, r.x + r.width, f32(94.5))
	testing.expect_value(t, r.y, f32(0))
	// The closed item collapses onto its left edge as the neighbour grows over it.
	gone := ui.layout_motion_rect(&m, 1, {})
	testing.expect_value(t, gone.x, f32(10.5))
	testing.expect(t, gone.width > 0 && gone.width < 40)
	testing.expect(t, gone.x + gone.width <= r.x, "the collapsing item never overlaps its neighbour")
}

@(test)
layout_motion_without_animations_or_change_lands_at_once :: proc(t: ^testing.T) {
	m: ui.Layout_Motion
	defer ui.layout_motion_destroy(&m)
	shown := []ui.Layout_Place{{1, {0, 0, 100, 40}, 0}}
	split := []ui.Layout_Place{{1, {0, 0, 48, 40}, 0}, {2, {52, 0, 48, 40}, 0}}
	ui.layout_motion_begin(&m, shown, split, LAYOUT_DURATION, .Decelerate, false)
	testing.expect(t, !ui.layout_motion_active(&m))
	testing.expect_value(t, ui.layout_motion_rect(&m, 2, split[1].rect), split[1].rect)
	ui.layout_motion_begin(&m, split, split, LAYOUT_DURATION, .Decelerate, true)
	testing.expect(t, !ui.layout_motion_active(&m), "nothing moved, so nothing animates")
}

@(test)
layout_retarget_carries_progress_to_new_rectangles :: proc(t: ^testing.T) {
	m: ui.Layout_Motion
	defer ui.layout_motion_destroy(&m)
	shown := []ui.Layout_Place{{1, {0, 0, 100, 40}, 0}}
	split := []ui.Layout_Place{{1, {0, 0, 48, 40}, 0}, {2, {52, 0, 48, 40}, 0}}
	first := layout_motion_first_frame(&m, shown, split)
	progress := m.progress.value
	// The window grows mid-motion; a third item arrives without a motion of its own.
	wider := []ui.Layout_Place{{1, {0, 0, 98, 40}, 0}, {2, {102, 0, 98, 40}, 0}, {3, {0, 44, 200, 40}, 0}}
	ui.layout_motion_retarget(&m, wider)
	testing.expect(t, ui.layout_motion_active(&m))
	testing.expect_value(t, m.progress.value, progress)
	testing.expect_value(t, ui.layout_motion_rect(&m, 3, wider[2].rect), wider[2].rect)
	// Item 2 still grows from the old right edge, now toward its wider place, a tenth of the way.
	testing.expect_value(t, ui.layout_motion_rect(&m, 2, wider[1].rect), render.Rect{100, 0, 10, 40})
	ui.layout_motion_update(&m, test_frame(time.tick_add(first.display, LAYOUT_DURATION)))
	testing.expect_value(t, ui.layout_motion_rect(&m, 1, wider[0].rect), wider[0].rect)
}

// A pane split inside a floating group grows from the group's divided pane, not from a larger tiled pane
// beneath the float; a pane closing there collapses beneath its float neighbour.
@(test)
layout_items_move_within_their_container :: proc(t: ^testing.T) {
	m: ui.Layout_Motion
	defer ui.layout_motion_destroy(&m)
	tiled := ui.Layout_Place{1, {0, 0, 400, 300}, 0}
	shown := []ui.Layout_Place{tiled, {2, {100, 100, 200, 100}, 7}}
	split := []ui.Layout_Place{tiled, {2, {100, 100, 98, 100}, 7}, {3, {202, 100, 98, 100}, 7}}
	ui.layout_motion_begin(&m, shown, split, LAYOUT_DURATION, .Linear, true)
	testing.expect_value(t, ui.layout_motion_rect(&m, 3, split[2].rect), render.Rect{300, 100, 0, 100})
	ui.layout_motion_begin(&m, split, shown, LAYOUT_DURATION, .Linear, true)
	successor, leaving := ui.layout_motion_successor(&m, 3)
	testing.expect(t, leaving)
	testing.expect_value(t, successor, u64(2))
	testing.expect_value(t, ui.layout_motion_rect(&m, 3, {}), split[2].rect)
}
