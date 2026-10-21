package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:control"
import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:term_view"
import "aio:ui"

@(private="file")
Cleanup_Fixture :: struct { state: app.App, source, destination: ^app.Window }

@(private="file")
cleanup_tab :: proc(t: ^testing.T, workspace: ^app.Workspace, content: layout.Content) -> ^app.Tab {
	tab := new(app.Tab)
	if !testing.expect_value(t, layout.init(&tab.tree, content), nil) { free(tab); return nil }
	workspace.next_tab_id += 1
	tab.id = workspace.next_tab_id
	append(&workspace.tabs, tab)
	return tab
}

@(private="file")
cleanup_fixture_init :: proc(t: ^testing.T, f: ^Cleanup_Fixture) -> bool {
	state := &f.state
	state.app_id = fmt.aprintf("AIODev.Test.PaneCleanup.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return false
	}
	state.platform_ready = true
	ui.notices_init(&state.notices)
	for index in 0 ..< 2 {
		workspace := app.workspace_create_empty(state)
		if !testing.expect(t, workspace != nil) { return false }
		tab := cleanup_tab(t, workspace, {.Terminal, u32(index+1)})
		if tab == nil { return false }
		id, err := platform.window_create(&state.platform, {hidden = true, width = 320, height = 200})
		if !testing.expect_value(t, err, platform.Error.None) { return false }
		w := new(app.Window)
		w.id, w.workspace, w.tree = id, workspace, &tab.tree
		append(&state.windows, w)
		view: term_view.View
		if !testing.expect(t, term_view.create(&view)) { return false }
		append(&w.views, app.Pane_View{content = {.Terminal, u32(index+1)}, view = view,
			cache = render.draw_list_init()})
		if index == 0 { f.source = w } else { f.destination = w }
	}
	return true
}

@(private="file")
cleanup_fixture_destroy :: proc(t: ^testing.T, f: ^Cleanup_Fixture) {
	state := &f.state
	for len(state.windows) > 0 { app.window_close(state, state.windows[len(state.windows)-1]) }
	delete(state.windows)
	for entry in state.sessions { term.destroy(entry.session) }
	delete(state.sessions)
	for workspace in state.workspaces { app.workspace_destroy(workspace) }
	delete(state.workspaces)
	ui.notices_destroy(&state.notices)
	if state.platform_ready { testing.expect_value(t, platform.destroy(&state.platform), platform.Error.None) }
	delete(state.app_id)
}

@(test)
pane_cleanup_committed_final_pane_removes_source_registry_and_view :: proc(t: ^testing.T) {
	for scenario in 0 ..< 4 {
		f: Cleanup_Fixture
		defer cleanup_fixture_destroy(t, &f)
		if !cleanup_fixture_init(t, &f) { return }
		state := &f.state
		source, destination := app.selected_tab(f.source.workspace), app.selected_tab(f.destination.workspace)
		source_id, window_id := f.source.workspace.id, f.source.id
		if scenario >= 2 { app.window_close(state, f.source) }
		destination_workspace, destination_tree := f.destination.workspace, f.destination.tree
		app.workspace_picker_open(state, f.destination)
		when app.AIO_CONTROL {
			state.verify.target_window, state.verify.mouse_window = window_id, window_id
			state.verify.buttons = {.Left}
		}
		if scenario%2 == 1 {
			if !testing.expect(t, app.pane_to_tab(state, f.destination, source, source.tree.root)) { return }
		} else {
			if !testing.expect(t, app.pane_transfer(state, f.destination, source, destination,
				source.tree.root, destination.tree.root, .Right, false)) { return }
		}
		testing.expect(t, app.workspace_find(state, source_id) == nil)
		testing.expect(t, app.window_find(state, window_id) == nil)
		testing.expect_value(t, len(state.workspaces), 1)
		testing.expect_value(t, len(state.windows), 1)
		testing.expect(t, f.destination.workspace == destination_workspace)
		testing.expect(t, app.window_for_workspace(state, destination_workspace) == f.destination)
		testing.expect(t, &destination.tree == destination_tree)
		testing.expect_value(t, destination_workspace.tabs[0].id, u32(1))
		app.workspace_picker_open(state, f.destination)
		for row in f.destination.workspace_picker.rows { testing.expect(t, row.id != source_id) }
		testing.expect(t, app.workspace_index(state, 0) == destination_workspace)
		testing.expect(t, app.workspace_index(state, 1) == nil)
		when app.AIO_CONTROL {
			testing.expect_value(t, app.verify_drive(state, control.Window_Select{u64(window_id)}),
				control.Error.Invalid_Argument)
			testing.expect(t, app.verify_window(state) == f.destination)
			testing.expect_value(t, state.verify.target_window, platform.Window_Id(0))
			testing.expect_value(t, state.verify.mouse_window, platform.Window_Id(0))
			testing.expect(t, state.verify.buttons == {})
		}
		testing.expect(t, !state.tray_hint_shown)
		fresh := app.workspace_create_empty(state)
		if !testing.expect(t, fresh != nil) { return }
		testing.expect_value(t, fresh.id, u32(3))
		testing.expect_value(t, fresh.name, "Workspace 3")
	}
}

