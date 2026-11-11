package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:ui"

// The page's reading position and its open rows belong to the workspace, so leaving and coming back
// shows Settings as it was left.
@(test)
settings_view_survives_workspace_round_trips :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-settings-workspace-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path,
		idle_shell_settings(t, "cursor.blink = false\n")), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.SettingsWorkspace.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	one := w.workspace
	app.run_action(&state, w, .Settings_UI)
	if !testing.expect(t, ui.editor_loaded(&w.editor)) {return}
	initial_scroll := w.editor.scroll
	w.editor.scroll = 24
	ui.editor_motion_toggle(&w.editor, .Panes)
	app.run_action(&state, w, .New_Workspace)
	app.rename_finish(&state, w, true)
	two := w.workspace
	if !testing.expect(t, two != one) {return}
	if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
	testing.expect_value(t, w.editor.scroll, 24)
	testing.expect(t, .Panes in w.editor.motion_expanded)
	for _ in 0..<3 {
		if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
		if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
		testing.expect_value(t, w.editor.scroll, 24)
		testing.expect(t, .Panes in w.editor.motion_expanded)
	}
	// Opening Settings from another workspace returns to the tab at its reading position.
	if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
	app.run_action(&state, w, .Settings_UI)
	testing.expect(t, w.workspace == one)
	testing.expect_value(t, w.editor.scroll, 24)
	testing.expect(t, .Panes in w.editor.motion_expanded)
	if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
	// A failed incoming load must leave the displayed workspace intact.
	settings_path := state.settings_path
	state.settings_path = fmt.tprintf("%s/missing.ini", directory)
	selected := app.workspace_select(&state, w, one)
	state.settings_path = settings_path
	testing.expect(t, !selected)
	testing.expect_value(t, w.workspace, two)
	if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
	testing.expect_value(t, w.editor.scroll, 24)
	testing.expect(t, .Panes in w.editor.motion_expanded)
	// Closing Settings discards its saved position and open rows instead of reviving them on the next open.
	app.run_action(&state, w, .Close_Tab)
	testing.expect(t, !ui.editor_loaded(&w.editor))
	if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
	if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
	app.run_action(&state, w, .Settings_UI)
	testing.expect_value(t, w.editor.scroll, initial_scroll)
	testing.expect(t, .Panes not_in w.editor.motion_expanded)
}
