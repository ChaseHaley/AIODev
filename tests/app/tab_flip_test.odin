package app_test

import "core:math"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:render"
import "aio:ui"

@(private = "file")
flip_frame :: proc(display: time.Tick) -> ui.Frame_Time {
	return {display = display, period = 16 * time.Millisecond}
}

// Going to the strip, the panes keep their places beside the rail while its rows pass into the title bar,
// then take its space; coming back, the rail is in place before the first row comes down from the title bar.
@(test)
tab_orientation_change_holds_the_rail_until_its_tabs_have_passed :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "tab-flip", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.window_resize(s, w, 1100, 560)
	for _ in 0 ..< 3 {_, _ = app.tab_create(s, w.workspace)}
	s.settings.tabs.orientation = .Vertical
	app.window_apply_settings(s, w)
	app.window_render(s, w)
	if !testing.expect(t, app.rail_docked(w)) {return}
	beside := w.panes[0].rect
	s.animations = true

	s.settings.tabs.orientation = .Horizontal
	app.window_apply_settings(s, w)
	if !testing.expect(t, app.tab_flip_active(w)) {return}
	whole := w.panes[0].rect
	testing.expect(t, whole.x < beside.x, "the panes take the rail's space in the layout at once")
	first := flip_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	halfway := time.tick_add(first.display, w.flip.duration / 2)
	app.window_motion_update(s, w, flip_frame(halfway))
	testing.expect(t, w.flip.value > 0 && w.flip.value < 1)
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), beside)
	done := time.tick_add(first.display, w.flip.duration + 160 * time.Millisecond)
	app.window_motion_update(s, w, flip_frame(done))
	testing.expect(t, !app.tab_flip_active(w) && !app.pane_motion_animating(w))
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), whole)
	app.window_render(s, w)

	s.settings.tabs.orientation = .Vertical
	app.window_apply_settings(s, w)
	if !testing.expect(t, app.tab_flip_active(w) && app.pane_motion_animating(w)) {return}
	at := time.tick_now()
	for app.pane_motion_animating(w) && w.flip.value > 0 {
		app.window_motion_update(s, w, flip_frame(at))
		at = time.tick_add(at, 16 * time.Millisecond)
	}
	testing.expect_value(t, app.pane_motion_rect(w, w.panes[0]), beside)
	testing.expect(t, w.flip.value > 0.5, "the rail arrived while New tab went in, before any row came down")
}

// With no docked rail, moving the Activity panel to the other side turns the panes and panel as one band
// around the window: every frame is the old one turned along the band, pixel for pixel.
@(test)
activity_side_change_wraps_the_band_pixel_for_pixel :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "panel-wrap", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.window_resize(s, w, 1100, 560)
	app.pane_split(s, w, .Right)
	s.settings.tabs.orientation = .Horizontal
	s.settings.status.enabled = true
	s.settings.status.panel = true
	s.settings.status.panel_side = .Left
	app.window_apply_settings(s, w)
	app.window_render(s, w)
	before, ok := flip_pixels(t, s, w)
	if !ok {return}
	defer delete(before)
	s.animations = true

	s.settings.status.panel_side = .Right
	app.window_apply_settings(s, w)
	if !testing.expect(t, app.panel_wrap_animating(w)) {return}
	first := flip_frame(time.tick_now())
	app.window_motion_update(s, w, first)
	app.window_motion_update(s, w, flip_frame(time.tick_add(first.display, w.wrap.duration / 3)))
	shift := w.wrap_shift
	offset := math.round(shift * w.wrap.value)
	testing.expect(t, offset > 0 && offset < shift, "part way round")
	during, drawn := flip_pixels(t, s, w)
	if !drawn {return}
	defer delete(during)
	period := int(w.wrap_period)
	margin := int(w.width) - period
	turn := int(shift - offset)
	title := int(app.window_title_height(w))
	mismatches := 0
	for y in title + 48 ..< title + 300 {
		for u in 0 ..< period {
			now := (y * int(w.width) + margin + u) * 4
			was := (y * int(w.width) + margin + (u + turn) %% period) * 4
			if (cast(^[4]u8)&before[was])^ != (cast(^[4]u8)&during[now])^ {mismatches += 1}
		}
	}
	testing.expect_value(t, mismatches, 0)
}

@(private = "file")
flip_pixels :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window) -> ([]u8, bool) {
	w.dirty = true
	if !testing.expect(t, app.window_build_frame(s, w)) {return nil, false}
	surface, surface_error := render.surface_create_offscreen(s.device, w.width, w.height)
	if !testing.expect_value(t, surface_error, render.Error.None) {return nil, false}
	defer render.surface_destroy(surface)
	testing.expect_value(t, render.frame_render(s.device, surface, &w.list, s.theme.window), render.Error.None)
	pixels, pixel_error := render.surface_read_pixels(s.device, surface, context.allocator)
	return pixels, testing.expect_value(t, pixel_error, render.Error.None)
}
