package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:term"

@(test)
pane_window_preparation_cancel_and_commit_keep_runtime :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-pane-windows-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"), nil) { return }
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.PaneWindows.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) { return }
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	source_window := state.windows[0]
	source_workspace := source_window.workspace
	source := app.selected_tab(source_workspace)
	node := source.tree.root
	session := state.sessions[0].session
	pid := term.process_id(session)
	geometry := term.geometry(session)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.pane_window_preview_create(&state, source, node, 80, 80)
	context.allocator = allocator
	testing.expect(t, failed == nil)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, source.tree.root, node)
	minimum := state.settings.pane.minimum_columns
	state.settings.pane.minimum_columns = 10_000
	failed = app.pane_window_preview_create(&state, source, node, 80, 80)
	state.settings.pane.minimum_columns = minimum
	testing.expect(t, failed == nil)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, term.process_id(session), pid)
	preview := app.pane_window_preview_create(&state, source, node, 80, 80)
	if !testing.expect(t, preview != nil) { return }
	testing.expect(t, preview.preparing)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, len(preview.views), 0)
	preview_id := preview.id
	app.pane_window_preview_discard(&state, preview_id)
	testing.expect(t, app.window_find(&state, preview_id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, term.geometry(session), geometry)
	preview = app.pane_window_preview_create(&state, source, node, 100, 100)
	if !testing.expect(t, preview != nil) { return }
	preview_id = preview.id
	// The prepared window adopts the existing runtime when its sole source view closes.
	if !testing.expect(t, app.pane_to_window(&state, source_window, source, node, preview_id)) { return }
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, state.windows[0] == preview)
	testing.expect(t, !preview.preparing)
	testing.expect_value(t, len(source_workspace.tabs), 0)
	testing.expect_value(t, len(preview.panes), 1)
	testing.expect_value(t, preview.panes[0].content, layout.Content{.Terminal, state.sessions[0].id})
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	app.tick(&state)

	// A foreign empty strip accepts the sole pane and removes only its exhausted source view.
	second_workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, second_workspace != nil) { return }
	if !testing.expect(t, app.tab_create(&state, second_workspace)) { return }
	if !testing.expect(t, app.window_open(&state, second_workspace)) { return }
	second := app.window_for_workspace(&state, second_workspace)
	if !testing.expect(t, app.pane_to_tab(&state, second, app.selected_tab(preview.workspace), preview.tree.root)) { return }
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, state.windows[0] == second)
	testing.expect_value(t, len(second_workspace.tabs), 2)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, second.panes[0].content.id, state.sessions[0].id)
}
