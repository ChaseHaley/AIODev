package app_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:term"
import "aio:ui"
import win32 "core:sys/windows"

@(private="file")
Delete_Fixture :: struct { state: app.App, directory, path: string }

@(test)
last_tab_group_removes_workspace_and_reuses_window_then_last_pane_exits :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) {return}
	state := &f.state
	w := state.windows[0]
	window_id := w.id
	fallback := w.workspace
	survivor := state.sessions[0].session
	survivor_pid := term.process_id(survivor)
	app.workspace_new(state, w, false)
	closed_id := w.workspace.id
	process := delete_process_handle(t, app.focused_session(state, w).session)
	defer if process != nil {testing.expect(t, bool(win32.CloseHandle(process)))}
	app.tab_new(state, w)
	for tab in w.workspace.tabs {tab.marked = true}
	app.tab_close(state, w, w.workspace.selected)
	testing.expect(t, app.workspace_find(state, closed_id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect(t, state.windows[0] == w && w.id == window_id && w.workspace == fallback)
	testing.expect_value(t, w.tree, &app.selected_tab(fallback).tree)
	testing.expect_value(t, term.process_id(survivor), survivor_pid)
	testing.expect_value(t, win32.WaitForSingleObject(process, 1000), win32.WAIT_OBJECT_0)
	testing.expect(t, state.running && !state.tray_hint_shown)
	app.tick(state)
	app.pane_close(state, w)
	testing.expect(t, !state.running)
	testing.expect_value(t, len(state.workspaces), 0)
	testing.expect_value(t, len(state.windows), 0)
	testing.expect_value(t, len(state.sessions), 0)
	// Already-queued open events must not resurrect work or index an empty registry during shutdown.
	app.handle_event(state, platform.Activate_Request_Event{})
	app.handle_event(state, platform.Tray_Event{})
	testing.expect(t, !state.running)
	testing.expect_value(t, len(state.workspaces), 0)
	testing.expect_value(t, len(state.windows), 0)
}

@(test)
last_tab_reuses_existing_workspace_owner_without_creating_a_replacement :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) {return}
	state := &f.state
	one := state.windows[0]
	workspace := one.workspace
	survivor := state.sessions[0].session
	survivor_pid := term.process_id(survivor)
	app.workspace_new(state, one, true)
	two := state.windows[1]
	closed_id := two.workspace.id
	app.tab_close(state, two, 0)
	testing.expect(t, app.workspace_find(state, closed_id) == nil)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect(t, state.windows[0] == one && one.workspace == workspace && state.running)
	testing.expect_value(t, term.process_id(survivor), survivor_pid)
	testing.expect(t, !state.tray_hint_shown)
}

@(test)
last_settings_tab_closes_the_app_after_split_close_confirmation :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) {return}
	state := &f.state
	w := state.windows[0]
	app.pane_split(state, w, .Right)
	app.tab_close_request(state, w, 0)
	testing.expect(t, w.pending_close.confirm.open)
	delete_key(state, w, .Escape)
	testing.expect(t, state.running && len(w.workspace.tabs) == 1)
	app.run_action(state, w, .Settings_UI)
	app.tab_close(state, w, 0)
	testing.expect_value(t, len(state.sessions), 0)
	testing.expect(t, state.running && len(w.workspace.tabs) == 1)
	app.tab_close_request(state, w, 0)
	testing.expect(t, !state.running)
	testing.expect_value(t, len(state.workspaces), 0)
	testing.expect_value(t, len(state.windows), 0)
}

