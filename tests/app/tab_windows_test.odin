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

// Presses tab `index` and holds it over `destination` at a point in that window's coordinates.
@(private = "file")
tab_drag_over_window :: proc(state: ^app.App, w, destination: ^app.Window, index: int, x, y: f32) {
	app.tab_press(state, w, index, 80, 20, false)
	_ = app.tab_drag_move(state, w, -30_000, -30_000)
	app.tab_drag_over(state, w, destination, x, y)
}

@(private = "file")
Across_Fixture :: struct {
	directory, path: string,
}

@(private = "file")
across_begin :: proc(t: ^testing.T, state: ^app.App) -> (fixture: Across_Fixture, ok: bool) {
	directory, directory_error := os.make_directory_temp("", "aio-tabs-across-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	fixture.directory = directory
	fixture.path = strings.concatenate({directory, "/settings.ini"})
	if !testing.expect_value(
		t,
		os.write_entire_file(fixture.path, idle_shell_settings(t, "cursor.blink = false\n")),
		nil,
	) {return}
	state.options = {data_dir = directory, inactive = true}
	state.app_id = fmt.aprintf("AIODev.Test.TabsAcross.%d", os.get_pid())
	init := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, init, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	return fixture, testing.expect(t, app.app_init(state))
}

@(private = "file")
across_end :: proc(t: ^testing.T, state: ^app.App, fixture: Across_Fixture) {
	app.app_destroy(state)
	os.remove(fixture.path)
	testing.expect_value(t, os.remove(fixture.directory), nil)
	delete(fixture.path)
	delete(fixture.directory)
}

// Tears a new tab off the first window, leaving two windows that each show one tab of their own workspace.
@(private = "file")
across_second_window :: proc(t: ^testing.T, state: ^app.App, first: ^app.Window) -> ^app.Window {
	if !testing.expect(t, app.tab_create(state, first.workspace)) {return nil}
	app.tab_select(state, first, 1)
	testing.expect(t, tab_drag_off_window(state, first, 1))
	second := app.window_find(state, first.tab_drag.preview_window)
	if !testing.expect(t, second != nil) {return nil}
	app.tab_drag_release(state, first)
	app.rename_finish(state, second, true)
	return second
}

@(test)
tabs_dragged_to_another_window_join_its_workspace :: proc(t: ^testing.T) {
	state: app.App
	fixture, ok := across_begin(t, &state)
	defer across_end(t, &state, fixture)
	if !ok {return}
	destination := state.windows[0]
	source := across_second_window(t, &state, destination)
	if source == nil {return}
	home, workspace := destination.workspace, source.workspace
	if !testing.expect(t, app.tab_create(&state, home)) {return}
	if !testing.expect(t, app.tab_create(&state, workspace)) {return}
	if !testing.expect(t, app.tab_create(&state, workspace)) {return}
	app.tab_select(&state, destination, 0)
	app.tab_select(&state, source, 0)
	app.pane_split(&state, source, .Right)
	first, second, third := workspace.tabs[0], workspace.tabs[1], workspace.tabs[2]
	kept_first, kept_second := home.tabs[0], home.tabs[1]
	first.name = strings.clone("Tools")
	content := first.tree.nodes[first.tree.focus].(layout.Pane).content
	session := app.session_find(&state, content.id).session
	pid := term.process_id(session)
	sessions, workspaces := len(state.sessions), len(state.workspaces)

	// The arriving group centres on the pointer, or lands after the tabs when it is away from them.
	testing.expect(t, destination.tabs_horizontal)
	bar := app.window_tab_bar(&state, destination)
	testing.expect_value(t, app.tab_drop_slot(&state, destination, 1, bar.x + bar.tab_width * 1.9, 10), 1)
	testing.expect_value(t, app.tab_drop_slot(&state, destination, 1, bar.x + bar.tab_width * 2.1, 10), 2)
	testing.expect_value(t, app.tab_drop_slot(&state, destination, 1, bar.x - 100, 10), 0)
	testing.expect_value(t, app.tab_drop_slot(&state, destination, 1, 40, bar.height + 40), 2)
	testing.expect_value(t, app.tab_drop_slot(&state, destination, 3, bar.x + bar.tab_width * 2, 10), 1)

	// Holding over the window opens a gap that follows the pointer, and nothing moves yet.
	tab_drag_over_window(&state, source, destination, 0, bar.x + bar.tab_width, 10)
	testing.expect_value(t, source.tab_drag.destination_window, destination.id)
	testing.expect_value(t, destination.tab_incoming.count, 1)
	testing.expect_value(t, destination.tab_incoming.slot, 1)
	// The strip shares its width with the arriving tab but does not count it as a tab.
	testing.expect_value(t, app.window_tab_bar(&state, destination).count, 2)
	testing.expect_value(t, len(home.tabs), 2)
	testing.expect_value(t, len(workspace.tabs), 3)
	app.tab_drag_over(&state, source, destination, bar.x + bar.tab_width * 2.5, 10)
	testing.expect_value(t, destination.tab_incoming.slot, 2)

	// Leaving the window closes the gap, and a cancel keeps both sides as they were.
	app.tab_drag_over(&state, source, nil, 0, 0)
	testing.expect_value(t, destination.tab_incoming.count, 0)
	testing.expect_value(t, source.tab_drag.destination_window, platform.Window_Id(0))
	app.tab_drag_over(&state, source, destination, bar.x, 10)
	app.tab_drag_cancel(&state, source)
	testing.expect_value(t, destination.tab_incoming.count, 0)
	testing.expect_value(t, len(workspace.tabs), 3)
	testing.expect(t, workspace.tabs[0] == first)

	// Allocation failure at the drop leaves both sides whole.
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	testing.expect(t, !app.tabs_to_workspace(&state, source, home, 1))
	context.allocator = allocator
	testing.expect_value(t, len(home.tabs), 2)
	testing.expect_value(t, len(workspace.tabs), 3)
	testing.expect_value(t, tab_pane_count(first), 2)

	// The drop carries every pane, the running shells and the name to the slot, and focuses the tab there.
	tab_drag_over_window(&state, source, destination, 0, bar.x + bar.tab_width, 10)
	app.tab_drag_release(&state, source)
	if !testing.expect_value(t, len(home.tabs), 3) {return}
	moved := home.tabs[1]
	testing.expect(t, home.tabs[0] == kept_first && home.tabs[2] == kept_second)
	testing.expect_value(t, moved.name, "Tools")
	testing.expect_value(t, tab_pane_count(moved), 2)
	testing.expect(t, layout.find_content(&moved.tree, content) != layout.INVALID_NODE)
	testing.expect_value(t, home.selected, 1)
	testing.expect(t, destination.tree == &moved.tree)
	testing.expect(t, moved.marked && !kept_first.marked && !kept_second.marked)
	testing.expect_value(t, home.selection_anchor, moved.id)
	testing.expect(t, moved.id != kept_first.id && moved.id != kept_second.id)
	testing.expect_value(t, len(destination.tab_positions), 3)
	testing.expect_value(t, len(destination.panes), 2)
	testing.expect_value(t, destination.tab_incoming.count, 0)
	testing.expect_value(t, len(state.sessions), sessions)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	// The source keeps the tabs that stayed and shows the nearest of them.
	testing.expect_value(t, len(workspace.tabs), 2)
	testing.expect(t, workspace.tabs[0] == second && workspace.tabs[1] == third)
	testing.expect(t, source.tree == &second.tree)
	testing.expect(t, second.marked)
	app.tick(&state)

	// A drop that takes the last tabs closes their window and deletes their workspace, with no shell stopping.
	// This group lands in a rail, in order, at the row under the pointer.
	destination.tabs_horizontal = false
	rail_show(destination)
	app.window_relayout(&state, destination)
	row := app.rail_row_rect_for_tab(destination, 0)
	app.tab_pointer_select(&state, source, 0, false, false)
	app.tab_pointer_select(&state, source, 1, true, false)
	content_second := second.tree.nodes[second.tree.focus].(layout.Pane).content
	content_third := third.tree.nodes[third.tree.focus].(layout.Pane).content
	source_id, workspace_id := source.id, workspace.id
	tab_drag_over_window(&state, source, destination, 1, row.x + 10, row.y + 1)
	testing.expect_value(t, destination.tab_incoming.count, 2)
	testing.expect_value(t, destination.tab_incoming.slot, 0)
	app.tab_drag_release(&state, source)
	testing.expect(t, app.window_find(&state, source_id) == nil)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, app.workspace_find(&state, workspace_id) == nil)
	testing.expect_value(t, len(state.workspaces), workspaces - 1)
	testing.expect_value(t, state.run, app.App_Run.Running)
	if !testing.expect_value(t, len(home.tabs), 5) {return}
	testing.expect(t, layout.find_content(&home.tabs[0].tree, content_second) != layout.INVALID_NODE)
	testing.expect(t, layout.find_content(&home.tabs[1].tree, content_third) != layout.INVALID_NODE)
	testing.expect(t, home.tabs[2] == kept_first && home.tabs[3] == moved && home.tabs[4] == kept_second)
	testing.expect_value(t, len(state.sessions), sessions)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	testing.expect(t, app.selected_tab(home) == home.tabs[1])
	testing.expect(t, destination.tree == &home.tabs[1].tree)
	app.tick(&state)
}

