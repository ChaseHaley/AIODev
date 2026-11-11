package app_test

import "core:math"
import "core:slice"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:layout"
import "aio:render"
import "aio:ui"

@(private = "file")
motion_frame :: proc(display: time.Tick) -> ui.Frame_Time {
	return {display = display, period = 16 * time.Millisecond}
}

// How long pane motions take with the default motion settings.
@(private = "file")
PANE_DURATION :: 160 * time.Millisecond

@(test)
split_and_close_ease_panes_while_the_layout_changes_at_once :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	whole := w.panes[0].rect

	app.pane_split(s, w, .Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	testing.expect(t, app.pane_motion_animating(w))
	kept, added := w.panes[0], w.panes[1]
	testing.expect(t, kept.rect.width < whole.width, "the layout takes its new rectangles at once")
	testing.expect_value(t, app.pane_motion_rect(w, kept), whole)
	testing.expect_value(t, app.pane_motion_rect(w, added).width, f32(0))
	first := motion_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	shown := app.pane_motion_rect(w, added)
	testing.expect(t, shown.width > 0 && shown.x > added.rect.x, "the new pane opens from the right edge")
	testing.expect_value(t, shown.x + shown.width, added.rect.x + added.rect.width)
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, PANE_DURATION)))
	testing.expect(t, !app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_rect(w, added), added.rect)

	// Closing the new pane grows the kept one back over the space it leaves.
	app.pane_close(s, w)
	if !testing.expect_value(t, len(w.panes), 1) {return}
	testing.expect(t, app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), kept.rect)
	closing := motion_frame(time.tick_now())
	app.window_motion_update(s, w, closing)
	grown := app.pane_motion_rect(w, w.panes[0])
	testing.expect(t, grown.width > kept.rect.width && grown.width < whole.width)
	app.window_motion_update(s, w, motion_frame(time.tick_add(closing.display, PANE_DURATION)))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), whole)

	// Without system animations, and for a tab that is not in view, the layout shows at once.
	s.animations = false
	app.pane_split(s, w, .Down)
	testing.expect(t, !app.pane_motion_animating(w))
	s.animations = true
	_, created := app.tab_create(s, w.workspace)
	if !testing.expect(t, created) {return}
	other := len(w.workspace.tabs) - 1
	app.tab_select(s, w, 0)
	node := w.workspace.tabs[other].tree.focus
	_, split_error := app.pane_split_at(s, w, w.workspace, other, node, .Right, 0.5, false, {}, false)
	testing.expect_value(t, split_error, app.Pane_Split_Error.None)
	testing.expect(t, !app.pane_motion_animating(w))
}

// A closed pane's session ends at once, but its last frame stays drawn while it collapses, so the space it
// leaves never flashes the window background.
@(test)
closed_pane_keeps_its_last_frame_while_it_collapses :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-close", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	split := motion_frame(time.tick_now())
	app.window_motion_update(s, w, split)
	app.window_motion_update(s, w, motion_frame(time.tick_add(split.display, PANE_DURATION)))
	w.dirty = true
	app.window_render(s, w)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	closed := w.panes[1].rect
	sessions := len(s.sessions)
	app.pane_close(s, w)
	testing.expect_value(t, len(s.sessions), sessions - 1)
	app.window_motion_update(s, w, motion_frame(time.tick_now()))
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	surface, surface_error := render.surface_create_offscreen(s.device, w.width, w.height)
	if !testing.expect_value(t, surface_error, render.Error.None) {return}
	defer render.surface_destroy(surface)
	testing.expect_value(t, render.frame_render(s.device, surface, &w.list, s.theme.window), render.Error.None)
	pixels, pixel_error := render.surface_read_pixels(s.device, surface, context.allocator)
	if !testing.expect_value(t, pixel_error, render.Error.None) {return}
	defer delete(pixels)
	at :: proc(pixels: []u8, width: i32, x, y: f32) -> [4]u8 {
		i := (int(y) * int(width) + int(x)) * 4
		return {pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]}
	}
	middle := closed.y + closed.height / 2
	// The window background shows only around the panes, as in the outer gap at the left edge.
	background := at(pixels, w.width, 1, middle)
	collapsing := at(pixels, w.width, closed.x + closed.width - 20, middle)
	testing.expect(t, collapsing != background, "the closing pane's last frame covers the space it leaves")
}

