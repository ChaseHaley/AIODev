package app_test

import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:ui"

@(private="file")
rail_tab :: proc(workspace: ^app.Workspace, id: u32) -> ^app.Tab {
	tab := new(app.Tab)
	tab.id = id
	if layout.init(&tab.tree, {.Terminal, id}) != nil {
		free(tab)
		return nil
	}
	append(&workspace.tabs, tab)
	return tab
}

@(private="file")
rail_workspace :: proc(state: ^app.App, id: u32, name: string) -> ^app.Workspace {
	workspace := new(app.Workspace)
	workspace^ = {id = id, name = name}
	append(&state.workspaces, workspace)
	return workspace
}

@(private="file")
rail_workspace_destroy :: proc(state: ^app.App) {
	for workspace in state.workspaces {
		for tab in workspace.tabs {
			layout.destroy(&tab.tree)
			free(tab)
		}
		delete(workspace.tabs)
		free(workspace)
	}
	delete(state.workspaces)
}

@(test)
rail_rows_show_only_the_current_workspace_and_follow_switches :: proc(t: ^testing.T) {
	state: app.App
	defer rail_workspace_destroy(&state)
	one := rail_workspace(&state, 1, "Build")
	rail_tab(one, 1)
	rail_tab(one, 2)
	two := rail_workspace(&state, 2, "Tests")
	rail_tab(two, 3)
	w := app.Window{workspace = one}
	rows := make([dynamic]app.Rail_Row)
	defer delete(rows)
	testing.expect(t, app.rail_rows_build(&state, &w, &rows))
	if !testing.expect_value(t, len(rows), 2) {return}
	for row, i in rows {
		testing.expect_value(t, row.workspace, one)
		testing.expect_value(t, row.tab, i)
	}
	testing.expect_value(t, app.rail_row_index_for_tab(rows[:], two, 0), -1)
	w.workspace = two
	testing.expect(t, app.rail_rows_build(&state, &w, &rows))
	if !testing.expect_value(t, len(rows), 1) {return}
	testing.expect_value(t, rows[0].workspace, two)
	testing.expect_value(t, rows[0].tab, 0)
}

@(test)
rail_adaptive_threshold_toggle_and_crossing_restore_automatic_behaviour :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 1200, height = 700, scale = 1, preparing = true}
	app.rail_adaptive_update(&w)
	testing.expect(t, w.rail_auto)
	testing.expect(t, app.rail_docked(&w))
	testing.expect(t, !app.rail_overlay(&w))

	// A user hiding a docked rail keeps that choice across resizes on the same side.
	app.rail_toggle(&state, &w)
	testing.expect(t, !app.rail_visible(&w))
	w.width = 1100
	app.rail_adaptive_update(&w)
	testing.expect(t, !app.rail_visible(&w))
	testing.expect_value(t, w.rail_override, app.Rail_Override.Hidden)
	app.rail_toggle(&state, &w)
	testing.expect(t, app.rail_docked(&w))

	// Below the threshold the automatic behaviour hides the rail and the toggle overlays it.
	w.width = 600
	app.rail_adaptive_update(&w)
	testing.expect(t, !w.rail_auto)
	testing.expect(t, !app.rail_visible(&w))
	testing.expect_value(t, w.rail_override, app.Rail_Override.Auto)
	testing.expect_value(t, w.rail_slide.value, f32(0))
	testing.expect(t, !w.rail_was_overlay)
	app.rail_toggle(&state, &w)
	testing.expect(t, app.rail_overlay(&w))
	testing.expect(t, !app.rail_docked(&w))
	testing.expect(t, w.rail_was_overlay)
	w.width = 660
	app.rail_adaptive_update(&w)
	testing.expect(t, app.rail_overlay(&w))
	testing.expect_value(t, w.rail_override, app.Rail_Override.Shown)

	// Crossing the threshold drops the override, so widening docks the rail again.
	w.width = 1300
	app.rail_adaptive_update(&w)
	testing.expect_value(t, w.rail_override, app.Rail_Override.Auto)
	testing.expect(t, app.rail_docked(&w))
}

@(test)
rail_overlay_closes_on_escape_and_after_a_selection :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.windows)
	defer rail_workspace_destroy(&state)
	workspace := rail_workspace(&state, 1, "Build")
	tab := rail_tab(workspace, 1)
	if !testing.expect(t, tab != nil) {return}
	w := app.Window {
		id            = 44,
		workspace     = workspace,
		tree          = &tab.tree,
		width         = 600,
		height        = 700,
		scale         = 1,
		rail_auto     = false,
		rail_override = .Shown,
	}
	append(&state.windows, &w)
	testing.expect(t, app.rail_overlay(&w))
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !app.rail_overlay(&w))
	testing.expect(t, !app.rail_visible(&w))

	w.rail_override = .Shown
	testing.expect(t, app.rail_overlay(&w))
	row := app.rail_row_rect_for_tab(&state, &w, 0)
	app.handle_event(
		&state,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = true,
			x = i32(row.x + 20),
			y = i32(row.y + 16),
		},
	)
	// Selecting the tab already dismissed the overlay through the tab-selection path.
	testing.expect(t, !app.rail_overlay(&w))
	app.handle_event(
		&state,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			x = i32(row.x + 20),
			y = i32(row.y + 16),
		},
	)
	testing.expect(t, !app.rail_overlay(&w))
	testing.expect(t, !app.rail_visible(&w))
	testing.expect_value(t, workspace.selected, 0)
}

