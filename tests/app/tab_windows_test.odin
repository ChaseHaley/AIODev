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
import "aio:ui"

@(private = "file")
tab_pane_count :: proc(tab: ^app.Tab) -> int {
	return layout.pane_count(&tab.tree)
}

// Presses tab `index` and drags it past every window, which is how a tear-off starts.
@(private = "file")
tab_drag_off_window :: proc(state: ^app.App, w: ^app.Window, index: int) -> bool {
	app.tab_press(state, w, index, 80, 20, false)
	return app.tab_drag_move(state, w, -30_000, -30_000)
}

@(test)
tab_tear_off_moves_marked_tabs_with_all_their_panes :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-tab-windows-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(
		t,
		os.write_entire_file(path, idle_shell_settings(t, "cursor.blink = false\n")),
		nil,
	) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.TabWindows.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	source := state.windows[0]
	workspace := source.workspace

	// A workspace's only tab stays, however many panes it has, and nothing is prepared for it.
	app.pane_split(&state, source, .Right)
	if !testing.expect_value(t, tab_pane_count(app.selected_tab(workspace)), 2) {return}
	testing.expect(t, tab_drag_off_window(&state, source, 0))
	testing.expect(t, source.tab_drag.active && !source.tab_drag.new_window)
	testing.expect_value(t, source.tab_drag.preview_window, platform.Window_Id(0))
	app.tab_drag_release(&state, source)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(workspace.tabs), 1)

	if !testing.expect(t, app.tab_create(&state, workspace)) {return}
	if !testing.expect(t, app.tab_create(&state, workspace)) {return}
	first, second, third := workspace.tabs[0], workspace.tabs[1], workspace.tabs[2]
	first.name = strings.clone("Tools")
	app.tab_select(&state, source, 0)
	content := first.tree.nodes[first.tree.focus].(layout.Pane).content
	sessions := len(state.sessions)
	session := state.sessions[0].session
	pid := term.process_id(session)

	// Cancelling discards the hidden destination and keeps the source exactly as it was.
	testing.expect(t, tab_drag_off_window(&state, source, 0))
	testing.expect(t, source.tab_drag.new_window)
	preview := app.window_find(&state, source.tab_drag.preview_window)
	if !testing.expect(t, preview != nil) {return}
	testing.expect(t, preview.preparing && preview.workspace.provisional)
	testing.expect_value(t, len(state.sessions), sessions)
	testing.expect_value(t, tab_pane_count(first), 2)
	app.tab_drag_cancel(&state, source)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect(t, workspace.tabs[0] == first)
	testing.expect_value(t, len(state.sessions), sessions)

	// Closing the destination cancels the drag rather than leaving it pointing at nothing.
	testing.expect(t, tab_drag_off_window(&state, source, 0))
	preview = app.window_find(&state, source.tab_drag.preview_window)
	if !testing.expect(t, preview != nil) {return}
	app.window_close(&state, preview)
	testing.expect(t, !source.tab_drag.pressed)
	testing.expect_value(t, len(state.workspaces), 1)

	// Allocation failure at the drop leaves both sides whole.
	testing.expect(t, tab_drag_off_window(&state, source, 0))
	preview = app.window_find(&state, source.tab_drag.preview_window)
	if !testing.expect(t, preview != nil) {return}
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.tabs_to_window(&state, source, preview)
	context.allocator = allocator
	testing.expect(t, !failed)
	testing.expect(t, preview.preparing)
	testing.expect_value(t, tab_pane_count(first), 2)
	testing.expect_value(t, len(workspace.tabs), 3)
	app.tab_drag_cancel(&state, source)

	// The drop carries every pane, the running sessions and the tab's name, then names the window.
	testing.expect(t, tab_drag_off_window(&state, source, 0))
	preview = app.window_find(&state, source.tab_drag.preview_window)
	if !testing.expect(t, preview != nil) {return}
	app.tab_drag_release(&state, source)
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, !preview.preparing && !preview.workspace.provisional)
	testing.expect(t, preview.workspace.name != "")
	testing.expect(t, preview.rename_open && preview.rename_mode == .Workspace)
	testing.expect(t, !source.rename_open)
	testing.expect_value(t, ui.field_selected_text(&preview.rename), preview.workspace.name)
	app.rename_finish(&state, preview, true)
	if !testing.expect_value(t, len(preview.workspace.tabs), 1) {return}
	torn := preview.workspace.tabs[0]
	testing.expect_value(t, tab_pane_count(torn), 2)
	testing.expect_value(t, torn.name, "Tools")
	testing.expect_value(t, len(preview.panes), 2)
	testing.expect(t, layout.find_content(&torn.tree, content) != layout.INVALID_NODE)
	testing.expect_value(t, len(state.sessions), sessions)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	// The source keeps the tabs that stayed and shows the nearest of them.
	testing.expect_value(t, len(workspace.tabs), 2)
	testing.expect(t, workspace.tabs[0] == second && workspace.tabs[1] == third)
	testing.expect(t, app.selected_tab(workspace) == second)
	testing.expect(t, source.tree == &second.tree)
	testing.expect(t, second.marked && !third.marked)
	app.tick(&state)

	// A marked group leaves together, in order, keeping which of them is selected.
	if !testing.expect(t, app.tab_create(&state, workspace)) {return}
	fourth := workspace.tabs[2]
	app.tab_pointer_select(&state, source, 0, false, false)
	app.tab_pointer_select(&state, source, 2, true, false)
	content_second := second.tree.nodes[second.tree.focus].(layout.Pane).content
	content_fourth := fourth.tree.nodes[fourth.tree.focus].(layout.Pane).content
	testing.expect(t, tab_drag_off_window(&state, source, 2))
	group := app.window_find(&state, source.tab_drag.preview_window)
	if !testing.expect(t, group != nil) {return}
	app.tab_drag_release(&state, source)
	app.rename_finish(&state, group, true)
	if !testing.expect_value(t, len(group.workspace.tabs), 2) {return}
	moved := group.workspace.tabs
	testing.expect(t, layout.find_content(&moved[0].tree, content_second) != layout.INVALID_NODE)
	testing.expect(t, layout.find_content(&moved[1].tree, content_fourth) != layout.INVALID_NODE)
	testing.expect_value(t, group.workspace.selected, 1)
	testing.expect(t, group.tree == &moved[1].tree)
	testing.expect(t, moved[0].marked && moved[1].marked)
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect(t, workspace.tabs[0] == third && third.marked)
	testing.expect_value(t, len(state.windows), 3)
	testing.expect_value(t, len(state.sessions), sessions + 1)
	app.tick(&state)

	// A pane in a linked window stays part of its tab, so the window follows the tab to its new home.
	app.pane_split(&state, group, .Right)
	app.pane_link_toggle(&state, group)
	linked: ^app.Window
	for window in state.windows {if window.linked {linked = window}}
	if !testing.expect(t, linked != nil) {return}
	testing.expect_value(t, linked.link_workspace, group.workspace.id)
	carried := moved[1]
	panes := layout.pane_count(&carried.tree)
	app.tab_select(&state, group, 1)
	testing.expect(t, tab_drag_off_window(&state, group, 1))
	home := app.window_find(&state, group.tab_drag.preview_window)
	if !testing.expect(t, home != nil) {return}
	app.tab_drag_release(&state, group)
	app.rename_finish(&state, home, true)
	app.pane_links_sync(&state)
	if !testing.expect_value(t, len(home.workspace.tabs), 1) {return}
	testing.expect_value(t, layout.pane_count(&home.workspace.tabs[0].tree), panes)
	testing.expect_value(t, linked.link_workspace, home.workspace.id)
	testing.expect(t, app.window_find(&state, linked.id) == linked && linked.link_shown)
	app.tick(&state)
}