@(private="file")
delete_fixture_init :: proc(t: ^testing.T, f: ^Delete_Fixture) -> bool {
	var_error: os.Error
	f.directory, var_error = os.make_directory_temp("", "aio-delete-*", context.allocator)
	if !testing.expect_value(t, var_error, nil) { return false }
	f.path = strings.concatenate({f.directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"), nil) { return false }
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Delete.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private="file")
delete_fixture_destroy :: proc(t: ^testing.T, f: ^Delete_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" { testing.expect_value(t, os.remove(f.path), nil); delete(f.path) }
	if f.directory != "" { testing.expect_value(t, os.remove(f.directory), nil); delete(f.directory) }
}

@(private="file")
delete_key :: proc(state: ^app.App, w: ^app.Window, key: input.Key) {
	app.handle_event(state, platform.Key_Event{window = w.id, key = key, pressed = true})
}

@(private="file")
delete_process_handle :: proc(t: ^testing.T, session: ^term.Session) -> win32.HANDLE {
	pid := term.process_id(session)
	testing.expect(t, pid != 0)
	handle := win32.OpenProcess(win32.SYNCHRONIZE, false, pid)
	testing.expect(t, handle != nil)
	return handle
}

@(test)
workspace_delete_cancel_and_last_replacement_preserve_window :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	workspace := w.workspace
	id, window_id := workspace.id, w.id
	session := state.sessions[0].session
	process := delete_process_handle(t, session)
	defer if process != nil { testing.expect(t, bool(win32.CloseHandle(process))) }
	app.pane_split(state, w, .Right)
	app.tab_new(state, w)
	app.run_action(state, w, .Settings_UI)
	testing.expect_value(t, len(state.sessions), 3)
	processes: [2]win32.HANDLE
	for entry, i in state.sessions[1:] { processes[i] = delete_process_handle(t, entry.session) }
	defer for handle in processes { if handle != nil { testing.expect(t, bool(win32.CloseHandle(handle))) } }
	for cancel in ([?]int{0, 1, 2, 3}) {
		app.workspace_delete_request(state, w, workspace)
		testing.expect(t, w.pending_close.confirm.open && !app.workspace_picker_active(&w.workspace_picker))
		text := app.pending_close_text(state, &w.pending_close, w.workspace)
		testing.expect(t, strings.contains(text.title, workspace.name))
		testing.expect_value(t, text.body, "Close 3 tabs (4 panes); stop 3 sessions.")
		switch cancel {
		case 0: delete_key(state, w, .Escape)
		case 1: delete_key(state, w, .Tab); delete_key(state, w, .Enter)
		case 2:
			l := ui.confirm_layout(f32(w.width), f32(w.height), w.scale, true)
			x, y := i32(l.cancel.x+l.cancel.width/2), i32(l.cancel.y+l.cancel.height/2)
			app.handle_event(state, platform.Mouse_Button_Event{window = w.id, button = .Left,
				pressed = true, x = x, y = y})
			app.handle_event(state, platform.Mouse_Button_Event{window = w.id, button = .Left, x = x, y = y})
		case 3:
			app.handle_event(state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true})
		}
		testing.expect(t, !w.pending_close.confirm.open && w.workspace == workspace)
		testing.expect_value(t, len(workspace.tabs), 3)
		testing.expect_value(t, len(state.sessions), 3)
		testing.expect_value(t, win32.WaitForSingleObject(process, 0), win32.WAIT_TIMEOUT)
	}
	app.workspace_delete_request(state, w, workspace)
	delete_key(state, w, .Enter)
	testing.expect(t, app.workspace_find(state, id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, state.windows[0] == w && w.id == window_id)
	testing.expect(t, w.workspace.id > id && w.tree == &app.selected_tab(w.workspace).tree)
	testing.expect_value(t, len(w.workspace.tabs), 1)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect(t, !w.editor.open && !w.tab_menu.open && !w.pending_close.confirm.open)
	testing.expect_value(t, win32.WaitForSingleObject(process, 1000), win32.WAIT_OBJECT_0)
	for handle in processes { testing.expect_value(t, win32.WaitForSingleObject(handle, 1000), win32.WAIT_OBJECT_0) }
	app.tick(state)
}

@(test)
workspace_delete_hidden_and_foreign_owner_leave_unrelated_runtimes :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) { return }
	state := &f.state
	one := state.windows[0]
	hidden := one.workspace
	hidden_id := hidden.id
	hidden_process := delete_process_handle(t, state.sessions[0].session)
	defer if hidden_process != nil { testing.expect(t, bool(win32.CloseHandle(hidden_process))) }
	app.workspace_new(state, one, false)
	current := one.workspace
	current_session := app.focused_session(state, one).session
	current_pid := term.process_id(current_session)
	app.workspace_new(state, one, true)
	two := state.windows[1]
	displayed := two.workspace
	foreign_id := displayed.id
	foreign_process := delete_process_handle(t, app.focused_session(state, two).session)
	defer if foreign_process != nil { testing.expect(t, bool(win32.CloseHandle(foreign_process))) }
	app.workspace_picker_open(state, two)
	app.workspace_delete_request(state, one, hidden)
	delete_key(state, one, .Space)
	testing.expect(t, app.workspace_find(state, hidden_id) == nil)
	testing.expect(t, one.workspace == current && two.workspace == displayed)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(current_session), current_pid)
	testing.expect_value(t, win32.WaitForSingleObject(hidden_process, 1000), win32.WAIT_OBJECT_0)
	for row in two.workspace_picker.rows { testing.expect(t, row.id != hidden_id) }
	// All remaining alternatives have owners, so only the target window gets a fresh workspace.
	app.workspace_delete_request(state, one, displayed)
	delete_key(state, one, .Enter)
	testing.expect(t, app.workspace_find(state, foreign_id) == nil)
	testing.expect(t, one.workspace == current && two.workspace != current)
	testing.expect(t, !app.workspace_picker_active(&two.workspace_picker))
	testing.expect_value(t, len(state.windows), 2)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(current_session), current_pid)
	testing.expect_value(t, win32.WaitForSingleObject(foreign_process, 1000), win32.WAIT_OBJECT_0)
	app.window_close(state, two)
	testing.expect_value(t, len(state.sessions), 2)
	app.tick(state)
}

