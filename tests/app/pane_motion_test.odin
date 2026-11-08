package app_test

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
	app.window_motion_update(s, w, motion_frame(time.tick_add(first.display, app.PANE_MOTION_DURATION)))
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
	app.window_motion_update(s, w, motion_frame(time.tick_add(closing.display, app.PANE_MOTION_DURATION)))
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
	app.window_motion_update(s, w, motion_frame(time.tick_add(split.display, app.PANE_MOTION_DURATION)))
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
	app.window_motion_update(s, w, motion_frame(time.tick_add(split.display, app.PANE_MOTION_DURATION)))
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
