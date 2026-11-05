package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"

@(test)
closed_panes_and_tabs_reopen_in_place :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-reopen-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	settings := idle_shell_settings(t, "cursor.blink = false\ntab.confirm_close = false\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return}
	state: app.App
	state.options = {data_dir = directory, inactive = true}
	state.app_id = fmt.aprintf("AIODev.Test.Reopen.%d", os.get_pid())
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		delete(state.app_id)
		return
	}
	state.platform_ready = true
	defer app.app_destroy(&state)
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	workspace := w.workspace

	// Nothing closed yet: the request is answered without changes.
	app.closed_reopen(&state, w)
	testing.expect_value(t, len(state.sessions), 1)

	// A named pane closed from the left of a split returns there with its share.
	app.pane_split(&state, w, .Right, 0.5)
	app.pane_split(&state, w, .Down, 0.5)
	tree := &workspace.tabs[0].tree
	left := layout.Node_Id(0)
	pane := tree.nodes[left].(layout.Pane)
	entry := app.session_find(&state, pane.content.id)
	entry.name = strings.clone("left")
	testing.expect_value(t, len(state.sessions), 3)
	app.pane_close_at(&state, workspace, 0, left)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, len(state.closed), 1)
	app.closed_reopen(&state, w)
	testing.expect_value(t, len(state.closed), 0)
	testing.expect_value(t, len(state.sessions), 3)
	root, is_split := tree.nodes[tree.root].(layout.Split)
	if !testing.expect(t, is_split) {return}
	testing.expect_value(t, root.axis, layout.Axis.Horizontal)
	testing.expect_value(t, root.ratio, f32(0.5))
	first, first_pane := tree.nodes[root.first].(layout.Pane)
	if !testing.expect(t, first_pane) {return}
	testing.expect_value(t, tree.focus, root.first)
	reopened := app.session_find(&state, first.content.id)
	if !testing.expect(t, reopened != nil) {return}
	testing.expect_value(t, reopened.name, "left")
	_, second_split := tree.nodes[root.second].(layout.Split)
	testing.expect(t, second_split)

	// A closed split tab returns whole at its position.
	testing.expect(t, app.tab_create(&state, workspace))
	app.tab_close(&state, w, 0)
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect_value(t, len(state.sessions), 1)
	app.closed_reopen(&state, w)
	testing.expect_value(t, len(workspace.tabs), 2)
	testing.expect_value(t, len(state.sessions), 4)
	testing.expect_value(t, workspace.selected, 0)
	panes := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(&workspace.tabs[0].tree, workspace.tabs[0].tree.root, &panes)
	testing.expect_value(t, len(panes), 3)
}