@(test)
workspace_delete_destination_failure_and_changed_ownership_reconfirm :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	destination := w.workspace
	context.logger = log.nil_logger()
	app.run_action(state, w, .Settings_UI)
	app.workspace_new(state, w, false)
	target := w.workspace
	target_id := target.id
	session := app.focused_session(state, w).session
	pid := term.process_id(session)
	app.workspace_delete_request(state, w, target)
	testing.expect_value(t, w.pending_close.destination, destination.id)
	testing.expect_value(t, os.remove(f.path), nil)
	delete_key(state, w, .Enter)
	testing.expect(t, w.workspace == target && app.workspace_find(state, target_id) == target)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, os.write_entire_file(f.path, "shell.command = pwsh.exe -NoLogo -NoProfile\n"), nil)
	app.workspace_delete_request(state, w, target)
	if !testing.expect(t, app.window_open(state, destination)) { return }
	delete_key(state, w, .Enter)
	testing.expect(t, w.pending_close.confirm.open && w.workspace == target)
	testing.expect_value(t, w.pending_close.destination, u32(0))
	delete_key(state, w, .Escape)
	app.window_close(state, state.windows[1])
	app.workspace_delete_request(state, w, target)
	delete_key(state, w, .Enter)
	testing.expect(t, w.workspace == destination && w.editor.open)
	testing.expect(t, app.workspace_find(state, target_id) == nil)
	testing.expect_value(t, len(state.sessions), 1)
	app.tick(state)
}

@(private="file")
Delete_Fail_Allocator :: struct { backing: runtime.Allocator, remaining: int, failed: bool }

@(private="file")
delete_fail_allocation :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, location := #caller_location) -> ([]u8, runtime.Allocator_Error) {
	f := cast(^Delete_Fail_Allocator)data
	if !f.failed && (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		if f.remaining == 0 { f.failed = true; return nil, .Out_Of_Memory }
		f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
workspace_delete_allocation_failures_preserve_original_until_prepared :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	original := w.workspace
	id := original.id
	session := state.sessions[0].session
	pid := term.process_id(session)
	backing := context.allocator
	context.logger = log.nil_logger()
	shell := state.settings.shell.command
	state.settings.shell.command = "aio-delete-nonexistent-shell.exe"
	app.workspace_delete_request(state, w, original)
	delete_key(state, w, .Enter)
	state.settings.shell.command = shell
	testing.expect(t, w.workspace == original && app.workspace_find(state, id) == original)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, term.process_id(session), pid)
	failure := Delete_Fail_Allocator{backing = backing}
	allocator := runtime.Allocator{delete_fail_allocation, &failure}
	failures := 0
	for allowed in 0 ..< 12 {
		app.workspace_delete_request(state, w, original)
		failure.remaining, failure.failed = allowed, false
		context.allocator = allocator
		app.pending_close_finish(state, w, true)
		context.allocator = backing
		failure.failed = true
		if app.workspace_find(state, id) == nil { break }
		failures += 1
		testing.expect(t, w.workspace == original && w.tree == &app.selected_tab(original).tree)
		testing.expect_value(t, len(state.workspaces), 1)
		testing.expect_value(t, len(state.sessions), 1)
		testing.expect_value(t, len(state.windows), 1)
		testing.expect_value(t, term.process_id(session), pid)
	}
	testing.expect(t, failures >= 4)
	if app.workspace_find(state, id) != nil {
		app.workspace_delete_request(state, w, original)
		delete_key(state, w, .Enter)
	}
	testing.expect(t, app.workspace_find(state, id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 1)
	// Existing hidden destinations isolate view allocation failures from runtime creation.
	app.workspace_new(state, w, false)
	original = w.workspace
	id = original.id
	session = app.focused_session(state, w).session
	pid = term.process_id(session)
	for allowed in 0 ..< 5 {
		app.workspace_delete_request(state, w, original)
		failure.remaining, failure.failed = allowed, false
		context.allocator = allocator
		app.pending_close_finish(state, w, true)
		context.allocator = backing
		failure.failed = true
		testing.expect(t, failure.remaining == 0)
		testing.expect(t, w.workspace == original && app.workspace_find(state, id) == original)
		testing.expect_value(t, len(state.workspaces), 2)
		testing.expect_value(t, len(state.sessions), 2)
		testing.expect_value(t, term.process_id(session), pid)
	}
	app.tick(state)
}

