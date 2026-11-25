package app_test

import app "../../src"
import "aio:layout"
import "cosmos:platform"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The owner asked that a pane opened from a Neovim pane start where Neovim is working (WORK-651): a split
// by key, a float and Agent changes take Neovim's reported directory, not the folder the pane started in
// nor the profile's.
@(test)
neovim_pane_spawns_in_neovim_directory :: proc(t: ^testing.T) {
	data, data_error := os.make_directory_temp("", "aio-neovim-directory-*", context.allocator)
	if !testing.expect_value(t, data_error, nil) {return}
	defer delete(data)
	defer os.remove_all(data)
	started := fmt.tprintf("%s\\started", data)
	working := fmt.tprintf("%s\\working", data)
	for folder in ([]string{started, working}) {
		if !testing.expect_value(t, os.make_directory(folder), nil) {return}
	}
	settings := idle_shell_settings(t, "cursor.blink = false\n")
	if !testing.expect_value(t, os.write_entire_file(fmt.tprintf("%s/settings.ini", data), settings), nil) {return}

	state := app.App{options = {data_dir = data, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.NeovimDirectory.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	workspace := w.workspace

	// A Neovim pane that started in one folder and has since reported another, as after :cd. It counts as
	// started, so laying it out never runs a real Neovim.
	pane := app.neovim_pane_create(&state, "", started)
	if !testing.expect(t, pane != nil) {return}
	pane.started = true
	pane.client.allocator = context.allocator
	pane.client.directory = strings.clone(working)
	content := layout.Content{.Neovim, pane.id}
	inserted := app.pane_split_insert(
		&state, w, workspace, workspace.selected, app.window_tree(w).focus, .Right, 0.5, true, content, false,
	)
	if !testing.expect_value(t, inserted, app.Pane_Split_Error.None) {return}
	focus_neovim :: proc(state: ^app.App, w: ^app.Window, content: layout.Content) -> bool {
		node := layout.find_content(app.window_tree(w), content)
		if node == layout.INVALID_NODE {return false}
		app.pane_focus(state, w, node)
		return app.window_tree(w).focus == node
	}
	last_launch :: proc(state: ^app.App) -> string {
		return state.sessions[len(state.sessions) - 1].header.launch_directory
	}

	if !testing.expect(t, focus_neovim(&state, w, content)) {return}
	sessions := len(state.sessions)
	app.run_action(&state, w, .Split)
	if testing.expect_value(t, len(state.sessions), sessions + 1) {
		testing.expect_value(t, last_launch(&state), working)
	}

	if !testing.expect(t, focus_neovim(&state, w, content)) {return}
	app.floating_new(&state, w)
	if testing.expect_value(t, len(state.sessions), sessions + 2) {
		testing.expect_value(t, last_launch(&state), working)
	}

	if !testing.expect(t, focus_neovim(&state, w, content)) {return}
	app.changes_open(&state, w)
	changes := app.changes_focused(&state, w)
	if testing.expect(t, changes != nil) {
		testing.expect_value(t, changes.directory, working)
	}
}
