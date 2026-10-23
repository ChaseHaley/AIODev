package app_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:control"
import "aio:layout"
import "aio:platform"
import "aio:term"

_ :: log

@(test)
window_workspaces_keep_metrics_and_runtimes_independent :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-windows-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\n"+
		"interface.font_size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(path, settings), nil) { return }
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.AppWindows.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	first := state.windows[0]
	first_session := state.sessions[0].session
	first_pid := term.process_id(first_session)
	testing.expect(t, first_pid != 0)
	second_workspace, allocation_error := new(app.Workspace)
	if !testing.expect_value(t, allocation_error, nil) { return }
	if _, err := append(&state.workspaces, second_workspace); err != nil {
		free(second_workspace)
		testing.expect_value(t, err, nil)
		return
	}
	if !testing.expect(t, app.tab_create(&state, second_workspace)) { return }
	if !testing.expect(t, app.window_open(&state, second_workspace)) { return }
	second := state.windows[1]
	second_session := state.sessions[1].session
	second_pid := term.process_id(second_session)
	testing.expect(t, second_pid != 0 && second_pid != first_pid)
	testing.expect(t, first.workspace == state.workspaces[0])
	testing.expect(t, second.workspace == second_workspace)
	testing.expect(t, first.tree != second.tree)
	testing.expect_value(t, len(state.sessions), 2)
	app.tick(&state)
	when app.AIO_CONTROL {
		first.focused, second.focused = true, false
		testing.expect_value(t, app.verify_drive(&state, control.Window_Select{u64(second.id)}), control.Error.None)
		entries, state_error := app.verify_state(&state)
		testing.expect_value(t, state_error, control.Error.None)
		testing.expect_value(t, app.verify_value(entries, "session.id"), fmt.tprintf("%d", state.sessions[1].id))
		testing.expect_value(t, app.verify_value(entries, "window.workspace_index"), "2")
		testing.expect(t, app.verify_window(&state) == second)
		testing.expect(t, first.focused && !second.focused)
	}
	when #config(AIO_NATIVE_FOCUS, false) {
		state.options.inactive = false
		logger := context.logger
		context.logger = {}
		activated := app.window_open(&state, second_workspace)
		context.logger = logger
		if activated {
			testing.expect(t, platform.window_is_focused(&state.platform, second.id))
			testing.expect(t, !platform.window_is_focused(&state.platform, first.id))
			log.info("native workspace activation succeeded")
		} else {
			log.info("native workspace activation was denied; ownership preserved")
		}
		testing.expect(t, first.workspace == state.workspaces[0])
		testing.expect_value(t, len(state.windows), 2)
		state.options.inactive = true
	}
	if !testing.expect(t, app.window_open(&state, second_workspace)) { return }
	if !testing.expect_value(t, len(state.windows), 2) { return }
	testing.expect(t, state.windows[1] == second)
	testing.expect(t, first.workspace == state.workspaces[0])
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(second_session), second_pid)
	app.window_set_dpi(&state, first, 144)
	testing.expect_value(t, first.ui_text.size_px, f32(24))
	testing.expect_value(t, second.ui_text.size_px, f32(16))
	app.window_set_dpi(&state, second, 168)
	testing.expect_value(t, second.ui_text.size_px, f32(28))
	testing.expect_value(t, first.ui_text.size_px, f32(24))
	app.window_set_dpi(&state, first, 96)
	testing.expect_value(t, first.ui_text.size_px, f32(16))
	testing.expect_value(t, second.ui_text.size_px, f32(28))
	second_geometry := term.geometry(second_session)
	app.window_resize(&state, first, 800, 600)
	testing.expect_value(t, term.geometry(second_session), second_geometry)
	app.window_close(&state, first)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, platform.window_native_handle(&state.platform, second.id) != nil)
	testing.expect_value(t, term.process_id(first_session), first_pid)
	testing.expect_value(t, term.process_id(second_session), second_pid)
	testing.expect_value(t, len(state.sessions), 2)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	opened := app.window_open(&state, state.workspaces[0])
	context.allocator = allocator
	testing.expect(t, !opened)
	testing.expect_value(t, len(state.windows), 1)
	if !testing.expect(t, app.window_open(&state, state.workspaces[0])) { return }
	testing.expect(t, state.windows[1].tree == &state.workspaces[0].tabs[0].tree)
	testing.expect_value(t, term.process_id(first_session), first_pid)
	testing.expect_value(t, len(state.sessions), 2)

	first = state.windows[1]
	app.run_action(&state, first, .Settings_UI)
	app.window_close(&state, first)
	testing.expect_value(t, os.remove(path), nil)
	testing.expect(t, !app.window_open(&state, state.workspaces[0]))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(first_session), first_pid)
	testing.expect_value(t, term.process_id(second_session), second_pid)
	testing.expect_value(t, os.write_entire_file(path, settings), nil)
	if !testing.expect(t, app.window_open(&state, state.workspaces[0])) {return}
	first = state.windows[1]
	testing.expect(t, first.editor.open && app.settings_active(first))
	app.tab_close(&state, first, 1)

	context.allocator = runtime.nil_allocator()
	opened = app.window_open(&state, second_workspace)
	context.allocator = allocator
	testing.expect(t, opened)
	testing.expect(t, app.window_for_workspace(&state, second_workspace) == second)
	testing.expect_value(t, len(state.windows), 2)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(second_session), second_pid)
	empty: app.Workspace
	testing.expect(t, !app.window_open(&state, &empty))
	testing.expect(t, !app.window_open(&state, nil))
	testing.expect_value(t, len(state.sessions), 2)

	first = state.windows[1]
	source_workspace_id := first.workspace.id
	source := app.selected_tab(first.workspace)
	destination := app.selected_tab(second_workspace)
	app.pane_split(&state, first, .Right)
	if !testing.expect_value(t, len(state.sessions), 3) { return }
	moved_session := state.sessions[2].session
	moved_id := state.sessions[2].id
	moved_pid := term.process_id(moved_session)
	testing.expect(t, moved_pid != 0 && moved_pid != first_pid && moved_pid != second_pid)
	if !testing.expect(t, app.pane_transfer(&state, second, source, destination,
		source.tree.focus, destination.tree.focus, .Right, false)) { return }
	testing.expect_value(t, len(first.panes), 1)
	testing.expect_value(t, len(second.panes), 2)
	testing.expect_value(t, destination.tree.nodes[destination.tree.focus].(layout.Pane).content.id, moved_id)
	testing.expect_value(t, term.process_id(moved_session), moved_pid)
	testing.expect_value(t, term.status(moved_session).kind, term.Status_Kind.Running)
	testing.expect_value(t, len(state.sessions), 3)
	if !testing.expect(t, app.pane_transfer(&state, second, source, destination,
		source.tree.focus, destination.tree.focus, .Down, true)) { return }
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, state.windows[0] == second)
	testing.expect(t, app.workspace_find(&state, source_workspace_id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(second.panes), 3)
	testing.expect_value(t, len(state.sessions), 3)
	testing.expect_value(t, term.process_id(first_session), first_pid)
	testing.expect_value(t, term.process_id(second_session), second_pid)
	testing.expect_value(t, term.process_id(moved_session), moved_pid)
	app.tick(&state)
	when app.AIO_CONTROL {
		app.window_close(&state, second)
		testing.expect(t, app.verify_window(&state) == nil)
		testing.expect_value(t, state.verify.target_window, platform.Window_Id(0))
		testing.expect_value(t, term.process_id(second_session), second_pid)
		testing.expect_value(t, len(state.sessions), 3)
	}
}