// Holds a press on tab `index` over row `row` of w's dropdown, returning false if the dropdown did not open.
@(private = "file")
tab_drag_to_row :: proc(state: ^app.App, source, w: ^app.Window, index, row: int) -> bool {
	app.tab_press(state, source, index, 80, 20, false)
	_ = app.tab_drag_move(state, source, -30_000, -30_000)
	chip := app.workspace_button_rect(w)
	if !app.tab_workspace_drag_move(state, source, w, chip.x + 4, chip.y + 4) {return false}
	r := app.workspace_picker_row_rect(w, row)
	return app.tab_workspace_drag_move(state, source, w, r.x + 4, r.y + r.height / 2)
}

// The dropdown takes a tab drag as it does a pane drag: its rows are the other workspaces, then new ones.
@(test)
tabs_dragged_onto_the_workspace_dropdown :: proc(t: ^testing.T) {
	state: app.App
	fixture, ok := across_begin(t, &state)
	defer across_end(t, &state, fixture)
	if !ok {return}
	shown_elsewhere := state.windows[0]
	source := across_second_window(t, &state, shown_elsewhere)
	if source == nil {return}
	home, workspace := shown_elsewhere.workspace, source.workspace
	unshown := app.workspace_create_empty(&state)
	if !testing.expect(t, unshown != nil && app.tab_create(&state, unshown)) {return}
	for _ in 0 ..< 4 {if !testing.expect(t, app.tab_create(&state, workspace)) {return}}
	app.tab_select(&state, source, 0)
	sessions, workspaces := len(state.sessions), len(state.workspaces)
	// The rows leave out the drag's own workspace, so the other two keep these places.
	home_row, unshown_row := 0, 1

	// Hovering the chip opens the dropdown, and leaving it closes it.
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, home_row)) {return}
	p := &source.workspace_picker
	move, _ := app.workspace_picker_move(p)
	testing.expect(t, app.workspace_picker_held(p) && move.request.whole_tab)
	testing.expect_value(t, source.tab_drag.picker_window, source.id)
	if !testing.expect_value(t, len(p.rows), 2) {return}
	testing.expect_value(t, p.rows[home_row].id, home.id)
	testing.expect_value(t, p.rows[unshown_row].id, unshown.id)
	testing.expect_value(t, source.tab_drag.picker_hit, home_row)
	testing.expect(t, !app.tab_workspace_drag_move(&state, source, source, 5, f32(source.height) - 5))
	testing.expect(t, !app.workspace_picker_held(p))
	testing.expect_value(t, source.tab_drag.picker_window, platform.Window_Id(0))
	app.tab_drag_cancel(&state, source)

	// A cancel from the dropdown closes it and moves nothing, as does a drop between rows.
	testing.expect(t, tab_drag_to_row(&state, source, source, 0, 0))
	app.tab_drag_cancel(&state, source)
	testing.expect(t, !app.workspace_picker_held(p))
	testing.expect_value(t, len(workspace.tabs), 5)
	// Escape ends the whole drag, not just the dropdown, restoring any order it had changed.
	first_tab := workspace.tabs[0]
	testing.expect(t, tab_drag_to_row(&state, source, source, 0, 0))
	app.tab_move(&state, source, 0, 1)
	app.handle_event(&state, platform.Key_Event{window = source.id, key = .Escape, pressed = true})
	testing.expect(t, !app.workspace_picker_held(p) && !source.tab_drag.pressed)
	testing.expect(t, workspace.tabs[0] == first_tab)
	app.handle_event(&state, platform.Key_Event{window = source.id, key = .Escape})
	testing.expect(t, tab_drag_to_row(&state, source, source, 0, 0))
	source.tab_drag.picker_hit = -1
	app.tab_drag_release(&state, source)
	testing.expect_value(t, len(workspace.tabs), 5)

	// A workspace in another window gains the tab there, and the source stays as it was.
	moved_content := app.selected_tab(workspace).tree.nodes[0].(layout.Pane).content
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, home_row)) {return}
	app.tab_drag_release(&state, source)
	testing.expect(t, !app.workspace_picker_held(p))
	testing.expect_value(t, len(workspace.tabs), 4)
	testing.expect(t, source.workspace == workspace)
	testing.expect_value(t, len(home.tabs), 2)
	testing.expect(t, layout.find_content(&app.selected_tab(home).tree, moved_content) != layout.INVALID_NODE)
	testing.expect(t, shown_elsewhere.tree == &app.selected_tab(home).tree)
	testing.expect_value(t, len(state.windows), 2)

	// The dropdown of another window works the same way.
	testing.expect(t, tab_drag_to_row(&state, source, shown_elsewhere, 0, 0))
	testing.expect_value(t, source.tab_drag.picker_window, shown_elsewhere.id)
	testing.expect(t, app.workspace_picker_held(&shown_elsewhere.workspace_picker))
	app.tab_drag_cancel(&state, source)
	testing.expect(t, !app.workspace_picker_held(&shown_elsewhere.workspace_picker))

	// A workspace no window shows comes to this window, as for a pane, and the old one waits with its tabs.
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, unshown_row)) {return}
	app.tab_drag_release(&state, source)
	testing.expect(t, source.workspace == unshown)
	testing.expect_value(t, len(unshown.tabs), 2)
	testing.expect_value(t, unshown.selected, 1)
	testing.expect_value(t, len(workspace.tabs), 3)
	testing.expect(t, app.workspace_find(&state, workspace.id) == workspace)
	app.tick(&state)
	if !testing.expect(t, app.workspace_select(&state, source, workspace)) {return}
	app.tab_select(&state, source, 0)

	// The row after the workspaces opens a new one, which starts naming itself in its chip.
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, 2)) {return}
	testing.expect_value(t, source.tab_drag.picker_hit, 2)
	app.tab_drag_release(&state, source)
	named := source.workspace
	testing.expect(t, named != workspace)
	testing.expect_value(t, len(named.tabs), 1)
	testing.expect(t, app.rename_shown(source))
	app.rename_finish(&state, source, true)
	testing.expect_value(t, len(state.workspaces), workspaces + 1)
	if !testing.expect(t, app.workspace_select(&state, source, workspace)) {return}
	testing.expect_value(t, len(workspace.tabs), 2)

	// The last row opens a window, only while a tab stays behind.
	app.tab_select(&state, source, 0)
	new_window_row := len(state.workspaces) - 1 + 1
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, new_window_row)) {return}
	testing.expect_value(t, source.tab_drag.picker_hit, new_window_row)
	app.tab_drag_release(&state, source)
	testing.expect_value(t, len(state.windows), 3)
	testing.expect_value(t, len(workspace.tabs), 1)
	for window in state.windows {if app.rename_shown(window) {app.rename_finish(&state, window, true)}}
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, new_window_row + 1)) {return}
	testing.expect_value(t, source.tab_drag.picker_hit, -1)
	app.tab_drag_release(&state, source)
	testing.expect_value(t, len(state.windows), 3)
	testing.expect_value(t, len(workspace.tabs), 1)

	// The last tab into a workspace with its own window closes this one and deletes its workspace.
	source_id, workspace_id := source.id, workspace.id
	if !testing.expect(t, tab_drag_to_row(&state, source, source, 0, home_row)) {return}
	app.tab_drag_release(&state, source)
	testing.expect(t, app.window_find(&state, source_id) == nil)
	testing.expect(t, app.workspace_find(&state, workspace_id) == nil)
	testing.expect_value(t, len(home.tabs), 3)
	testing.expect_value(t, state.run, app.App_Run.Running)
	testing.expect_value(t, len(state.sessions), sessions)
	app.tick(&state)
}

