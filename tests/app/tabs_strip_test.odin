package app_test

import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:ui"

@(private="file")
strip_tab :: proc(workspace: ^app.Workspace, id: u32) -> ^app.Tab {
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
strip_workspace :: proc(state: ^app.App, id: u32, name: string) -> ^app.Workspace {
	workspace := new(app.Workspace)
	workspace^ = {id = id, name = name}
	append(&state.workspaces, workspace)
	return workspace
}

@(private="file")
strip_destroy :: proc(state: ^app.App) {
	for workspace in state.workspaces {
		for tab in workspace.tabs {
			layout.destroy(&tab.tree)
			free(tab)
		}
		delete(workspace.tabs)
		free(workspace)
	}
	delete(state.workspaces)
	delete(state.windows)
}

@(test)
horizontal_tabs_fill_the_title_bar_without_a_rail :: proc(t: ^testing.T) {
	state: app.App
	defer strip_destroy(&state)
	workspace := strip_workspace(&state, 1, "Build")
	one := strip_tab(workspace, 1)
	two := strip_tab(workspace, 2)
	three := strip_tab(workspace, 3)
	if !testing.expect(t, one != nil && two != nil && three != nil) {return}
	one.marked = true
	w := app.Window {
		workspace       = workspace,
		tree            = &one.tree,
		width           = 1000,
		height          = 700,
		scale           = 1,
		rail_auto       = true,
		tabs_horizontal = true,
	}
	testing.expect(t, !app.rail_visible(&w))
	testing.expect(t, !app.rail_docked(&w))
	area := app.window_content_area(&state, &w)
	testing.expect_value(t, area.x, f32(0))
	testing.expect_value(t, area.width, f32(1000))

	bar := app.window_tab_bar(&state, &w)
	testing.expect_value(t, bar.count, 3)
	testing.expect(t, bar.tab_width > 0 && bar.tab_width <= 220)
	testing.expect(t, app.window_tab_hit(&state, &w, bar, bar.x+2, 20) == 0)
	testing.expect(t, app.window_tab_hit(&state, &w, bar, bar.x+bar.tab_width*3+2, 20) == bar.count)
	testing.expect(t, app.window_tab_hit(&state, &w, bar, 1, 20) == -1)

	// The strip and the two trailing buttons end before the native caption buttons start.
	testing.expect(t, app.window_title_controls_end(&state, &w) < f32(w.width)-138)
	testing.expect_value(t, app.window_tab_rect(&state, &w, 0).x, bar.x)
	expect_close := app.window_tab_close_rect(&state, &w, 1)
	testing.expect_value(t, expect_close.width, f32(22))
}

@(test)
horizontal_tab_click_and_close_use_the_strip_geometry :: proc(t: ^testing.T) {
	state: app.App
	defer strip_destroy(&state)
	workspace := strip_workspace(&state, 1, "Build")
	one := strip_tab(workspace, 1)
	two := strip_tab(workspace, 2)
	if !testing.expect(t, one != nil && two != nil) {return}
	one.marked = true
	w := app.Window {
		id              = 71,
		workspace       = workspace,
		tree            = &one.tree,
		width           = 1000,
		height          = 700,
		scale           = 1,
		tabs_horizontal = true,
	}
	defer app.tab_presentation_destroy(&w.presentation)
	append(&state.windows, &w)
	second := app.window_tab_rect(&state, &w, 1)
	app.handle_event(
		&state,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = true,
			x = i32(second.x + second.width / 2),
			y = i32(second.y + second.height / 2),
		},
	)
	testing.expect_value(t, workspace.selected, 1)
	app.handle_event(
		&state,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			x = i32(second.x + second.width / 2),
			y = i32(second.y + second.height / 2),
		},
	)
	testing.expect(t, w.tree == &two.tree)

	close := app.window_tab_close_rect(&state, &w, 1)
	app.handle_event(
		&state,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			pressed = true,
			x = i32(close.x + close.width / 2),
			y = i32(close.y + close.height / 2),
		},
	)
	testing.expect(t, ui.armed_is(w.tab_close_armed, 1))
	app.handle_event(
		&state,
		platform.Mouse_Button_Event {
			window = w.id,
			button = .Left,
			x = i32(close.x + close.width / 2),
			y = i32(close.y + close.height / 2),
		},
	)
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect(t, workspace.tabs[0] == one)
}

@(test)
tab_orientation_toggle_switches_the_setting_without_a_settings_file :: proc(t: ^testing.T) {
	state: app.App
	defer ui.notices_destroy(&state.notices)
	testing.expect_value(t, state.settings.tabs.orientation, settings.Tabs_Orientation.Vertical)
	app.toggle_tab_orientation(&state)
	testing.expect_value(t, state.settings.tabs.orientation, settings.Tabs_Orientation.Horizontal)
	app.toggle_tab_orientation(&state)
	testing.expect_value(t, state.settings.tabs.orientation, settings.Tabs_Orientation.Vertical)
}
