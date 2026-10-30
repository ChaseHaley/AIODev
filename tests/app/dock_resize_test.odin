package app_test

import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
activity_dock_junctions_resize_in_both_orientations_and_sides :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "activity-dock") {return}
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
				if side == .Left {
					testing.expect(t, panel.x + panel.width <= content.x)
					if orientation == .Vertical {
						testing.expect(t, panel.x + panel.width <= app.rail_area(w).x)
					}
				} else {testing.expect(t, panel.x >= content.x + content.width)}
				for d in w.dividers {
					if d.axis != .Vertical {continue}
					x := side == .Left ? panel.x + panel.width : panel.x
					y := d.rect.y + d.rect.height / 2
					before := w.tree.nodes[d.node].(layout.Split).ratio
					// In vertical mode the left dock meets the tab rail, not the pane divider.
					junction := side == .Right || orientation == .Horizontal
					pointer_expect_move(t, s, w, x, y, junction ? .Resize_All : .Resize_Horizontal)
					gesture_button(s, w, .Left, true, x, y)
					testing.expect_value(t, w.dragging.count, junction ? 2 : 1)
					dx := side == .Left ? 40 * scale : -40 * scale
					rail_resize_drag_to(s, w, x + dx, y + 30 * scale)
					after := app.status_panel_rect(s, w)
					testing.expect_value(t, after.width - panel.width, 40 * scale)
					if junction {testing.expect(t, w.tree.nodes[d.node].(layout.Split).ratio > before)}
					gesture_button(s, w, .Left, false, x + dx, y + 30 * scale)
					testing.expect_value(t, w.dragging.count, 0)
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
	if !palette_fixture_create(t, &f, "activity-side") {return}
	s, w := &f.state, f.state.windows[0]
	saved, _ := app.settings_save_value(s, "status.panel", "true", "enable panel")
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
