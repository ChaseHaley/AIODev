package app_test

import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:ui"

@(private, require_results)
rail_resize_fixture :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> bool {
	if !palette_fixture_create(t, f, name) {return false}
	f.state.settings.tabs.orientation = .Vertical
	app.window_apply_settings(&f.state, f.state.windows[0])
	return true
}

@(private)
rail_resize_drag_to :: proc(s: ^app.App, w: ^app.Window, x, y: f32) {
	app.handle_event(s, platform.Mouse_Move_Event{
		window = w.id, x = i32(x), y = i32(y), buttons = {.Left},
	})
}

@(test)
rail_resize_drag_updates_content_clamps_and_finishes_outside :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !rail_resize_fixture(t, &f, "rail-resize-drag") {return}
	s, w := &f.state, f.state.windows[0]
	for scale in ([?]f32{1, 1.5}) {
		w.scale, w.width, w.height = scale, i32(1200 * scale), i32(800 * scale)
		w.rail_width = 0
		app.rail_adaptive_update(w)
		app.window_relayout(s, w)
		before := app.window_content_area(s, w)
		x, y := app.rail_width_pixels(w) + scale, 100 * scale
		pointer_expect_move(t, s, w, x, y, .Resize_Horizontal)
		gesture_button(s, w, .Left, true, x, y)
		testing.expect(t, w.rail_resizing && !w.tab_drag.pressed && !w.selecting)
		rail_resize_drag_to(s, w, x + 80 * scale, y)
		testing.expect_value(t, app.rail_width_pixels(w), 288 * scale)
		after := app.window_content_area(s, w)
		testing.expect_value(t, after.x - before.x, 80 * scale)
		testing.expect_value(t, before.width - after.width, 80 * scale)
		gesture_button(s, w, .Left, false, x + 80 * scale, -20)
		testing.expect(t, !w.rail_resizing && !w.pane_drag.pressed)
		pointer_expect_move(t, s, w, x + 120 * scale, y, .Text)
		testing.expect_value(t, app.rail_width_pixels(w), 288 * scale)

		gesture_button(s, w, .Left, true, app.rail_width_pixels(w), y)
		rail_resize_drag_to(s, w, -200, y)
		testing.expect_value(t, app.rail_width_pixels(w), ui.RAIL_MIN_WIDTH * scale)
		rail_resize_drag_to(s, w, f32(w.width) + 200, y)
		testing.expect_value(t, app.rail_width_pixels(w), ui.RAIL_MAX_WIDTH * scale)
		gesture_button(s, w, .Left, false, f32(w.width) + 200, y)
		testing.expect(t, !w.rail_resizing)
	}
}

@(test)
rail_resize_cancellation_and_orientation_preserve_the_last_width :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !rail_resize_fixture(t, &f, "rail-resize-cancel") {return}
	s, w := &f.state, f.state.windows[0]
	for scenario in 0 ..< 4 {
		y := 100 * w.scale
		gesture_button(s, w, .Left, true, app.rail_width_pixels(w), y)
		rail_resize_drag_to(s, w, 260 * w.scale, y)
		width := app.rail_width_pixels(w)
		switch scenario {
		case 0: app.handle_event(s, platform.Capture_Lost_Event{w.id})
		case 1: app.handle_event(s, platform.Focus_Event{w.id, false})
		case 2: app.palette_open(s, w)
		case 3:
			s.settings.tabs.orientation = .Horizontal
			app.window_apply_settings(s, w)
		}
		testing.expect(t, !w.rail_resizing)
		rail_resize_drag_to(s, w, 400 * w.scale, y)
		gesture_button(s, w, .Left, false, 400 * w.scale, y)
		testing.expect_value(t, app.rail_width_pixels(w), width)
		app.palette_close(s, w)
		s.settings.tabs.orientation = .Vertical
		app.window_apply_settings(s, w)
	}
}

@(test)
rail_resize_overlay_keeps_content_geometry_and_stays_inside_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !rail_resize_fixture(t, &f, "rail-resize-overlay") {return}
	s, w := &f.state, f.state.windows[0]
	w.width = i32(600 * w.scale)
	app.rail_adaptive_update(w)
	app.rail_toggle(s, w)
	if !testing.expect(t, app.rail_overlay(w)) {return}
	before := app.window_content_area(s, w)
	y := 100 * w.scale
	gesture_button(s, w, .Left, true, app.rail_width_pixels(w), y)
	rail_resize_drag_to(s, w, 500 * w.scale, y)
	testing.expect_value(t, app.rail_width_pixels(w), 300 * w.scale)
	testing.expect_value(t, app.window_content_area(s, w), before)
	app.rail_toggle(s, w)
	testing.expect(t, !w.rail_resizing && !app.rail_visible(w))
	gesture_button(s, w, .Left, false, 500 * w.scale, y)
	testing.expect_value(t, w.workspace.selected, 0)
}
