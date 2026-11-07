package app_test

import app "../../src"
import "aio:input"
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
		for edge in ([?]app.Dock_Edge{.Rail_Width, .Activity_Width, .Activity_Height}) {
			saved := app.settings_save_value(s, "status.panel", "true", "enable Activity")
			if !testing.expect(t, saved) {return}
			side := edge == .Activity_Height ? "left" : "right"
			saved = app.settings_save_value(s, "status.panel_side", side, "set side")
			if !testing.expect(t, saved) {return}
			saved = app.settings_save_value(s, "tabs.orientation", "vertical", "set orientation")
			if !testing.expect(t, saved) {return}
			w.scale, w.width, w.height = scale, i32(1400 * scale), i32(900 * scale)
			w.rail_width, w.status.panel_width, w.status.panel_height = 272, 354, 0.57
			app.rail_adaptive_update(w)
			app.window_relayout(s, w)
			x, y: f32
			for shown, i in w.dock_edges.edges[:w.dock_edges.count] {
				r := w.dock_edges.bars[i].rect
				if shown == edge {x, y = r.x + r.width / 2, r.y + r.height / 2}
			}
			before, read_error := os.read_entire_file(f.path, context.temp_allocator)
			if !testing.expect_value(t, read_error, nil) {return}
			gesture_button(s, w, .Right, true, x, y)
			gesture_button(s, w, .Right, false, x, y)
			divider, shown := w.overlay.(app.Overlay_Divider_Menu)
			testing.expect(t, shown)
			testing.expect_value(t, divider.edge, edge)
			testing.expect_value(t, len(w.divider_menu.items), 1)
			testing.expect_value(t, w.divider_menu.items[0].label, "Set as Default Size")
			testing.expect_value(t, divider_count(w), 0)
			app.handle_event(s, input.Key_Event{window = w.id, key = .Escape, pressed = true})
			testing.expect(t, w.overlay == nil)
			after, after_error := os.read_entire_file(f.path, context.temp_allocator)
			testing.expect_value(t, after_error, nil)
			testing.expect_value(t, string(after), string(before))
			gesture_button(s, w, .Right, true, x, y)
			gesture_button(s, w, .Right, false, x, y)
			key: string
			expected: int
			switch edge {
			case .Rail_Width: key, expected = "tabs.rail_width", 272
			case .Activity_Width: key, expected = "status.panel_width", 354
			case .Activity_Height:
				key = "status.panel_height"
				expected = int(math.round(100 * app.status_panel_rail_height(s, w) / app.rail_area(w).height))
			}
			// Exercise pointer selection as well as keyboard selection through normal event dispatch.
			if scale == 1 {
				row := window_menu_row(w, &w.divider_menu, 0)
				gesture_button(s, w, .Left, true, row.x + 20, row.y + row.height / 2)
				gesture_button(s, w, .Left, false, row.x + 20, row.y + row.height / 2)
			} else {
				app.handle_event(s, input.Key_Event{window = w.id, key = .Enter, pressed = true})
			}
			testing.expect(t, w.overlay == nil)
			text, err := os.read_entire_file(f.path, context.temp_allocator)
			testing.expect_value(t, err, nil)
			testing.expect(t, strings.contains(string(text), fmt.tprintf("%s = %d", key, expected)))
			app.dock_edge_reset(w, edge)
			app.window_relayout(s, w)
			switch edge {
			case .Rail_Width: testing.expect_value(t, app.rail_width_pixels(w), f32(expected) * scale)
			case .Activity_Width:
				testing.expect_value(t, app.status_panel_dock_width(s, w), f32(expected) * scale)
			case .Activity_Height:
				testing.expect_value(t, s.settings.status.panel_height, expected)
			}
		}
	}
}
