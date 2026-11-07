package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"

@(private="file")
Pending_Fixture :: struct { state: app.App, directory, path: string }

@(private="file")
pending_fixture_init :: proc(t: ^testing.T, f: ^Pending_Fixture) -> bool {
	var_error: os.Error
	f.directory, var_error = os.make_directory_temp("", "aio-pending-*", context.allocator)
	if !testing.expect_value(t, var_error, nil) { return false }
	f.path = strings.concatenate({f.directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path,
		idle_shell_settings(t, "cursor.blink = false\n")), nil) { return false }
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Pending.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private="file")
pending_fixture_destroy :: proc(t: ^testing.T, f: ^Pending_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" { testing.expect_value(t, os.remove(f.path), nil); delete(f.path) }
	if f.directory != "" { testing.expect_value(t, os.remove(f.directory), nil); delete(f.directory) }
}

@(private="file")
close_asking :: proc(w: ^app.Window) -> ^app.Pending_Close {
	return app.confirmation_asking(w, app.Pending_Close)
}

@(test)
pending_close_tab_subject_recounts_and_targets_recorded_tab :: proc(t: ^testing.T) {
	f: Pending_Fixture
	defer pending_fixture_destroy(t, &f)
	if !pending_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	workspace := w.workspace
	app.tab_new(state, w)
	app.tab_new(state, w)
	recorded := workspace.tabs[2]
	added, split_error := layout.split_direction(
		&recorded.tree,
		recorded.tree.root,
		.Right,
		0.5,
		{.Terminal, 0},
	)
	if !testing.expect_value(t, split_error, nil) { return }
	app.tab_select(state, w, 2)
	app.tab_close_request(state, w, 2)
	pc := close_asking(w)
	if !testing.expect(t, pc != nil) { return }
	recorded_target, is_tab := pc.target.(app.Close_Tab)
	if !testing.expect(t, is_tab) { return }
	testing.expect_value(t, recorded_target.tab, recorded.id)
	text := app.pending_close_text(state, pc, true, workspace)
	testing.expect_value(t, text.title, "Close this tab and its 2 panes?")
	testing.expect_value(t, text.label, "Close")
	_, split_error = layout.split_direction(
		&recorded.tree,
		added,
		.Right,
		0.5,
		{.Terminal, 0},
	)
	testing.expect_value(t, split_error, nil)
	text = app.pending_close_text(state, pc, true, workspace)
	testing.expect_value(t, text.title, "Close this tab and its 3 panes?")
	app.confirmation_finish(state, w, false)
	testing.expect(t, close_asking(w) == nil)
	testing.expect_value(t, len(workspace.tabs), 3)
	app.tab_close_request(state, w, 2)
	app.tab_close(state, w, 1)
	testing.expect_value(t, len(workspace.tabs), 2)
	pc = close_asking(w)
	if !testing.expect(t, pc != nil) { return }
	_, is_tab = pc.target.(app.Close_Tab)
	testing.expect(t, is_tab)
	app.confirmation_finish(state, w, true)
	testing.expect(t, close_asking(w) == nil)
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect(t, workspace.tabs[0].id != recorded.id)
}

