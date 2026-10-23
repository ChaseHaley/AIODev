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
	workspace_id := state.next_workspace_id
	workspace_number := state.next_workspace_number
	tab_id := source_workspace.next_tab_id
	last_preview := app.pane_window_preview_create(&state, source, node, 80, 80)
	testing.expect(t, last_preview == nil)
	if last_preview != nil { app.pane_window_preview_discard(&state, last_preview.id) }
	testing.expect_value(t, state.next_workspace_id, workspace_id)
	testing.expect_value(t, source_workspace.next_tab_id, tab_id)
	app.pane_drag_press(&state, source_window, node, 80, 58)
	testing.expect(t, app.pane_drag_move(&state, source_window, -30_000, -30_000, false))
	testing.expect(t, source_window.pane_drag.active && !source_window.pane_drag.new_window)
	testing.expect(t, !source_window.pane_drag.shown && !source_window.pane_drag.preview_failed)
	testing.expect_value(t, source_window.pane_drag.preview_window, platform.Window_Id(0))
	testing.expect(t, app.pane_drag_release(&state, source_window))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, state.next_workspace_id, workspace_id)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, term.process_id(session), pid)
	app.run_action(&state, source_window, .Settings_UI)
	settings_tab := app.selected_tab(source_workspace)
	workspace_id = state.next_workspace_id
	testing.expect(t, app.pane_window_preview_create(&state, settings_tab, settings_tab.tree.root, 80, 80) == nil)
	testing.expect_value(t, state.next_workspace_id, workspace_id)
	settings_preview := app.pane_window_preview_create(&state, source, node, 80, 80)
	if !testing.expect(t, settings_preview != nil) { return }
	app.pane_window_preview_discard(&state, settings_preview.id)
	testing.expect_value(t, state.next_workspace_number, workspace_number)
	app.tab_close(&state, source_window, 1)
	testing.expect_value(t, len(source_workspace.tabs), 1)
	testing.expect_value(t, len(state.sessions), 1)
	if !testing.expect(t, app.tab_create(&state, source_workspace)) { return }
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
	testing.expect_value(t, state.next_workspace_number, workspace_number)
	testing.expect(t, state.next_workspace_id > workspace_id)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, term.process_id(session), pid)
	preview := app.pane_window_preview_create(&state, source, node, 80, 80)
	if !testing.expect(t, preview != nil) { return }
	testing.expect(t, preview.preparing)
	testing.expect_value(t, preview.workspace.name, "")
	testing.expect_value(t, state.next_workspace_number, workspace_number)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, len(preview.views), 0)
	testing.expect_value(t, cap(preview.views), 0)
	app.window_set_dpi(&state, preview, 144)
	testing.expect_value(t, len(preview.views), 0)
	testing.expect_value(t, term.geometry(session), geometry)
	app.window_set_dpi(&state, preview, 96)
	testing.expect(t, app.pane_window_preview_hide(&state, preview.id))
	testing.expect(t, !preview.preview_visible && preview.preparing)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect(t, app.window_show_prepared(&state, preview))
	testing.expect(t, preview.preview_visible && preview.preparing)
	preview_id := preview.id
	preview_workspace_id := preview.workspace.id
	app.pane_window_preview_discard(&state, preview_id)
	testing.expect(t, app.window_find(&state, preview_id) == nil)
	testing.expect_value(t, state.next_workspace_id, preview_workspace_id)
	testing.expect_value(t, state.next_workspace_number, workspace_number)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.geometry(session), geometry)
	preview = app.pane_window_preview_create(&state, source, node, 100, 100)
	if !testing.expect(t, preview != nil) { return }
	app.pane_drag_press(&state, source_window, node, 80, 80)
	source_window.pane_drag.preview_window = preview.id
	app.window_close(&state, preview)
	testing.expect(t, !source_window.pane_drag.pressed)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, term.geometry(session), geometry)
	preview = app.pane_window_preview_create(&state, source, node, 100, 100)
	if !testing.expect(t, preview != nil) { return }
	preview_id = preview.id
	app.tab_close(&state, source_window, 1)
	testing.expect(t, !app.pane_to_window(&state, source_window, source, node, preview_id))
	testing.expect_value(t, state.next_workspace_number, workspace_number)
	testing.expect(t, preview.preparing && preview.workspace.provisional)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.geometry(session), geometry)
	app.pane_drag_press(&state, source_window, node, 80, 58)
	source_window.pane_drag.preview_window = preview_id
	testing.expect(t, app.pane_drag_move(&state, source_window, -30_000, -30_000, false))
	testing.expect(t, !source_window.pane_drag.new_window && !source_window.pane_drag.shown)
	testing.expect_value(t, source_window.pane_drag.preview_window, platform.Window_Id(0))
	testing.expect(t, app.window_find(&state, preview_id) == nil)
	testing.expect(t, app.pane_drag_release(&state, source_window))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	if !testing.expect(t, app.tab_create(&state, source_workspace)) { return }
	preview = app.pane_window_preview_create(&state, source, node, 100, 100)
	if !testing.expect(t, preview != nil) { return }
	preview_id = preview.id
	preview_workspace_id = preview.workspace.id
	allocator = context.allocator
	context.allocator = runtime.nil_allocator()
	failed_commit := app.pane_to_window(&state, source_window, source, node, preview_id)
	context.allocator = allocator
	testing.expect(t, !failed_commit)
	testing.expect(t, preview.preparing && preview.workspace.provisional)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, state.next_workspace_number, workspace_number)
	// The sole pane of one tab can move while another tab keeps the workspace populated.
	if !testing.expect(t, app.pane_to_window(&state, source_window, source, node, preview_id)) { return }
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, app.window_find(&state, preview_id) == preview)
	testing.expect(t, !preview.preparing)
	testing.expect_value(t, preview.workspace.name, "Workspace 2")
	testing.expect_value(t, preview.workspace.id, preview_workspace_id)
	testing.expect(t, preview.workspace.id > 2)
	testing.expect_value(t, state.next_workspace_number, u32(2))
	testing.expect_value(t, len(source_workspace.tabs), 1)
	testing.expect_value(t, len(preview.panes), 1)
	testing.expect_value(t, preview.panes[0].content, layout.Content{.Terminal, state.sessions[0].id})
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	testing.expect(t, !state.tray_hint_shown)
	app.tick(&state)

	// A foreign empty strip accepts the sole pane and removes only its exhausted source view.
	second_workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, second_workspace != nil) { return }
	if !testing.expect(t, app.tab_create(&state, second_workspace)) { return }
	if !testing.expect(t, app.window_open(&state, second_workspace)) { return }
	second := app.window_for_workspace(&state, second_workspace)
	if !testing.expect(t, app.pane_to_tab(&state, second, app.selected_tab(preview.workspace), preview.tree.root)) { return }
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, app.window_find(&state, second.id) == second)
	testing.expect_value(t, len(second_workspace.tabs), 2)
	testing.expect_value(t, len(state.sessions), 3)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, second.panes[0].content.id, state.sessions[0].id)
}
