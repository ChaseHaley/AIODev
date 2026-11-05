package app_test

import app "../../src"
import "aio:layout"
import "aio:platform"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
dock_menu_saves_current_sizes_in_setting_units_and_cancel_preserves_file :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "dock-default-menu", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	for scale in ([?]f32{1, 1.5}) {
		for node in ([?]layout.Node_Id{app.RAIL_DIVIDER, app.ACTIVITY_DIVIDER, app.ACTIVITY_HEIGHT_DIVIDER}) {
			saved, _ := app.settings_save_value(s, "status.panel", "true", "enable Activity")
			if !testing.expect(t, saved) {return}
			side := node == app.ACTIVITY_HEIGHT_DIVIDER ? "left" : "right"
			saved, _ = app.settings_save_value(s, "status.panel_side", side, "set side")
			if !testing.expect(t, saved) {return}
			saved, _ = app.settings_save_value(s, "tabs.orientation", "vertical", "set orientation")
			if !testing.expect(t, saved) {return}
			w.scale, w.width, w.height = scale, i32(1400 * scale), i32(900 * scale)
			w.rail_width, w.status.panel_width, w.status.panel_height = 272, 354, 0.57
			app.rail_adaptive_update(w)
			app.window_relayout(s, w)
			x, y: f32
			for d in w.dividers {
				if d.node == node {x, y = d.rect.x + d.rect.width / 2, d.rect.y + d.rect.height / 2}
			}
			before, read_error := os.read_entire_file(f.path, context.temp_allocator)
			if !testing.expect_value(t, read_error, nil) {return}
			gesture_button(s, w, .Right, true, x, y)
			gesture_button(s, w, .Right, false, x, y)
			testing.expect(t, w.tab_menu.open)
			testing.expect_value(t, w.tab_menu.dock, node)
			testing.expect_value(t, w.tab_menu.count, 1)
			testing.expect_value(t, app.tab_menu_label(w, 0), "Set as Default Size")
			testing.expect_value(t, w.dragging.count, 0)
			app.handle_event(s, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
			testing.expect(t, !w.tab_menu.open)
			after, after_error := os.read_entire_file(f.path, context.temp_allocator)
			testing.expect_value(t, after_error, nil)
			testing.expect_value(t, string(after), string(before))
			gesture_button(s, w, .Right, true, x, y)
			gesture_button(s, w, .Right, false, x, y)
			key: string
			expected: int
			switch node {
			case app.RAIL_DIVIDER: key, expected = "tabs.rail_width", 272
			case app.ACTIVITY_DIVIDER: key, expected = "status.panel_width", 354
			case app.ACTIVITY_HEIGHT_DIVIDER:
				key = "status.panel_height"
				expected = int(math.round(100 * app.status_panel_rail_height(s, w) / app.rail_area(w).height))
			}
			// Exercise pointer selection as well as keyboard selection through normal event dispatch.
			if scale == 1 {
				row := app.tab_menu_row_rect(w, 0)
				gesture_button(s, w, .Left, true, row.x + 20, row.y + row.height / 2)
				gesture_button(s, w, .Left, false, row.x + 20, row.y + row.height / 2)
			} else {
				app.handle_event(s, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
			}
			testing.expect(t, !w.tab_menu.open)
			text, err := os.read_entire_file(f.path, context.temp_allocator)
			testing.expect_value(t, err, nil)
			testing.expect(t, strings.contains(string(text), fmt.tprintf("%s = %d", key, expected)))
			app.dock_divider_reset(w, node)
			app.window_relayout(s, w)
			switch node {
			case app.RAIL_DIVIDER: testing.expect_value(t, app.rail_width_pixels(w), f32(expected) * scale)
			case app.ACTIVITY_DIVIDER:
				testing.expect_value(t, app.status_panel_dock_width(s, w), f32(expected) * scale)
			case app.ACTIVITY_HEIGHT_DIVIDER:
				testing.expect_value(t, s.settings.status.panel_height, expected)
			}
		}
	}
}
