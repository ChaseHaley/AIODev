package app_test

import "core:fmt"
import "core:testing"
import app "../../src"
import "aio:control"
import "aio:layout"
import "aio:platform"

when app.AIO_CONTROL {
	@(test)
	verification_target_overrides_focus_and_clears_after_destruction :: proc(t: ^testing.T) {
		first_workspace, second_workspace: app.Workspace
		first := app.Window{id = 11, workspace = &first_workspace, focused = true}
		second := app.Window{id = 22, workspace = &second_workspace}
		state: app.App
		append(&state.windows, &first, &second)
		defer delete(state.windows)
		testing.expect(t, app.verify_window(&state) == &first)
		testing.expect_value(t, app.verify_drive(&state, control.Window_Select{22}), control.Error.None)
		testing.expect(t, app.verify_window(&state) == &second)
		testing.expect(t, first.focused && !second.focused)
		testing.expect_value(t, app.verify_drive(&state, control.Window_Select{99}), control.Error.Invalid_Argument)
		testing.expect_value(t, state.verify.target_window, platform.Window_Id(22))
		app.verify_clear(&state.verify)
		testing.expect(t, app.verify_window(&state) == &second)
		state.verify.mouse_window, state.verify.buttons = second.id, {.Left}
		second.dragging.count = 1
		second.tab_drag.pressed = true
		app.handle_event(&state, platform.Capture_Lost_Event{second.id})
		testing.expect_value(t, second.dragging.count, 0)
		testing.expect(t, !second.tab_drag.pressed)
		ordered_remove(&state.windows, 1)
		testing.expect(t, app.verify_window(&state) == &first)
		testing.expect_value(t, state.verify.target_window, platform.Window_Id(0))
		testing.expect_value(t, state.verify.mouse_window, platform.Window_Id(0))
		testing.expect(t, state.verify.buttons == {})
		first.focused = false
		testing.expect(t, app.verify_window(&state) == &first)
		clear(&state.windows)
		testing.expect(t, app.verify_window(&state) == nil)
	}

	@(test)
	verification_inventory_and_tabs_follow_selected_workspace :: proc(t: ^testing.T) {
		state := app.App{app_id = "AIODev.Test.VerifyState"}
		if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
			return
		}
		defer testing.expect_value(t, platform.destroy(&state.platform), platform.Error.None)
		first_id, err := platform.window_create(&state.platform, {hidden = true, width = 160, height = 100})
		if !testing.expect_value(t, err, platform.Error.None) { return }
		second_id, second_error := platform.window_create(&state.platform,
			{hidden = true, width = 240, height = 140})
		if !testing.expect_value(t, second_error, platform.Error.None) { return }
		first_workspace, second_workspace: app.Workspace
		first_tab := app.Tab{id = 101}
		second_tab := app.Tab{id = 202}
		if !testing.expect_value(t, layout.init(&first_tab.tree, {.Terminal, 0}), nil) { return }
		defer layout.destroy(&first_tab.tree)
		if !testing.expect_value(t, layout.init(&second_tab.tree, {.Terminal, 0}), nil) { return }
		defer layout.destroy(&second_tab.tree)
		append(&first_workspace.tabs, &first_tab)
		defer delete(first_workspace.tabs)
		append(&second_workspace.tabs, &second_tab)
		defer delete(second_workspace.tabs)
		first := app.Window{id = first_id, workspace = &first_workspace, tree = &first_tab.tree,
			focused = true, width = 160, height = 100}
		second := app.Window{id = second_id, workspace = &second_workspace, tree = &second_tab.tree,
			width = 240, height = 140}
		append(&state.windows, &first, &second)
		defer delete(state.windows)
		append(&state.workspaces, &first_workspace, &second_workspace)
		defer delete(state.workspaces)
		testing.expect_value(t, app.verify_drive(&state, control.Window_Select{u64(second_id)}), control.Error.None)
		testing.expect_value(t, app.verify_drive(&state, control.Window_Move{{-320, -200}}), control.Error.None)
		x, y, screen_error := platform.window_to_screen(&state.platform, second_id, -20, -10)
		testing.expect_value(t, screen_error, platform.Error.None)
		point, ok := app.verify_position(&state, &second, {int(x), int(y)}, false, true)
		testing.expect(t, ok)
		testing.expect_value(t, point, [2]i32{-20, -10})
		_, ok = app.verify_position(&state, &second, {-1, 0}, true)
		testing.expect(t, !ok)
		entries, state_error := app.verify_state(&state)
		testing.expect_value(t, state_error, control.Error.None)
		testing.expect_value(t, app.verify_value(entries, "windows.count"), "2")
		testing.expect_value(t, app.verify_value(entries, "window.id"), fmt.tprintf("%d", second_id))
		testing.expect_value(t, app.verify_value(entries, "window.workspace_index"), "2")
		testing.expect_value(t, app.verify_value(entries, "window.1.workspace_index"), "1")
		testing.expect_value(t, app.verify_value(entries, "window.2.workspace_index"), "2")
		testing.expect_value(t, app.verify_value(entries, "window.2.size"), "240x140")
		testing.expect_value(t, app.verify_value(entries, "window.2.id"), fmt.tprintf("%d", second_id))
		origin_x, origin_y, origin_error := platform.window_to_screen(&state.platform, second_id, 0, 0)
		testing.expect_value(t, origin_error, platform.Error.None)
		testing.expect_value(t, app.verify_value(entries, "window.2.origin"), fmt.tprintf("%d,%d", origin_x, origin_y))
		testing.expect_value(t, app.verify_value(entries, "window.origin"), fmt.tprintf("%d,%d", origin_x, origin_y))
		testing.expect_value(t, app.verify_value(entries, "tab.1.id"), "202")
		testing.expect_value(t, app.verify_value(entries, "window.focused"), "false")
		state.verify.target_window = first_id
		entries, state_error = app.verify_state(&state)
		testing.expect_value(t, state_error, control.Error.None)
		testing.expect_value(t, app.verify_value(entries, "tab.1.id"), "101")
		clear(&state.windows)
		clear(&state.workspaces)
		entries, state_error = app.verify_state(&state)
		testing.expect_value(t, state_error, control.Error.None)
		testing.expect_value(t, app.verify_value(entries, "window.id"), "0")
		testing.expect_value(t, app.verify_value(entries, "tabs.count"), "0")
	}
}