@(test)
pending_close_workspace_subject_recounts_and_deletes :: proc(t: ^testing.T) {
	f: Pending_Fixture
	defer pending_fixture_destroy(t, &f)
	if !pending_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	target := w.workspace
	target_id := target.id
	app.pane_split(state, w, .Right)
	app.tab_new(state, w)
	app.workspace_delete_request(state, w, target)
	pc := close_asking(w)
	if !testing.expect(t, pc != nil) { return }
	plan, is_workspace := pc.target.(app.Close_Workspace)
	if !testing.expect(t, is_workspace) { return }
	testing.expect_value(t, plan.workspace, target_id)
	testing.expect_value(t, plan.owner, w.id)
	testing.expect_value(t, plan.destination, u32(0))
	text := app.pending_close_text(state, pc, true, w.workspace)
	testing.expect_value(t, text.body, "Close 2 tabs (3 panes); stop 3 sessions.")
	testing.expect_value(t, text.label, "Delete")
	testing.expect_value(t, text.note, "Replace it with a fresh default workspace and shell.")
	if _, created := app.tab_create(state, target); !testing.expect(t, created) { return }
	text = app.pending_close_text(state, pc, true, w.workspace)
	testing.expect_value(t, text.body, "Close 3 tabs (4 panes); stop 4 sessions.")
	app.confirmation_finish(state, w, false)
	testing.expect(t, close_asking(w) == nil)
	testing.expect(t, app.workspace_find(state, target_id) == target)
	testing.expect_value(t, len(target.tabs), 3)
	app.workspace_delete_request(state, w, target)
	app.confirmation_finish(state, w, true)
	testing.expect(t, close_asking(w) == nil)
	testing.expect(t, app.workspace_find(state, target_id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect(t, w.workspace.id != target_id)
	// The window adopting its replacement released the question's subject, names included.
	testing.expect(t, app.confirmation_shown(w) == nil)
}

@(test)
pending_close_stale_owner_reopens_question :: proc(t: ^testing.T) {
	f: Pending_Fixture
	defer pending_fixture_destroy(t, &f)
	if !pending_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	first := w.workspace
	app.workspace_new(state, w, true)
	app.rename_finish(state, w, true)
	if !testing.expect_value(t, len(state.windows), 2) { return }
	owner := state.windows[1]
	target := owner.workspace
	target_id := target.id
	app.workspace_delete_request(state, w, target)
	pc := close_asking(w)
	if !testing.expect(t, pc != nil) { return }
	plan, is_workspace := pc.target.(app.Close_Workspace)
	if !testing.expect(t, is_workspace) { return }
	testing.expect_value(t, plan.owner, owner.id)
	testing.expect_value(t, plan.destination, u32(0))
	app.window_close(state, owner)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect(t, app.workspace_find(state, target_id) == target)
	app.confirmation_finish(state, w, true)
	pc = close_asking(w)
	if !testing.expect(t, pc != nil) { return }
	plan, _ = pc.target.(app.Close_Workspace)
	testing.expect(t, plan.owner == 0)
	testing.expect_value(t, plan.destination, u32(0))
	testing.expect(t, app.workspace_find(state, target_id) == target)
	testing.expect(t, w.workspace == first)
	text := app.pending_close_text(state, pc, true, w.workspace)
	testing.expect_value(t, text.note, "Other workspaces and their sessions stay open.")
	app.confirmation_finish(state, w, false)
	testing.expect(t, close_asking(w) == nil)
}

@(private="file")
Pending_Fail_Allocator :: struct { backing: runtime.Allocator, remaining: int, failed: bool }

@(private="file")
pending_fail_allocation :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	runtime.Allocator_Error,
) {
	f := cast(^Pending_Fail_Allocator)data
	if !f.failed &&
	   (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		if f.remaining == 0 { f.failed = true; return nil, .Out_Of_Memory }
		f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
pending_close_allocation_failure_keeps_previous_question :: proc(t: ^testing.T) {
	f: Pending_Fixture
	defer pending_fixture_destroy(t, &f)
	if !pending_fixture_init(t, &f) { return }
	state := &f.state
	w := state.windows[0]
	target := w.workspace
	app.pane_split(state, w, .Right)
	app.tab_close_request(state, w, 0)
	pc := close_asking(w)
	if !testing.expect(t, pc != nil) { return }
	asked, is_tab := pc.target.(app.Close_Tab)
	if !testing.expect(t, is_tab) { return }
	backing := context.allocator
	failure := Pending_Fail_Allocator{backing = backing}
	context.allocator = runtime.Allocator{pending_fail_allocation, &failure}
	app.workspace_delete_request(state, w, target)
	context.allocator = backing
	testing.expect(t, failure.failed)
	pc = close_asking(w)
	if testing.expect(t, pc != nil) {
		kept, still_tab := pc.target.(app.Close_Tab)
		testing.expect(t, still_tab)
		testing.expect_value(t, kept.tab, asked.tab)
	}
	testing.expect(t, app.workspace_find(state, target.id) == target)
	testing.expect_value(t, len(state.windows), 1)
	app.confirmation_finish(state, w, false)
}
