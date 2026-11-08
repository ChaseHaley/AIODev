package app_test

import "core:fmt"
import "core:math"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:settings"
import "aio:term_view"
import "aio:ui"

@(private="file")
box_metrics :: proc(scale: f32) -> term_view.Metrics {
	return {cell_width = 10 * scale, cell_height = 20 * scale}
}

@(private="file")
box_window :: proc(workspace: ^app.Workspace, scale: f32) -> app.Window {
	w := app.Window {
		workspace = workspace,
		scale = scale,
		metrics = box_metrics(scale),
		width = i32(1000 * scale),
		height = i32(650 * scale),
	}
	app.rail_adaptive_update(&w)
	return w
}

// The grid one single-pane tab receives at this window size, through the same
// content area and layout callers use.
@(private="file")
box_applied :: proc(
	t: ^testing.T,
	state: ^app.App,
	w: ^app.Window,
	kind: layout.Content_Kind,
) -> app.Pane_Box {
	tree: layout.Layout
	if !testing.expect_value(t, layout.init(&tree, {kind, 1}), nil) {return {}}
	defer layout.destroy(&tree)
	rects := make([dynamic]layout.Pane_Rect)
	defer delete(rects)
	layout.compute(&tree, app.window_content_area(state, w),
		app.window_gap(state, w), &rects, false)
	if !testing.expect_value(t, len(rects), 1) {return {}}
	return app.pane_box(w.metrics, rects[0].rect,
		app.pane_insets(state, w.scale, nil))
}

@(test)
pane_box_inverse_produces_the_requested_grid_through_the_window_content_area :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 2, 1.1}) {
		for gap in ([?]int{0, 5, 24}) {
			for padding in ([?]int{0, 8}) {
				for headers in ([?]bool{false, true}) {
					state := app.App{}
					state.settings.pane.gap = gap
					state.settings.window.padding = padding
					state.settings.pane.show_headers = headers
					workspace: app.Workspace
					w := box_window(&workspace, scale)
					insets := app.pane_insets(&state, scale, nil)
					testing.expect_value(t, insets.header,
						headers ? math.round(ui.HEADER_HEIGHT * scale) : 0)
					for grid in ([?][2]u16{{80, 24}, {40, 10}, {1, 1}}) {
						box, width, height, solved := app.pane_box_for_grid(
							&state, w, grid.x, grid.y, insets, activity_dock = true,
						)
						testing.expect(t, solved)
						testing.expect_value(t, box.columns, grid.x)
						testing.expect_value(t, box.rows, grid.y)
						w.width, w.height = width, height
						app.rail_adaptive_update(&w)
						applied := box_applied(t, &state, &w, .Terminal)
						testing.expect_value(t, applied.rect, box.rect)
						testing.expect_value(t, applied.columns, grid.x)
						testing.expect_value(t, applied.rows, grid.y)
						testing.expect_value(t, applied.origin, box.origin)
					}
				}
			}
		}
	}
}

@(test)
pane_box_inverse_respects_resized_rail_width :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.1, 1.5, 2}) {
		for width in ([?]f32{144, 288, 480}) {
			state: app.App
			state.settings.tabs.orientation = .Vertical
			workspace: app.Workspace
			w := box_window(&workspace, scale)
			w.rail_width = width
			insets := app.pane_insets(&state, scale, nil)
			box, client_width, client_height, solved := app.pane_box_for_grid(
				&state, w, 120, 24, insets, activity_dock = true,
			)
			testing.expect(t, solved)
			w.width, w.height = client_width, client_height
			app.rail_adaptive_update(&w)
			applied := box_applied(t, &state, &w, .Terminal)
			testing.expect_value(t, applied.rect, box.rect)
			testing.expect_value(t, applied.columns, u16(120))
			testing.expect_value(t, applied.rows, u16(24))
		}
	}
}

// window.columns and window.rows size a new window as if the Activity panel took no width beside the
// pane, on either side; the docked panel then takes its width from the pane.
@(test)
new_window_size_leaves_out_the_docked_activity_panel :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "window-size-activity") {return}
	s := &f.state
	s.settings.window.columns, s.settings.window.rows = 120, 32
	s.settings.status.enabled = true
	s.settings.status.panel = false
	without := app.initial_geometry(s)
	s.settings.status.panel = true
	s.settings.status.panel_width = 300
	for side in ([?]settings.Status_Panel_Side{.Left, .Right}) {
		s.settings.status.panel_side = side
		docked := app.initial_geometry(s)
		testing.expect_value(t, docked.surface_width, without.surface_width)
		testing.expect_value(t, docked.surface_height, without.surface_height)
		testing.expect_value(t, docked.columns, without.columns)
		testing.expect_value(t, docked.rows, without.rows)
		testing.expect_value(t, docked.padding_left, without.padding_left)
	}
}

@(test)
pane_minimum_refusal_reports_the_grid_the_layout_applies_at_every_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 2}) {
		for settings_tab in ([?]bool{false, true}) {
			state: app.App
			ui.notices_init(&state.notices)
			defer ui.notices_destroy(&state.notices)
			state.settings.window.padding = 8
			state.settings.pane.gap = 5
			state.settings.pane.show_headers = true
			shown_kind: layout.Content_Kind = settings_tab ? .Settings : .Terminal
			shown_tab: app.Tab
			if !testing.expect_value(t, layout.init(&shown_tab.tree, {shown_kind, 1}), nil) {return}
			defer layout.destroy(&shown_tab.tree)
			workspace: app.Workspace
			defer delete(workspace.tabs)
			w := box_window(&workspace, scale)
			append(&workspace.tabs, &shown_tab)
			shown := box_applied(t, &state, &w, shown_kind)
			// A new tab or split guards a terminal pane, which is what the layout
			// applies next whichever tab is on screen.
			applied := box_applied(t, &state, &w, .Terminal)
			testing.expect_value(t, shown.header, applied.header)
			state.settings.pane.minimum_columns = int(applied.columns)
			state.settings.pane.minimum_rows = int(applied.rows)
			testing.expect(t, app.pane_minimum_single(&state, &w))
			testing.expect_value(t, len(state.notices.items), 0)
			state.settings.pane.minimum_columns = int(applied.columns) + 1
			testing.expect(t, !app.pane_minimum_single(&state, &w))
			if !testing.expect_value(t, len(state.notices.items), 1) {continue}
			expected := fmt.tprintf(
				"Can't create this pane: %d × %d content cells; minimum %d × %d. " +
				"Change Minimum Pane Width and Height in Settings.",
				applied.columns,
				applied.rows,
				state.settings.pane.minimum_columns,
				state.settings.pane.minimum_rows,
			)
			testing.expect_value(t, state.notices.items[0].text, expected)
			state.settings.pane.minimum_columns = 0
			state.settings.pane.minimum_rows = int(applied.rows) + 1
			testing.expect(t, !app.pane_minimum_single(&state, &w))
		}
	}
}
