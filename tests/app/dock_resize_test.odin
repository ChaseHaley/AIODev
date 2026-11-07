package app_test

import app "../../src"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
activity_dock_junctions_resize_in_both_orientations_and_sides :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-dock", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.panel = true
	app.pane_split(s, w, .Down)
	for orientation in ([?]settings.Tabs_Orientation{.Horizontal, .Vertical}) {
		s.settings.tabs.orientation = orientation
		app.window_apply_settings(s, w)
		for side in ([?]settings.Status_Panel_Side{.Left, .Right}) {
			s.settings.status.panel_side = side
			for scale in ([?]f32{1, 1.5}) {
				w.scale, w.width, w.height = scale, i32(1400 * scale), i32(900 * scale)
				w.status.panel_width, w.rail_width = 300, 208
				app.rail_adaptive_update(w)
				app.window_relayout(s, w)
				panel := app.status_panel_rect(s, w)
				content := app.window_content_area(s, w)
				if side == .Left && orientation == .Vertical {
					// The left panel shares the docked rail with the tab list instead of docking.
					rail := app.rail_area(w)
					testing.expect_value(t, panel.x, rail.x)
					testing.expect_value(t, panel.width, rail.width)
					testing.expect_value(t, panel.y + panel.height, rail.y + rail.height)
					testing.expect_value(t, w.dock_left_width, 0)
					testing.expect(t, w.status_rail_reserve > 0)
					for d in w.dividers {testing.expect(t, d.node != app.ACTIVITY_DIVIDER)}
					continue
				}
				if side == .Left {
					testing.expect(t, panel.x + panel.width <= content.x)
				} else {testing.expect(t, panel.x >= content.x + content.width)}
				for d in w.dividers {
					if d.axis != .Vertical {continue}
					x := side == .Left ? panel.x + panel.width : panel.x
					y := d.rect.y + d.rect.height / 2
					before := w.tree.nodes[d.node].(layout.Split).ratio
					pointer_expect_move(t, s, w, x, y, .Resize_All)
					gesture_button(s, w, .Left, true, x, y)
					testing.expect_value(t, divider_count(w), 2)
					dx := side == .Left ? 40 * scale : -40 * scale
					rail_resize_drag_to(s, w, x + dx, y + 30 * scale)
					after := app.status_panel_rect(s, w)
					testing.expect_value(t, after.width - panel.width, 40 * scale)
					testing.expect(t, w.tree.nodes[d.node].(layout.Split).ratio > before)
					gesture_button(s, w, .Left, false, x + dx, y + 30 * scale)
					testing.expect_value(t, divider_count(w), 0)
					break
				}
			}
		}
	}
}

@(test)
activity_side_button_persists_setting_and_cancels_outside_or_on_capture_loss :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-side", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	saved := app.settings_save_value(s, "status.panel", "true", "enable panel")
	if !testing.expect(t, saved) {return}
	for side in ([?]settings.Status_Panel_Side{.Left, .Right}) {
		r := app.status_panel_side_rect(s, w)
		x, y := r.x + r.width / 2, r.y + r.height / 2
		gesture_button(s, w, .Left, true, x, y)
		gesture_button(s, w, .Left, false, 0, 0)
		testing.expect(t, s.settings.status.panel_side != side)
		gesture_button(s, w, .Left, true, x, y)
		app.handle_event(s, platform.Capture_Lost_Event{w.id})
		gesture_button(s, w, .Left, false, x, y)
		testing.expect(t, s.settings.status.panel_side != side)
		gesture_button(s, w, .Left, true, x, y)
		gesture_button(s, w, .Left, false, x, y)
		testing.expect_value(t, s.settings.status.panel_side, side)
		text, err := os.read_entire_file(f.path, context.temp_allocator)
		testing.expect_value(t, err, nil)
		expected := side == .Left ? "status.panel_side = left" : "status.panel_side = right"
		testing.expect(t, strings.contains(string(text), expected))
		for window in s.windows {
			testing.expect_value(t, window.dock_left_width > 0, side == .Left)
		}
	}
}

@(private)
dock_click_at :: proc(s: ^app.App, w: ^app.Window, x, y: f32, time_ns: i64) {
	for pressed in ([?]bool{true, false}) {
		app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left,
			pressed = pressed, x = i32(x), y = i32(y), time_ns = time_ns})
	}
}

@(test)
activity_in_rail_height_drags_clamps_and_double_click_resets_to_setting :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-height", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.panel = true
	s.settings.status.panel_side = .Left
	s.settings.tabs.orientation = .Vertical
	app.window_apply_settings(s, w)
	for scale in ([?]f32{1, 1.5}) {
		w.scale, w.width, w.height = scale, i32(1400 * scale), i32(900 * scale)
		w.status.panel_height = 0
		app.rail_adaptive_update(w)
		app.window_relayout(s, w)
		rail := app.rail_area(w)
		panel := app.status_panel_rect(s, w)
		testing.expect_value(t, panel.height, math.round(rail.height * 0.45))
		x, y := rail.x + rail.width / 2, panel.y
		pointer_expect_move(t, s, w, x, y, .Resize_Vertical)
		gesture_button(s, w, .Left, true, x, y)
		testing.expect_value(t, divider_count(w), 1)
		rail_resize_drag_to(s, w, x, y - 60 * scale)
		testing.expect_value(t, app.status_panel_rect(s, w).height, panel.height + 60 * scale)
		testing.expect_value(t, w.status_rail_reserve, panel.height + 60 * scale)
		rail_resize_drag_to(s, w, x, rail.y)
		testing.expect_value(t, app.status_panel_rect(s, w).y, rail.y + 96 * scale)
		rail_resize_drag_to(s, w, x, rail.y + rail.height)
		testing.expect_value(t, app.status_panel_rect(s, w).height, 80 * scale)
		gesture_button(s, w, .Left, false, x, rail.y + rail.height)
		testing.expect_value(t, divider_count(w), 0)

		s.settings.status.panel_height = 30
		top := app.status_panel_rect(s, w).y
		dock_click_at(s, w, x, top, 2_000_000_000)
		dock_click_at(s, w, x, top, 2_200_000_000)
		testing.expect_value(t, w.status.panel_height, 0)
		testing.expect_value(t, app.status_panel_rect(s, w).height, math.round(rail.height * 0.3))
		s.settings.status.panel_height = 45
	}
}

@(test)
dock_double_clicks_reset_widths_to_their_settings :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "dock-defaults", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.panel = true
	s.settings.status.panel_side = .Right
	s.settings.tabs.orientation = .Vertical
	s.settings.tabs.rail_width = 260
	s.settings.status.panel_width = 360
	w.scale, w.width, w.height = 1, 1400, 900
	app.window_apply_settings(s, w)
	app.rail_adaptive_update(w)
	app.window_relayout(s, w)
	testing.expect_value(t, app.rail_width_pixels(w), 260)
	testing.expect_value(t, app.status_panel_dock_width(s, w), 360)
	w.rail_width, w.status.panel_width = 180, 200
	app.window_relayout(s, w)
	y := f32(400)
	dock_click_at(s, w, app.rail_width_pixels(w), y, 2_000_000_000)
	dock_click_at(s, w, app.rail_width_pixels(w), y, 2_200_000_000)
	testing.expect_value(t, app.rail_width_pixels(w), 260)
	edge := f32(w.width) - app.status_panel_dock_width(s, w)
	dock_click_at(s, w, edge, y, 3_000_000_000)
	dock_click_at(s, w, edge, y, 3_200_000_000)
	testing.expect_value(t, app.status_panel_dock_width(s, w), 360)
}