// A floating group is just another container: a split or a close inside it moves its panes as the tiling
// moves tiled panes, the closed pane keeps its last frame there, and the tiled panes beneath stay put.
@(test)
panes_move_within_a_float_as_within_the_tiling :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-float", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	tiled := w.panes[0]
	app.floating_new(s, w)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	floated := w.panes[1]
	testing.expect(t, floated.floating)

	app.pane_split(s, w, .Right)
	if !testing.expect_value(t, len(w.panes), 3) {return}
	testing.expect(t, app.pane_motion_animating(w))
	kept, added := w.panes[1], w.panes[2]
	testing.expect(t, added.floating && added.group == kept.group)
	testing.expect_value(t, app.pane_motion_rect(w, kept), floated.rect)
	r := added.rect
	testing.expect_value(t, app.pane_motion_rect(w, added), layout.Rect{r.x + r.width, r.y, 0, r.height})
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), tiled.rect)
	split := motion_frame(time.tick_now())
	app.window_motion_update(s, w, split)
	app.window_motion_update(s, w, motion_frame(time.tick_add(split.display, PANE_DURATION)))
	testing.expect(t, !app.pane_motion_animating(w))
	w.dirty = true
	app.window_render(s, w)

	app.pane_close(s, w)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	testing.expect(t, app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[1]), kept.rect)
	app.window_motion_update(s, w, motion_frame(time.tick_now()))
	grown := app.pane_motion_rect(w, w.panes[1])
	testing.expect(t, grown.width > kept.rect.width && grown.width < floated.rect.width)
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	surface, surface_error := render.surface_create_offscreen(s.device, w.width, w.height)
	if !testing.expect_value(t, surface_error, render.Error.None) {return}
	defer render.surface_destroy(surface)
	testing.expect_value(t, render.frame_render(s.device, surface, &w.list, s.theme.window), render.Error.None)
	pixels, pixel_error := render.surface_read_pixels(s.device, surface, context.allocator)
	if !testing.expect_value(t, pixel_error, render.Error.None) {return}
	defer delete(pixels)
	at :: proc(pixels: []u8, width: i32, x, y: f32) -> [4]u8 {
		i := (int(y) * int(width) + int(x)) * 4
		return {pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]}
	}
	// Without the closed pane's frame, its space would show the float's frame, as its header strip does.
	frame := at(pixels, w.width, r.x + r.width - 20, r.y - app.floating_header_height(w) / 2)
	collapsing := at(pixels, w.width, r.x + r.width - 20, r.y + r.height / 2)
	testing.expect(t, collapsing != frame, "the closing pane's last frame covers the space it leaves")
}

@(private = "file")
motion_settle :: proc(s: ^app.App, w: ^app.Window) {
	first := motion_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, PANE_DURATION)))
}

// A close takes its duration from the Close motion settings, while a split keeps the default.
@(test)
close_takes_its_duration_from_the_motion_settings :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-close-duration", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	s.settings.motion.specs[.Close] = {duration = 400}
	app.pane_split(s, w, .Right)
	motion_settle(s, w)
	testing.expect(t, !app.pane_motion_animating(w), "the split took the default duration")
	if !testing.expect_value(t, len(w.panes), 2) {return}

	app.pane_close(s, w)
	testing.expect(t, app.pane_motion_animating(w))
	first := motion_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, PANE_DURATION)))
	testing.expect(t, app.pane_motion_animating(w), "the close outlasts the default duration")
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, 400 * time.Millisecond)))
	testing.expect(t, !app.pane_motion_animating(w))
}