@(test)
workspace_delete_rejects_previews_and_cancels_when_requester_closes :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	target := w.workspace
	id := target.id
	target.provisional = true
	app.workspace_delete_request(state, w, target)
	testing.expect(t, !w.pending_close.confirm.open)
	target.provisional = false
	w.preparing = true
	app.workspace_delete_request(state, w, target)
	testing.expect(t, !w.pending_close.confirm.open)
	w.preparing = false
	app.workspace_new(state, w, true)
	requester := state.windows[1]
	requester_workspace := requester.workspace
	app.workspace_delete_request(state, requester, target)
	app.window_close(state, requester)
	testing.expect(t, app.workspace_find(state, id) == target)
	testing.expect_value(t, len(state.sessions), 2)
	if !testing.expect(t, app.window_open(state, requester_workspace)) { return }
	requester = state.windows[1]
	app.workspace_delete_request(state, requester, target)
	app.workspace_delete_request(state, w, target)
	delete_key(state, w, .Enter)
	testing.expect(t, app.workspace_find(state, id) == nil)
	delete_key(state, requester, .Enter)
	testing.expect(t, !requester.pending_close.confirm.open)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, len(state.workspaces), 2)
	app.tick(state)
}

@(test)
workspace_view_partial_failure_and_move_have_one_owner :: proc(t: ^testing.T) {
	f: Delete_Fixture
	defer delete_fixture_destroy(t, &f)
	if !delete_fixture_init(t, &f) {return}
	state := &f.state
	w := state.windows[0]
	app.pane_split(state, w, .Right)
	if !testing.expect_value(t, len(state.sessions), 2) {return}
	workspace := w.workspace
	live_views := raw_data(w.views)
	session := state.sessions[0].session
	pid, geometry := term.process_id(session), term.geometry(session)
	backing := context.allocator
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, backing)
	defer mem.tracking_allocator_destroy(&tracker)
	tracking := mem.tracking_allocator(&tracker)
	failure := Delete_Fail_Allocator{backing = tracking}
	allocator := runtime.Allocator{delete_fail_allocation, &failure}
	for allowed in 0 ..< 16 {
		prepared: app.Workspace_View_Resources
		failure.remaining, failure.failed = allowed, false
		context.allocator = allocator
		ok := app.workspace_view_prepare(state, &prepared, workspace)
		app.workspace_view_destroy(&prepared)
		context.allocator = backing
		if ok {break}
		testing.expect(t, failure.failed)
		testing.expect_value(t, len(tracker.allocation_map), 0)
		testing.expect(t, prepared.workspace == nil && prepared.tree == nil)
		testing.expect_value(t, raw_data(w.views), live_views)
		testing.expect(t, w.workspace == workspace && w.tree == &app.selected_tab(workspace).tree)
		testing.expect_value(t, term.geometry(session), geometry)
		testing.expect_value(t, term.process_id(session), pid)
	}
	failure.failed = true
	context.allocator = tracking
	defer context.allocator = backing
	prepared, receiver: app.Workspace_View_Resources
	defer app.workspace_view_destroy(&receiver)
	defer app.workspace_view_destroy(&prepared)
	if !testing.expect(t, app.workspace_view_prepare(state, &prepared, workspace)) {return}
	if !testing.expect(t, app.workspace_view_prepare(state, &receiver, workspace)) {return}
	testing.expect_value(t, len(prepared.views), 2)
	views := raw_data(prepared.views)
	app.workspace_view_move(&receiver, &prepared)
	app.workspace_view_destroy(&prepared)
	app.workspace_view_destroy(&prepared)
	testing.expect(t, prepared.workspace == nil && prepared.tree == nil)
	testing.expect(t, raw_data(prepared.views) == nil && raw_data(prepared.panes) == nil)
	testing.expect(t, raw_data(prepared.dividers) == nil)
	testing.expect(t, raw_data(prepared.dividers) == nil && prepared.editor.source == "")
	testing.expect_value(t, raw_data(receiver.views), views)
	testing.expect(t, receiver.workspace == workspace && receiver.tree == w.tree)
	testing.expect_value(t, raw_data(w.views), live_views)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, term.process_id(session), pid)
	app.workspace_view_destroy(&receiver)
	testing.expect_value(t, len(tracker.allocation_map), 0)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	context.allocator = backing
	app.run_action(state, w, .Settings_UI)
	context.allocator = tracking
	if !testing.expect(t, app.workspace_view_prepare(state, &prepared, workspace)) {return}
	source := prepared.editor.source
	app.workspace_view_move(&receiver, &prepared)
	app.workspace_view_destroy(&prepared)
	testing.expect(t, prepared.editor.source == "" && len(prepared.editor.rows) == 0)
	testing.expect(t, receiver.editor.open && len(receiver.editor.rows) > 0)
	testing.expect_value(t, receiver.editor.source, source)
	app.workspace_view_destroy(&receiver)
	testing.expect_value(t, len(tracker.allocation_map), 0)
}
