package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:platform"
import "aio:term"

@(test)
workspace_move_commands_preserve_live_content_and_cleanup_sources :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-workspace-moves-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.WorkspaceMoves.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	original := w.workspace
	for name in ([?]string{"pane.move_workspace", "pane.move_new_workspace", "tab.move_workspace", "tab.move_new_workspace"}) {
		testing.expect(t, commands.find(&state.registry, name) != nil)
	}
	app.run_action(&state, w, .Split_Right)
	if !testing.expect_value(t, len(state.sessions), 2) {return}
	session := app.focused_session(&state, w).session
	pid := term.process_id(session)
	app.run_action(&state, w, .Move_Pane_Workspace)
	testing.expect_value(t, len(w.workspace_picker.rows), 0)
	testing.expect_value(t, app.workspace_picker_count(w), 1)
	app.workspace_picker_cancel(w)
	testing.expect_value(t, app.tab_pane_count(app.selected_tab(original)), 2)
	app.run_action(&state, w, .Move_Pane_New_Workspace)
	two := w.workspace
	testing.expect(t, two != original)
	testing.expect_value(t, len(two.tabs), 1)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, app.tab_pane_count(app.selected_tab(original)), 1)
	testing.expect_value(t, app.focused_session(&state, w).session, session)
	testing.expect_value(t, term.process_id(session), pid)
	app.run_action(&state, w, .Split_Down)
	name, name_error := strings.clone("Build pair")
	if !testing.expect_value(t, name_error, nil) {return}
	app.selected_tab(two).name = name
	request := app.workspace_move_request(w, true)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.workspace_move_content(&state, w, request, original)
	context.allocator = allocator
	testing.expect(t, !failed)
	testing.expect_value(t, app.tab_pane_count(app.selected_tab(two)), 2)
	testing.expect_value(t, len(original.tabs), 1)
	app.run_action(&state, w, .Move_Tab_Workspace)
	if !testing.expect_value(t, len(w.workspace_picker.rows), 1) {return}
	app.workspace_picker_choose(&state, w)
	testing.expect_value(t, w.workspace, original)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(original.tabs), 2)
	testing.expect_value(t, app.selected_tab(original).name, "Build pair")
	testing.expect_value(t, app.tab_pane_count(app.selected_tab(original)), 2)
	testing.expect_value(t, len(state.sessions), 3)
	testing.expect_value(t, term.process_id(session), pid)
	app.run_action(&state, w, .Move_Tab_New_Workspace)
	three := w.workspace
	testing.expect(t, three != original)
	testing.expect_value(t, app.tab_pane_count(app.selected_tab(three)), 2)
	app.run_action(&state, w, .Settings_UI)
	app.run_action(&state, w, .Move_Pane_New_Workspace)
	settings_workspace := w.workspace
	testing.expect(t, settings_workspace != three)
	testing.expect(t, app.settings_active(w))
	testing.expect_value(t, len(state.sessions), 3)
	if !testing.expect(t, app.workspace_select(&state, w, three)) {return}
	app.run_action(&state, w, .Settings_UI)
	settings_request := app.workspace_move_request(w, true)
	testing.expect(t, !app.workspace_move_content(&state, w, settings_request, settings_workspace))
	settings_request.whole_tab = false
	testing.expect(t, !app.workspace_move_content(&state, w, settings_request, settings_workspace))
	settings_request.tab = max(u32)
	testing.expect(t, !app.workspace_move_content(&state, w, settings_request, original))
	testing.expect(t, !app.workspace_move_content(&state, w, app.workspace_move_request(w, true), three))
	// A sole source tab can move into another window without leaving the picker callback on freed storage.
	if !testing.expect(t, app.workspace_select(&state, w, original)) {return}
	if !testing.expect(t, app.window_open(&state, settings_workspace)) {return}
	other := app.window_for_workspace(&state, settings_workspace)
	other_id, settings_id := other.id, settings_workspace.id
	app.run_action(&state, other, .Move_Pane_Workspace)
	for row, i in other.workspace_picker.rows {
		if row.id == original.id {other.workspace_picker.selected = i; break}
	}
	app.handle_event(&state, platform.Key_Event{window = other.id, key = .Enter, pressed = true})
	testing.expect(t, app.window_find(&state, other_id) == nil)
	testing.expect(t, app.workspace_find(&state, settings_id) == nil)
	testing.expect_value(t, len(state.sessions), 3)
	testing.expect(t, app.workspace_find(&state, settings_request.workspace) != nil)
}
