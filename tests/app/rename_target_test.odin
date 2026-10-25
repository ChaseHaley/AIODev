package app_test

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:ui"

@(private="file")
Rename_Target_Fixture :: struct {
	state:     app.App,
	workspace: ^app.Workspace,
	w:         app.Window,
}

@(private="file")
rename_target_fixture_init :: proc(t: ^testing.T, f: ^Rename_Target_Fixture) -> bool {
	identity := fmt.tprintf("AIODev.Test.RenameTarget.%d.%p", os.get_pid(), f)
	if !testing.expect_value(t, platform.init(&f.state.platform, identity),
		platform.Init_Result.Primary) {return false}
	f.state.app_id = "AIODev.Test.RenameTarget"
	f.workspace = app.workspace_create_empty(&f.state)
	if !testing.expect(t, f.workspace != nil) {return false}
	id, window_error := platform.window_create(&f.state.platform,
		{hidden = true, width = 800, height = 600})
	if !testing.expect_value(t, window_error, platform.Error.None) {return false}
	f.w = {id = id, workspace = f.workspace, scale = 1}
	append(&f.state.windows, &f.w)
	for tab_id: u32 = 1; tab_id <= 2; tab_id += 1 {
		tab := new(app.Tab)
		if !testing.expect(t, tab != nil) {return false}
		tab.id = tab_id
		if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, tab_id*10}), nil) {
			free(tab)
			return false
		}
		append(&f.workspace.tabs, tab)
	}
	f.workspace.next_tab_id = 2
	for session_id: u32 = 10; session_id <= 20; session_id += 10 {
		append(&f.state.sessions, app.Session_Entry{id = session_id,
			name = fmt.aprintf("Pane %d", session_id)})
	}
	f.w.tree = &f.workspace.tabs[0].tree
	return true
}

@(private="file")
rename_target_fixture_destroy :: proc(f: ^Rename_Target_Fixture) {
	for workspace in f.state.workspaces {app.workspace_destroy(workspace)}
	delete(f.state.workspaces)
	for &entry in f.state.sessions {delete(entry.name)}
	delete(f.state.sessions)
	delete(f.state.windows)
	delete(f.w.rename.bytes)
	delete(f.w.panes)
	delete(f.w.dividers)
	_ = platform.destroy(&f.state.platform)
}

@(test)
rename_target_commits_each_kind_and_refreshes_its_owner :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s, w := &f.state, &f.w
	tab := f.workspace.tabs[0]
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, tab.id}, "  Build  "),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "Build")
	testing.expect_value(t, tab.title, "Build")
	testing.expect_value(t, f.workspace.tabs[1].name, "")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, tab.id}, "Build tools"),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "Build tools")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Pane, 10}, " Shell "),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, s.sessions[0].name, "Shell")
	testing.expect_value(t, tab.title, "Build tools")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, tab.id}, "   "),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "")
	testing.expect_value(t, tab.title, "Shell")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Workspace, f.workspace.id},
		"  Tooling  "), app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.name, "Tooling")
	testing.expect(t, w.dirty)
}

@(test)
rename_target_empty_policy_and_cleaning_differ_by_kind :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s, w := &f.state, &f.w
	tab := f.workspace.tabs[0]
	kept := f.workspace.name
	testing.expect_value(t, app.rename_target_commit(s, w, {.Workspace, f.workspace.id},
		" \n\t "), app.Rename_Outcome.Empty)
	testing.expect_value(t, f.workspace.name, kept)
	testing.expect_value(t, app.rename_target_commit(s, w, {.Workspace, f.workspace.id},
		" A\x01B "), app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.name, "AB")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, tab.id}, " Na\x1bme\t"),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "Name")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, tab.id}, ""),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "")
	testing.expect_value(t, app.rename_target_commit(s, w, {.Pane, 10}, " \n "),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, s.sessions[0].name, "")
}