@(test)
rail_keyboard_tab_selection_closes_an_open_overlay :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.windows)
	defer rail_workspace_destroy(&state)
	workspace := rail_workspace(&state, 1, "Build")
	one := rail_tab(workspace, 1)
	two := rail_tab(workspace, 2)
	if !testing.expect(t, one != nil && two != nil) {return}
	one.marked = true
	w := app.Window {
		id             = 47,
		workspace      = workspace,
		tree           = &one.tree,
		width          = 600,
		height         = 700,
		scale          = 1,
		rail_auto      = false,
		rail_override  = .Shown,
		preparing      = true,
	}
	append(&state.windows, &w)
	testing.expect(t, app.rail_overlay(&w))
	app.run_action(&state, &w, .Tab_2)
	testing.expect_value(t, workspace.selected, 1)
	testing.expect(t, !app.rail_overlay(&w))
	testing.expect(t, !app.rail_visible(&w))
}

@(test)
rail_preview_windows_do_not_reserve_rail_width :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 1000, height = 700, scale = 1, rail_auto = true, preparing = true}
	preview := app.window_content_area(&state, &w)
	testing.expect_value(t, preview.x, f32(0))
	testing.expect_value(t, preview.width, f32(1000))
	w.preparing = false
	docked := app.window_content_area(&state, &w)
	testing.expect_value(t, docked.x, ui.rail_pixel_width(1))
	testing.expect_value(t, docked.width, 1000 - ui.rail_pixel_width(1))
}

@(test)
rail_close_and_multiselect_keep_the_selected_group_and_remaining_tab :: proc(t: ^testing.T) {
	state: app.App
	workspace := rail_workspace(&state, 1, "Build")
	defer {
		for tab in workspace.tabs {
			layout.destroy(&tab.tree)
			free(tab)
		}
		delete(workspace.tabs)
		free(workspace)
		delete(state.windows)
		delete(state.workspaces)
	}
	one := rail_tab(workspace, 1)
	two := rail_tab(workspace, 2)
	three := rail_tab(workspace, 3)
	if !testing.expect(t, one != nil && two != nil && three != nil) {return}
	one.marked, workspace.selection_anchor = true, one.id
	w := app.Window {
		id        = 45,
		workspace = workspace,
		tree      = &one.tree,
		width     = 1000,
		height    = 700,
		scale     = 1,
		rail_auto = true,
	}
	append(&state.windows, &w)
	row1 := app.rail_row_rect_for_tab(&state, &w, 1)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(row1.x + 20), y = i32(row1.y + 16), modifiers = {.Control}})
	testing.expect(t, one.marked && two.marked && !three.marked)
	testing.expect_value(t, workspace.selected, 1)

	layout_state, ok := app.rail_current_layout(&state, &w)
	if !testing.expect(t, ok) {return}
	row_index := app.rail_row_index_for_tab(w.rail_rows[:], workspace, 1)
	close := ui.rail_close_rect(layout_state, row_index, w.scale)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(close.x + close.width / 2), y = i32(close.y + close.height / 2)})
	testing.expect(t, ui.armed_down(w.tab_close_armed))
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left,
		x = i32(close.x + close.width / 2), y = i32(close.y + close.height / 2)})
	testing.expect(t, !ui.armed_down(w.tab_close_armed))
	if !testing.expect_value(t, len(workspace.tabs), 1) {return}
	testing.expect(t, workspace.tabs[0] == three)
	testing.expect_value(t, workspace.selected, 0)
	testing.expect_value(t, w.tree, &three.tree)
}

@(test)
rail_footer_and_empty_space_are_new_tab_drop_targets :: proc(t: ^testing.T) {
	state: app.App
	workspace := rail_workspace(&state, 1, "Build")
	defer {
		for tab in workspace.tabs {
			layout.destroy(&tab.tree)
			free(tab)
		}
		delete(workspace.tabs)
		free(workspace)
		delete(state.windows)
		delete(state.workspaces)
	}
	tab := rail_tab(workspace, 1)
	if !testing.expect(t, tab != nil) {return}
	w := app.Window {
		id        = 46,
		workspace = workspace,
		tree      = &tab.tree,
		width     = 1000,
		height    = 700,
		scale     = 1,
		rail_auto = true,
	}
	append(&state.windows, &w)
	layout_state, ok := app.rail_current_layout(&state, &w)
	if !testing.expect(t, ok) {return}
	footer := ui.rail_footer_tile(layout_state)
	_, new_tab, target := app.rail_pane_target(&state, &w, footer.x + 8, footer.y + 8)
	testing.expect(t, target && new_tab)
	empty_y := layout_state.list.y + layout_state.list.height - 4
	_, new_tab, target = app.rail_pane_target(&state, &w, footer.x + 8, empty_y)
	testing.expect(t, target && new_tab)
	row := app.rail_row_rect_for_tab(&state, &w, 0)
	on_tab, on_new, on_target := app.rail_pane_target(&state, &w, row.x + 20, row.y + 16)
	testing.expect(t, on_target && !on_new)
	testing.expect_value(t, on_tab, 0)
}