// Swapping, resizing from the keyboard and balancing move panes from where they were drawn.
@(test)
rearranged_resized_and_balanced_panes_ease_into_place :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-rearrange", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	motion_settle(s, w)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	left, right := w.panes[0], w.panes[1]

	app.run_action(s, w, .Swap_Left)
	testing.expect(t, app.pane_motion_animating(w))
	moved := w.panes[0]
	testing.expect_value(t, moved.content, right.content)
	testing.expect_value(t, app.pane_motion_rect(w, moved), right.rect)
	testing.expect_value(t, moved.rect, left.rect)
	motion_settle(s, w)

	app.run_action(s, w, .Resize_Right_Large)
	testing.expect(t, app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), left.rect)
	testing.expect(t, w.panes[0].rect.width != left.rect.width)
	motion_settle(s, w)
	resized := w.panes[0].rect

	app.run_action(s, w, .Balance_Panes)
	testing.expect(t, app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), resized)
	testing.expect_value(t, w.panes[0].rect, left.rect)
}

// Zoom grows the focused pane over the others and shrinks it back off them, drawn above them both ways.
@(test)
zoomed_pane_grows_over_the_others_and_shrinks_back :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-zoom", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	motion_settle(s, w)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	focused := w.panes[1]

	app.run_action(s, w, .Zoom_Pane)
	if !testing.expect_value(t, len(w.panes), 1) {return}
	zoomed := w.panes[0]
	testing.expect_value(t, zoomed.content, focused.content)
	testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_raised(w, zoomed))
	testing.expect_value(t, app.pane_motion_rect(w, zoomed), focused.rect)
	motion_settle(s, w)

	app.run_action(s, w, .Zoom_Pane)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_raised(w, w.panes[1]))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[1]), zoomed.rect)
}

// Minimizing a float shrinks its frame and panes into its capsule, drawn from their last frame; restoring
// it grows them back out of the capsule.
@(test)
minimized_float_shrinks_into_its_capsule_and_grows_back :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-capsule", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.floating_new(s, w)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	id := w.panes[1].group
	w.dirty = true
	app.window_render(s, w)
	tree := app.window_tree(w)
	frame, framed := layout.float_rect(tree, layout.float_root(tree, w.panes[1].node), app.floating_area(w))
	if !testing.expect(t, framed) {return}

	app.run_action(s, w, .Minimize_Floating)
	if !testing.expect_value(t, len(w.float_capsules), 1) {return}
	c := w.float_capsules[0].rect
	capsule := layout.Rect{c.x, c.y, c.width, c.height}
	// Moving edges land on whole pixels.
	whole := layout.Rect{math.round(c.x), math.round(c.y), math.round(c.x + c.width), math.round(c.y + c.height)}
	whole.width, whole.height = whole.width - whole.x, whole.height - whole.y
	testing.expect_value(t, len(w.panes), 1)
	testing.expect(t, app.pane_motion_animating(w))
	first := motion_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	// Early on, before it reaches the notices drawn in the corner.
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, PANE_DURATION / 8)))
	shrinking := app.pane_motion_frame(w, id, {})
	testing.expect(t, shrinking.width < frame.width && shrinking.width > capsule.width)
	testing.expect(t, shrinking.x > frame.x, "the frame heads for the capsule")
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	surface, surface_error := render.surface_create_offscreen(s.device, w.width, w.height)
	if !testing.expect_value(t, surface_error, render.Error.None) {return}
	defer render.surface_destroy(surface)
	testing.expect_value(t, render.frame_render(s.device, surface, &w.list, s.theme.window), render.Error.None)
	pixels, pixel_error := render.surface_read_pixels(s.device, surface, context.allocator)
	if !testing.expect_value(t, pixel_error, render.Error.None) {return}
	defer delete(pixels)
	at :: proc(pixels: []u8, width: i32, x, y: f32) -> [4]u8 {
		i := (int(y) * int(width) + int(x)) * 4
		return {pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]}
	}
	mid := slice.clone(pixels)
	defer delete(mid)
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, PANE_DURATION)))
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	after, after_error := render.surface_create_offscreen(s.device, w.width, w.height)
	if !testing.expect_value(t, after_error, render.Error.None) {return}
	defer render.surface_destroy(after)
	testing.expect_value(t, render.frame_render(s.device, after, &w.list, s.theme.window), render.Error.None)
	settled, settled_error := render.surface_read_pixels(s.device, after, context.allocator)
	if !testing.expect_value(t, settled_error, render.Error.None) {return}
	defer delete(settled)
	// Where the float shrinks, its copied frame covers what shows there once it has gone.
	covered, inside := 0, 0
	for y := int(shrinking.y); y < int(shrinking.y + shrinking.height); y += 2 {
		for x := int(shrinking.x); x < int(shrinking.x + shrinking.width); x += 2 {
			inside += 1
			if at(mid, w.width, f32(x), f32(y)) != at(settled, w.width, f32(x), f32(y)) {covered += 1}
		}
	}
	testing.expectf(t, covered * 10 > inside, "the float's last frame draws as it shrinks: %v of %v", covered, inside)

	app.run_action(s, w, .Minimize_Floating)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	testing.expect(t, app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_frame(w, id, {}), whole)
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[1]), whole)
}