// With no other window showing the destination, the last tab's window takes the workspace over and stays.
@(test)
last_tab_dropped_on_an_unshown_workspace_keeps_its_window :: proc(t: ^testing.T) {
	state: app.App
	fixture, ok := across_begin(t, &state)
	defer across_end(t, &state, fixture)
	if !ok {return}
	w := state.windows[0]
	workspace := w.workspace
	if !testing.expect(t, app.tab_create(&state, workspace)) {return}
	unshown := app.workspace_create_empty(&state)
	if !testing.expect(t, unshown != nil && app.tab_create(&state, unshown)) {return}
	// A group too, so the emptied tabs have nothing to show while they leave.
	app.tab_pointer_select(&state, w, 0, false, false)
	app.tab_pointer_select(&state, w, 1, true, false)
	workspace_id, sessions := workspace.id, len(state.sessions)
	if !testing.expect(t, tab_drag_to_row(&state, w, w, 0, 0)) {return}
	app.tab_drag_release(&state, w)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, w.workspace == unshown)
	testing.expect(t, app.workspace_find(&state, workspace_id) == nil)
	testing.expect_value(t, len(unshown.tabs), 3)
	testing.expect_value(t, len(state.sessions), sessions)
	testing.expect(t, w.tree == &app.selected_tab(unshown).tree)
	testing.expect_value(t, state.run, app.App_Run.Running)
	app.tick(&state)
}

