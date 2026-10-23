package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:ui"

@(private="file")
Adoption_Fixture :: struct { state: app.App, directory, path: string }

@(private="file")
adoption_fixture_init :: proc(t: ^testing.T, f: ^Adoption_Fixture) -> bool {
	var_error: os.Error
	f.directory, var_error = os.make_directory_temp("", "aio-adoption-*", context.allocator)
	if !testing.expect_value(t, var_error, nil) { return false }
	f.path = strings.concatenate({f.directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path,
		"shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"), nil) { return false }
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.Adoption.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private="file")
adoption_fixture_destroy :: proc(t: ^testing.T, f: ^Adoption_Fixture) {
	app.app_destroy(&f.state)
	if f.path != "" { testing.expect_value(t, os.remove(f.path), nil); delete(f.path) }
	if f.directory != "" { testing.expect_value(t, os.remove(f.directory), nil); delete(f.directory) }
}

// Every presentation value a caller must not have to teach either path separately.
@(private="file")
adoption_dirty_presentation :: proc(w: ^app.Window) {
	w.tab_hover, w.tab_pressed = 1, true
	ui.armed_press(&w.tab_close_armed, 2)
	w.tab_underline = {value = 9, target = 9}
	w.tab_menu.open, w.rename_open = true, true
	w.workspace_picker.mode = .List
}

@(private="file")
adoption_expect_postcondition :: proc(
	t: ^testing.T,
	state: ^app.App,
	w: ^app.Window,
	workspace: ^app.Workspace,
) {
	testing.expect_value(t, w.workspace, workspace)
	testing.expect(t, w.tree == &app.selected_tab(workspace).tree)
	testing.expect_value(t, w.tab_hover, -1)
	testing.expect(t, !w.tab_pressed)
	testing.expect(t, !ui.armed_down(w.tab_close_armed))
	testing.expect_value(t, w.tab_underline.value, f32(workspace.selected))
	testing.expect_value(t, w.tab_underline.target, f32(workspace.selected))
	testing.expect(t, !w.tab_menu.open && !w.rename_open)
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, w.pending_close.kind, app.Pending_Close_Kind.None)
	testing.expect(t, len(w.close_restore) == 0)
	testing.expect(t, app.focused_session(state, w) != nil)
	testing.expect_value(t, workspace.selection_anchor, workspace.tabs[workspace.selected].id)
}

@(test)
workspace_adopt_retains_or_replaces_storage_with_one_postcondition :: proc(t: ^testing.T) {
	f: Adoption_Fixture
	defer adoption_fixture_destroy(t, &f)
	if !adoption_fixture_init(t, &f) { return }
	state, w := &f.state, f.state.windows[0]
	one := w.workspace
	app.pane_split(state, w, .Right)
	if !testing.expect_value(t, len(w.views), 2) { return }
	two := app.workspace_create_empty(state)
	if !testing.expect(t, two != nil) { return }
	if !testing.expect(t, app.tab_create(state, two)) { return }
	panes, controls, positions := raw_data(w.panes), raw_data(w.tab_controls), raw_data(w.tab_positions)
	adoption_dirty_presentation(w)
	if !testing.expect(t, app.workspace_adopt(state, w, two, .Retain)) { return }
	adoption_expect_postcondition(t, state, w, two)
	testing.expect_value(t, raw_data(w.panes), panes)
	testing.expect_value(t, raw_data(w.tab_controls), controls)
	testing.expect_value(t, raw_data(w.tab_positions), positions)
	testing.expect_value(t, len(w.views), 1)
	retained := raw_data(w.panes)
	adoption_dirty_presentation(w)
	if !testing.expect(t, app.workspace_adopt(state, w, one, .Replace)) { return }
	adoption_expect_postcondition(t, state, w, one)
	// Replacing pre-flights one view per terminal pane before taking over the window.
	testing.expect_value(t, len(w.views), 2)
	testing.expect(t, raw_data(w.panes) != retained)
	app.tick(state)
}

@(private="file")
Adoption_Fail_Allocator :: struct { backing: runtime.Allocator, remaining: int, failed: bool }

@(private="file")
adoption_fail_allocation :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]u8, runtime.Allocator_Error) {
	f := cast(^Adoption_Fail_Allocator)data
	if !f.failed && (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		if f.remaining == 0 { f.failed = true; return nil, .Out_Of_Memory }
		f.remaining -= 1
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
workspace_adopt_failure_keeps_previous_view_and_presentation :: proc(t: ^testing.T) {
	f: Adoption_Fixture
	defer adoption_fixture_destroy(t, &f)
	if !adoption_fixture_init(t, &f) { return }
	state, w := &f.state, f.state.windows[0]
	one := w.workspace
	app.pane_split(state, w, .Right)
	two := app.workspace_create_empty(state)
	if !testing.expect(t, two != nil) { return }
	if !testing.expect(t, app.tab_create(state, two)) { return }
	views, panes := raw_data(w.views), raw_data(w.panes)
	adoption_dirty_presentation(w)
	backing := context.allocator
	failure := Adoption_Fail_Allocator{backing = backing}
	allocator := runtime.Allocator{adoption_fail_allocation, &failure}
	context.allocator = allocator
	ok := app.workspace_adopt(state, w, two, .Replace)
	context.allocator = backing
	testing.expect(t, !ok && failure.failed)
	// Failure before the old view is released leaves the workspace and its presentation alone.
	testing.expect_value(t, w.workspace, one)
	testing.expect(t, w.tree == &app.selected_tab(one).tree)
	testing.expect_value(t, raw_data(w.views), views)
	testing.expect_value(t, raw_data(w.panes), panes)
	testing.expect_value(t, w.tab_hover, 1)
	testing.expect(t, w.tab_pressed)
	testing.expect_value(t, ui.armed_target(w.tab_close_armed), 2)
	testing.expect_value(t, w.tab_underline.value, f32(9))
	testing.expect_value(t, w.tab_underline.target, f32(9))
	testing.expect(t, w.workspace_picker.mode == .List)
	app.tick(state)
}

@(test)
workspace_selection_and_deletion_share_adoption_order :: proc(t: ^testing.T) {
	f: Adoption_Fixture
	defer adoption_fixture_destroy(t, &f)
	if !adoption_fixture_init(t, &f) { return }
	state, w := &f.state, f.state.windows[0]
	one := w.workspace
	app.workspace_new(state, w, false)
	two := w.workspace
	if !testing.expect(t, two != one) { return }
	adoption_dirty_presentation(w)
	if !testing.expect(t, app.workspace_select(state, w, one)) { return }
	adoption_expect_postcondition(t, state, w, one)
	app.workspace_delete_request(state, w, one)
	testing.expect(t, w.pending_close.confirm.open)
	adoption_dirty_presentation(w)
	app.pending_close_finish(state, w, true)
	adoption_expect_postcondition(t, state, w, two)
	testing.expect(t, app.workspace_find(state, one.id) == nil)
	testing.expect_value(t, len(state.workspaces), 1)
	app.tick(state)
}