// Fill Window grows the focused pane over the Activity panel, drawn above it, while the panel stays where
// it was beneath it; leaving it, the pane shrinks back off the panel, which is already in place.
@(test)
fill_window_grows_the_pane_over_chrome_that_stays_in_place :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-fill", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	w.dirty = true
	app.window_render(s, w)
	panel := app.status_panel_rect(s, w)
	if !testing.expect(t, panel.width > 0, "the fixture shows the Activity panel") {return}
	pane := w.panes[0]

	app.run_action(s, w, .Fill_Window_Pane)
	testing.expect_value(t, app.status_panel_rect(s, w).width, f32(0))
	testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_over_chrome(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), pane.rect)
	first := motion_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, PANE_DURATION / 2)))
	growing := app.pane_motion_rect(w, w.panes[0])
	testing.expect(t, growing.width > pane.rect.width, "the pane grows over the panel")
	testing.expect_value(t, app.pane_motion_region_begin(w, app.PANE_MOTION_PANEL, {}).shown, panel)

	// Leaving Fill Window before the pane has covered the panel shrinks it back from where it is.
	if !testing.expect(t, app.window_build_frame(s, w)) {return}
	app.run_action(s, w, .Fill_Window_Pane)
	testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_over_chrome(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), growing)
	testing.expect_value(t, app.pane_motion_region_begin(w, app.PANE_MOTION_PANEL, panel).shown, panel)
	motion_settle(s, w)
	testing.expect(t, !app.pane_motion_over_chrome(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), pane.rect)
}

// A single-pane view showing another pane slides it in from the side it lies on in the split view, while
// the one it showed slides out the other way; both keep their size.
@(test)
zoom_slides_to_the_pane_focus_moves_to :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-slide", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	app.run_action(s, w, .Zoom_Pane)
	motion_settle(s, w)
	w.dirty = true
	app.window_render(s, w)
	right := w.panes[0]

	app.run_action(s, w, .Focus_Left)
	if !testing.expect_value(t, len(w.panes), 1) {return}
	left := w.panes[0]
	testing.expect(t, left.content != right.content)
	testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_over_chrome(w))
	entering := app.pane_motion_rect(w, left)
	testing.expect(t, entering.x + entering.width <= left.rect.x, "the left pane comes in from the left")
	testing.expect_value(t, entering.width, left.rect.width)
	motion_settle(s, w)
	testing.expect_value(t, app.pane_motion_rect(w, left), left.rect)

	// Back to the right pane, which comes in from the right.
	w.dirty = true
	app.window_render(s, w)
	app.run_action(s, w, .Focus_Right)
	entering = app.pane_motion_rect(w, w.panes[0])
	testing.expect(t, entering.x >= right.rect.x + right.rect.width, "the right pane comes in from the right")
}