// Closing the destination cancels a drag held over it rather than leaving it pointing at nothing.
@(test)
closing_the_destination_cancels_a_tab_drag :: proc(t: ^testing.T) {
	state: app.App
	fixture, ok := across_begin(t, &state)
	defer across_end(t, &state, fixture)
	if !ok {return}
	destination := state.windows[0]
	source := across_second_window(t, &state, destination)
	if source == nil {return}
	tab_drag_over_window(&state, source, destination, 0, 0, 10)
	testing.expect(t, source.tab_drag.pressed)
	app.window_close(&state, destination)
	testing.expect(t, !source.tab_drag.pressed)
	testing.expect_value(t, len(source.workspace.tabs), 1)
	app.tick(&state)
}

// The app keeps one settings tab: opening it again from anywhere focuses that tab, wherever it has gone.
@(test)
settings_opens_once_and_focuses_the_existing_tab :: proc(t: ^testing.T) {
	state: app.App
	fixture, ok := across_begin(t, &state)
	defer across_end(t, &state, fixture)
	if !ok {return}
	first := state.windows[0]
	second := across_second_window(t, &state, first)
	if second == nil {return}
	home, other := first.workspace, second.workspace

	testing.expect(t, app.editor_open(&state, first) == first)
	settings_index := app.settings_tab_index(home)
	if !testing.expect(t, settings_index >= 0) {return}
	tabs, other_tabs := len(home.tabs), len(other.tabs)

	// From another window: no new tab there, and the tab's own window shows it.
	app.tab_select(&state, first, settings_index == 0 ? 1 : 0)
	testing.expect(t, !app.settings_active(first))
	testing.expect(t, app.editor_open(&state, second) == first)
	testing.expect_value(t, len(other.tabs), other_tabs)
	testing.expect_value(t, len(home.tabs), tabs)
	testing.expect_value(t, home.selected, settings_index)
	testing.expect(t, app.settings_active(first))
	testing.expect(t, !app.settings_active(second))

	// A reveal reaches the page in the window showing it.
	app.settings_reveal(&state, second, {key = "font.size", search = .Clear})
	testing.expect_value(t, ui.editor_row(&first.editor).key, "font.size")
	testing.expect(t, !ui.editor_loaded(&second.editor))

	// The tab can be dragged to another window, and the page goes with it.
	tab_drag_over_window(&state, first, second, settings_index, 0, 10)
	app.tab_drag_release(&state, first)
	testing.expect_value(t, app.settings_tab_index(home), -1)
	testing.expect(t, app.settings_tab_index(other) >= 0)
	testing.expect(t, ui.editor_loaded(&second.editor) && !ui.editor_loaded(&first.editor))
	testing.expect(t, app.editor_open(&state, first) == second)
	testing.expect_value(t, len(other.tabs), other_tabs + 1)
	testing.expect_value(t, app.settings_tab_index(home), -1)

	// With no window showing its workspace, the window asking takes the workspace over.
	app.window_close(&state, second)
	testing.expect(t, app.editor_open(&state, first) == first)
	testing.expect(t, first.workspace == other)
	testing.expect(t, app.settings_active(first))
	testing.expect_value(t, len(other.tabs), other_tabs + 1)
	app.tick(&state)
}

