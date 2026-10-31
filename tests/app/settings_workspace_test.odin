package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"

@(test)
settings_scroll_survives_workspace_round_trips :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-settings-workspace-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.SettingsWorkspace.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	one := w.workspace
	app.run_action(&state, w, .Settings_UI)
	if !testing.expect(t, w.editor.open) {return}
	initial_scroll := w.editor.scroll
	w.editor.scroll = 24
	app.run_action(&state, w, .New_Workspace)
	two := w.workspace
	if !testing.expect(t, two != one) {return}
	if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
	testing.expect_value(t, w.editor.scroll, 24)
	if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
	app.run_action(&state, w, .Settings_UI)
	w.editor.scroll = 48
	for _ in 0..<3 {
		if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
		testing.expect_value(t, w.editor.scroll, 24)
		if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
		testing.expect_value(t, w.editor.scroll, 48)
	}
	// A failed incoming load must leave the displayed workspace and its reading position intact.
	settings_path := state.settings_path
	state.settings_path = fmt.tprintf("%s/missing.ini", directory)
	selected := app.workspace_select(&state, w, one)
	state.settings_path = settings_path
	testing.expect(t, !selected)
	testing.expect_value(t, w.workspace, two)
	testing.expect_value(t, w.editor.scroll, 48)
	if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
	testing.expect_value(t, w.editor.scroll, 24)
	if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
	// Closing Settings discards its saved position instead of reviving it on the next open.
	app.run_action(&state, w, .Close_Tab)
	testing.expect(t, !w.editor.open)
	if !testing.expect(t, app.workspace_select(&state, w, one)) {return}
	if !testing.expect(t, app.workspace_select(&state, w, two)) {return}
	app.run_action(&state, w, .Settings_UI)
	testing.expect_value(t, w.editor.scroll, initial_scroll)
}