// Changing tabs slides along the tabs: sideways for a tab strip, up or down for a rail; the tab further
// along comes from the right or from below. Split tabs slide too, every pane together.
@(test)
changing_tabs_slides_along_the_tabs :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-tabs", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.tab_new(s, w)
	app.run_action(s, w, .Fill_Window_Pane)
	motion_settle(s, w)

	for horizontal in ([?]bool{true, false}) {
		w.tabs_horizontal = horizontal
		app.window_relayout(s, w)
		w.dirty = true
		app.window_render(s, w)
		app.tab_select(s, w, 0)
		testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_over_chrome(w))
		target := w.panes[0].rect
		earlier := app.pane_motion_rect(w, w.panes[0])
		if horizontal {
			testing.expect(t, earlier.x + earlier.width <= target.x, "an earlier tab comes from the left")
		} else {
			testing.expect(t, earlier.y + earlier.height <= target.y, "an earlier tab comes from above")
		}
		motion_settle(s, w)
		w.dirty = true
		app.window_render(s, w)
		app.tab_select(s, w, 1)
		target = w.panes[0].rect
		later := app.pane_motion_rect(w, w.panes[0])
		if horizontal {
			testing.expect(t, later.x >= target.x + target.width, "a later tab comes from the right")
		} else {
			testing.expect(t, later.y >= target.y + target.height, "a later tab comes from below")
		}
		motion_settle(s, w)
	}

	app.run_action(s, w, .Fill_Window_Pane)
	app.pane_split(s, w, .Right)
	motion_settle(s, w)
	w.tabs_horizontal = true
	app.window_relayout(s, w)
	w.dirty = true
	app.window_render(s, w)
	app.tab_select(s, w, 0)
	testing.expect(t, app.pane_motion_animating(w))
	target := w.panes[0].rect
	earlier := app.pane_motion_rect(w, w.panes[0])
	testing.expect(t, earlier.x + earlier.width <= target.x, "a split tab slides in too")
	motion_settle(s, w)
	w.dirty = true
	app.window_render(s, w)
	app.tab_select(s, w, 1)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	for pane in w.panes {
		shown := app.pane_motion_rect(w, pane)
		testing.expect(t, shown.x > pane.rect.x && shown.width == pane.rect.width, "every pane slides together")
	}
}

// Switching workspace while either shows a single pane slides up or down, as the workspace list orders
// them: one further down the list comes from below.
@(test)
switching_workspace_in_a_single_pane_view_slides_along_the_workspace_list :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-workspaces", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	original := w.workspace
	app.run_action(s, w, .Zoom_Pane)
	motion_settle(s, w)
	w.dirty = true
	app.window_render(s, w)

	app.workspace_new(s, w, false, name_it = false)
	if !testing.expect(t, w.workspace != original) {return}
	testing.expect(t, app.pane_motion_animating(w))
	target := w.panes[0].rect
	below := app.pane_motion_rect(w, w.panes[0])
	testing.expect(t, below.y >= target.y + target.height, "a workspace further down comes from below")
	motion_settle(s, w)
	w.dirty = true
	app.window_render(s, w)

	if !testing.expect(t, app.workspace_select(s, w, original)) {return}
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Zoom)
	target = w.panes[0].rect
	above := app.pane_motion_rect(w, w.panes[0])
	testing.expect(t, above.y + above.height <= target.y, "a workspace further up comes from above")
}

// Double-clicking the Activity panel's edge returns it to its default width while the panes follow it.
@(test)
dock_edge_reset_eases_the_panel_and_panes :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-motion-dock", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	w.status.panel_width = 520 * w.scale
	app.window_relayout(s, w)
	w.dirty = true
	app.window_render(s, w)
	wide, pane := app.status_panel_rect(s, w), w.panes[0]
	edge: Maybe(layout.Edge)
	for i in 0 ..< w.dock_edges.count {
		if w.dock_edges.edges[i] == .Activity_Width {edge = w.dock_edges.bars[i]}
	}
	bar, found := edge.?
	if !testing.expect(t, found, "the panel has a width edge") {return}
	x, y := bar.rect.x + bar.rect.width / 2, bar.rect.y + bar.rect.height / 2
	testing.expect(t, app.divider_press(s, w, x, y, 1_000_000))
	_ = app.divider_drag_release(s, w, x, y)
	testing.expect(t, app.divider_press(s, w, x, y, 2_000_000))
	narrow := app.status_panel_rect(s, w)
	testing.expect(t, narrow.width < wide.width, "the panel returns to its default width")
	testing.expect(t, app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_region_begin(w, app.PANE_MOTION_PANEL, narrow).shown, wide)
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), pane.rect)
}