// A linked window belongs to its tab, so it outlives the window the tab left.
@(test)
linked_window_follows_a_tab_whose_window_closes :: proc(t: ^testing.T) {
	state: app.App
	fixture, ok := across_begin(t, &state)
	defer across_end(t, &state, fixture)
	if !ok {return}
	destination := state.windows[0]
	source := across_second_window(t, &state, destination)
	if source == nil {return}
	app.pane_split(&state, source, .Right)
	app.pane_link_toggle(&state, source)
	linked: ^app.Window
	for window in state.windows {if app.window_linked(window) {linked = window}}
	if !testing.expect(t, linked != nil) {return}
	source_id, workspace_id := source.id, source.workspace.id
	tab_drag_over_window(&state, source, destination, 0, 0, 10)
	app.tab_drag_release(&state, source)
	app.pane_links_sync(&state)
	testing.expect(t, app.window_find(&state, source_id) == nil)
	testing.expect(t, app.workspace_find(&state, workspace_id) == nil)
	testing.expect(t, app.window_find(&state, linked.id) == linked && linked.phase == .Shown)
	testing.expect_value(t, app.window_link_workspace(linked), destination.workspace.id)
	app.tick(&state)
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
	testing.expect(t, preview.phase == .Preparing && preview.workspace.provisional)
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
	testing.expect(t, preview.phase == .Preparing)
	testing.expect_value(t, tab_pane_count(first), 2)
	testing.expect_value(t, len(workspace.tabs), 3)
	app.tab_drag_cancel(&state, source)

	// The drop carries every pane, the running sessions and the tab's name, then names the window.
	testing.expect(t, tab_drag_off_window(&state, source, 0))
	preview = app.window_find(&state, source.tab_drag.preview_window)
	if !testing.expect(t, preview != nil) {return}
	app.tab_drag_release(&state, source)
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, preview.phase == .Shown && !preview.workspace.provisional)
	testing.expect(t, preview.workspace.name != "")
	testing.expect(t, app.chip_name_shown(preview))
	testing.expect(t, !app.rename_shown(source))
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
	for window in state.windows {if app.window_linked(window) {linked = window}}
	if !testing.expect(t, linked != nil) {return}
	testing.expect_value(t, app.window_link_workspace(linked), group.workspace.id)
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
	testing.expect_value(t, app.window_link_workspace(linked), home.workspace.id)
	testing.expect(t, app.window_find(&state, linked.id) == linked && linked.phase == .Shown)
	app.tick(&state)
}