@(test)
pane_cleanup_drag_release_returns_after_source_view_is_freed :: proc(t: ^testing.T) {
	for to_tab in ([?]bool{false, true}) {
		f: Cleanup_Fixture
		defer cleanup_fixture_destroy(t, &f)
		if !cleanup_fixture_init(t, &f) { return }
		state := &f.state
		source, destination := app.selected_tab(f.source.workspace), app.selected_tab(f.destination.workspace)
		id, window_id := f.source.workspace.id, f.source.id
		f.source.pane_drag = {pressed = true, active = true, shown = true, new_tab = to_tab,
			source = source, destination = destination, node = source.tree.root,
			target = destination.tree.root, destination_window = f.destination.id, direction = .Right}
		if !testing.expect(t, app.pane_drag_release(state, f.source)) { return }
		testing.expect(t, app.window_find(state, window_id) == nil)
		testing.expect(t, app.workspace_find(state, id) == nil)
		testing.expect_value(t, len(state.workspaces), 1)
		testing.expect_value(t, len(state.windows), 1)
	}
}

@(test)
pane_cleanup_refreshes_another_windows_open_picker :: proc(t: ^testing.T) {
	f: Cleanup_Fixture
	defer cleanup_fixture_destroy(t, &f)
	if !cleanup_fixture_init(t, &f) { return }
	state := &f.state
	workspace := app.workspace_create_empty(state)
	if !testing.expect(t, workspace != nil) { return }
	tab := cleanup_tab(t, workspace, {.Terminal, 3})
	if tab == nil { return }
	id, err := platform.window_create(&state.platform, {hidden = true, width = 320, height = 200})
	if !testing.expect_value(t, err, platform.Error.None) { return }
	observer := new(app.Window)
	observer.id, observer.workspace, observer.tree = id, workspace, &tab.tree
	append(&state.windows, observer)
	app.workspace_picker_open(state, observer)
	testing.expect_value(t, len(observer.workspace_picker.rows), 3)
	source_id := f.source.workspace.id
	source, destination := app.selected_tab(f.source.workspace), app.selected_tab(f.destination.workspace)
	if !testing.expect(t, app.pane_transfer(state, f.destination, source, destination,
		source.tree.root, destination.tree.root, .Right, false)) { return }
	testing.expect(t, observer.workspace_picker.open)
	testing.expect_value(t, len(observer.workspace_picker.rows), 2)
	for row in observer.workspace_picker.rows { testing.expect(t, row.id != source_id) }
	testing.expect(t, observer.workspace_picker.selected >= 0 && observer.workspace_picker.selected < 2)
}

@(test)
pane_cleanup_other_tabs_settings_and_split_panes_keep_source :: proc(t: ^testing.T) {
	for remaining in 0 ..< 3 {
		for to_tab in ([?]bool{false, true}) {
			f: Cleanup_Fixture
			defer cleanup_fixture_destroy(t, &f)
			if !cleanup_fixture_init(t, &f) { return }
			state := &f.state
			workspace := f.source.workspace
			source, destination := app.selected_tab(workspace), app.selected_tab(f.destination.workspace)
			node := source.tree.root
			switch remaining {
			case 0: if cleanup_tab(t, workspace, {.Terminal, 3}) == nil { return }
			case 1: if cleanup_tab(t, workspace, {.Settings, 0}) == nil { return }
			case 2:
				_, err := layout.split_direction(&source.tree, node, .Right, 0.5, {.Terminal, 3})
				if !testing.expect_value(t, err, nil) { return }
			}
			if to_tab {
				if !testing.expect(t, app.pane_to_tab(state, f.destination, source, node)) { return }
			} else {
				if !testing.expect(t, app.pane_transfer(state, f.destination, source, destination,
					node, destination.tree.root, .Right, false)) { return }
			}
			testing.expect(t, app.workspace_find(state, workspace.id) == workspace)
			testing.expect(t, app.window_for_workspace(state, workspace) == f.source)
			testing.expect(t, f.source.tree == &app.selected_tab(workspace).tree)
			testing.expect_value(t, len(state.workspaces), 2)
			testing.expect_value(t, len(state.windows), 2)
		}
	}
}