@(test)
rename_target_resolution_survives_rename_and_rejects_closed_targets :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s, w := &f.state, &f.w
	other := app.workspace_create_empty(s)
	if !testing.expect(t, other != nil) {return}
	other_tab := new(app.Tab)
	if !testing.expect(t, other_tab != nil) {return}
	other_tab.id = f.workspace.tabs[0].id
	if !testing.expect_value(t, layout.init(&other_tab.tree, {.Terminal, 99}), nil) {
		free(other_tab)
		return
	}
	append(&other.tabs, other_tab)
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, other_tab.id}, "Presented"),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.tabs[0].name, "Presented")
	testing.expect_value(t, other_tab.name, "")
	closed := f.workspace.tabs[1]
	closed_id := closed.id
	ordered_remove(&f.workspace.tabs, 1)
	layout.destroy(&closed.tree)
	delete(closed.title)
	delete(closed.name)
	free(closed)
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, closed_id}, "Closed"),
		app.Rename_Outcome.Missing)
	testing.expect_value(t, f.workspace.tabs[0].name, "Presented")
	delete(s.sessions[1].name)
	ordered_remove(&s.sessions, 1)
	testing.expect_value(t, app.rename_target_commit(s, w, {.Pane, 20}, "Closed"),
		app.Rename_Outcome.Missing)
	doomed := app.workspace_create_empty(s)
	if !testing.expect(t, doomed != nil) {return}
	testing.expect_value(t, app.rename_target_commit(s, w, {.Workspace, doomed.id}, "Doomed"),
		app.Rename_Outcome.Saved)
	if !testing.expect(t, app.workspace_discard_empty(s, doomed)) {return}
	testing.expect_value(t, app.rename_target_commit(s, w, {.Workspace, doomed.id}, "Again"),
		app.Rename_Outcome.Missing)
}

@(test)
rename_target_allocation_failure_preserves_the_previous_name :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s, w := &f.state, &f.w
	tab := f.workspace.tabs[0]
	testing.expect_value(t, app.rename_target_commit(s, w, {.Tab, tab.id}, "Kept"),
		app.Rename_Outcome.Saved)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	outcome := app.rename_target_commit(s, w, {.Tab, tab.id}, "Dropped")
	workspace_outcome := app.rename_target_commit(s, w, {.Workspace, f.workspace.id}, "Dropped")
	context.allocator = allocator
	testing.expect_value(t, outcome, app.Rename_Outcome.Failed)
	testing.expect_value(t, workspace_outcome, app.Rename_Outcome.Failed)
	testing.expect_value(t, tab.name, "Kept")
	testing.expect_value(t, f.workspace.name, "Workspace 1")
}

@(test)
rename_target_modal_commits_and_clears_through_the_same_policy :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s, w := &f.state, &f.w
	tab := f.workspace.tabs[0]
	app.rename_open(s, w, true)
	testing.expect(t, w.rename_open && w.rename_target.kind == app.Rename_Kind.Tab)
	testing.expect_value(t, w.rename_target.id, tab.id)
	ui.field_set(&w.rename, "  Modal  ")
	app.rename_finish(s, w, true)
	testing.expect(t, !w.rename_open && tab.name == "Modal" && tab.title == "Modal")
	app.rename_open(s, w, true)
	testing.expect(t, w.rename_open && w.rename_target.kind == app.Rename_Kind.Tab)
	ui.field_set(&w.rename, "   ")
	app.rename_finish(s, w, true)
	testing.expect(t, !w.rename_open && tab.name == "" && tab.title == "Pane 10")
	app.rename_open(s, w, false)
	testing.expect(t, w.rename_open && w.rename_target.kind == app.Rename_Kind.Pane)
	ui.field_set(&w.rename, "Modal pane")
	app.rename_finish(s, w, true)
	testing.expect(t, !w.rename_open && s.sessions[0].name == "Modal pane")
	testing.expect_value(t, tab.title, "Modal pane")
}