@(test)
pane_cleanup_failure_cancel_stale_and_same_workspace_preserve_source :: proc(t: ^testing.T) {
	f: Cleanup_Fixture
	defer cleanup_fixture_destroy(t, &f)
	if !cleanup_fixture_init(t, &f) { return }
	state := &f.state
	workspace := f.source.workspace
	source, destination := app.selected_tab(workspace), app.selected_tab(f.destination.workspace)
	node, target := source.tree.root, destination.tree.root
	app.pane_drag_press(state, f.source, node, 0, 0)
	f.source.pane_drag.active = true
	app.pane_drag_cancel(state, f.source)
	testing.expect(t, !app.pane_drag_release(state, f.source))
	testing.expect(t, !app.pane_transfer(state, f.destination, source, destination,
		layout.INVALID_NODE, target, .Right, false))
	stale: app.Tab
	testing.expect(t, !app.pane_transfer(state, f.destination, &stale, destination, node, target, .Right, false))
	testing.expect(t, !app.pane_to_tab(state, f.destination, &stale, node))
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.pane_to_tab(state, f.destination, source, node)
	context.allocator = allocator
	testing.expect(t, !failed)
	for len(destination.tree.nodes)+2 <= cap(destination.tree.nodes) {
		append(&destination.tree.nodes, layout.Vacant{})
	}
	destination.tree.nodes.allocator = runtime.nil_allocator()
	failed = app.pane_transfer(state, f.destination, source, destination, node, target, .Right, false)
	destination.tree.nodes.allocator = allocator
	testing.expect(t, !failed)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, destination.tree.root, target)
	testing.expect_value(t, len(state.workspaces), 2)
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, app.pane_to_tab(state, f.source, source, node))
	testing.expect_value(t, len(workspace.tabs), 1)
	other := cleanup_tab(t, workspace, {.Terminal, 3})
	if other == nil { return }
	if !testing.expect(t, app.pane_transfer(state, f.source, source, other,
		node, other.tree.root, .Right, false)) { return }
	testing.expect(t, app.workspace_find(state, workspace.id) == workspace)
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect(t, app.pane_to_tab(state, f.source, other, other.tree.focus))
	testing.expect_value(t, len(workspace.tabs), 2)
	testing.expect(t, app.workspace_find(state, workspace.id) == workspace)
}

@(test)
pane_cleanup_moved_and_destination_runtime_pids_survive :: proc(t: ^testing.T) {
	f: Cleanup_Fixture
	defer cleanup_fixture_destroy(t, &f)
	if !cleanup_fixture_init(t, &f) { return }
	state := &f.state
	for id: u32 = 1; id <= 2; id += 1 {
		session, err := term.create({
			command_line = "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe -NoLogo -NoProfile",
			working_directory = "C:\\Windows\\System32",
			geometry = {columns = 40, rows = 12, cell_width = 8, cell_height = 16,
				surface_width = 320, surface_height = 192}}, {})
		if !testing.expect_value(t, err, term.Error.None) { return }
		append(&state.sessions, app.Session_Entry{id = id, session = session})
	}
	deadline := time.tick_add(time.tick_now(), 10*time.Second)
	for term.process_id(state.sessions[0].session) == 0 || term.process_id(state.sessions[1].session) == 0 {
		for entry in state.sessions {
			status := term.status(entry.session)
			if !testing.expectf(t, status.kind == .Running, "session startup: %v %s", status.kind, status.message) {
				return
			}
		}
		if !testing.expect(t, time.tick_diff(time.tick_now(), deadline) > 0) { return }
		time.sleep(time.Millisecond)
	}
	moved, destination_session := state.sessions[0].session, state.sessions[1].session
	pids := [?]u32{term.process_id(moved), term.process_id(destination_session)}
	source, destination := app.selected_tab(f.source.workspace), app.selected_tab(f.destination.workspace)
	id := f.source.workspace.id
	if !testing.expect(t, app.pane_transfer(state, f.destination, source, destination,
		source.tree.root, destination.tree.root, .Right, false)) { return }
	testing.expect(t, app.workspace_find(state, id) == nil)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect(t, state.sessions[0].session == moved && state.sessions[1].session == destination_session)
	for entry, i in state.sessions {
		testing.expect_value(t, term.process_id(entry.session), pids[i])
		testing.expect_value(t, term.status(entry.session).kind, term.Status_Kind.Running)
	}
}
