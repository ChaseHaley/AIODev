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
	testing.expect_value(t, app.rename_target_commit(&f.state, app.Rename_Workspace_Target{f.workspace.id},
		"Workspace 1", .Workspace_Row), app.Rename_Outcome.Saved)
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
	target := app.Rename_Tab_Target{f.workspace.id, tab.id}
	testing.expect_value(t, app.rename_target_commit(s, target, "  Build  ", .Automatic_Title),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "Build")
	testing.expect_value(t, tab.title, "Build")
	testing.expect_value(t, f.workspace.tabs[1].name, "")
	testing.expect_value(t, app.rename_target_commit(s, target, "Build tools", .Automatic_Title),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "Build tools")
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Pane_Target{10}, " Shell ",
		.Automatic_Title), app.Rename_Outcome.Saved)
	testing.expect_value(t, s.sessions[0].name, "Shell")
	testing.expect_value(t, tab.title, "Build tools")
	testing.expect_value(t, app.rename_target_commit(s, target, "   ", .Automatic_Title),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "")
	testing.expect_value(t, tab.title, "Shell")
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Workspace_Target{f.workspace.id},
		"  Tooling  ", .Workspace_Row), app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.name, "Tooling")
	testing.expect(t, w.dirty)
}

@(test)
rename_target_empty_policy_and_cleaning_differ_by_kind :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s := &f.state
	tab := f.workspace.tabs[0]
	workspace := app.Rename_Workspace_Target{f.workspace.id}
	kept := f.workspace.name
	testing.expect_value(t, app.rename_target_commit(s, workspace, " \n\t ", .Workspace_Row),
		app.Rename_Outcome.Empty)
	testing.expect_value(t, f.workspace.name, kept)
	// The chip closes on an empty name, keeping the workspace's name.
	testing.expect_value(t, app.rename_target_commit(s, workspace, " \n\t ", .Workspace_Chip),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.name, kept)
	testing.expect_value(t, app.rename_target_commit(s, workspace, " A\x01B ", .Workspace_Chip),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.name, "AB")
	target := app.Rename_Tab_Target{f.workspace.id, tab.id}
	testing.expect_value(t, app.rename_target_commit(s, target, " Na\x1bme\t", .Automatic_Title),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "Name")
	testing.expect_value(t, app.rename_target_commit(s, target, "", .Automatic_Title),
		app.Rename_Outcome.Saved)
	testing.expect_value(t, tab.name, "")
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Pane_Target{10}, " \n ",
		.Automatic_Title), app.Rename_Outcome.Saved)
	testing.expect_value(t, s.sessions[0].name, "")
}

@(test)
rename_target_resolution_survives_rename_and_rejects_closed_targets :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s := &f.state
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
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Tab_Target{f.workspace.id, other_tab.id},
		"Presented", .Automatic_Title), app.Rename_Outcome.Saved)
	testing.expect_value(t, f.workspace.tabs[0].name, "Presented")
	testing.expect_value(t, other_tab.name, "")
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Tab_Target{other.id, other_tab.id},
		"Elsewhere", .Automatic_Title), app.Rename_Outcome.Saved)
	testing.expect_value(t, other_tab.name, "Elsewhere")
	testing.expect_value(t, f.workspace.tabs[0].name, "Presented")
	closed := f.workspace.tabs[1]
	closed_id := closed.id
	ordered_remove(&f.workspace.tabs, 1)
	layout.destroy(&closed.tree)
	delete(closed.title)
	delete(closed.name)
	free(closed)
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Tab_Target{f.workspace.id, closed_id},
		"Closed", .Automatic_Title), app.Rename_Outcome.Missing)
	testing.expect_value(t, f.workspace.tabs[0].name, "Presented")
	delete(s.sessions[1].name)
	ordered_remove(&s.sessions, 1)
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Pane_Target{20}, "Closed",
		.Automatic_Title), app.Rename_Outcome.Missing)
	doomed := app.workspace_create_empty(s)
	if !testing.expect(t, doomed != nil) {return}
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Workspace_Target{doomed.id}, "Doomed",
		.Workspace_Row), app.Rename_Outcome.Saved)
	if !testing.expect(t, app.workspace_discard_empty(s, doomed)) {return}
	testing.expect_value(t, app.rename_target_commit(s, app.Rename_Workspace_Target{doomed.id}, "Again",
		.Workspace_Row), app.Rename_Outcome.Missing)
}

@(test)
rename_target_allocation_failure_preserves_the_previous_name :: proc(t: ^testing.T) {
	f: Rename_Target_Fixture
	defer rename_target_fixture_destroy(&f)
	if !rename_target_fixture_init(t, &f) {return}
	s := &f.state
	tab := f.workspace.tabs[0]
	target := app.Rename_Tab_Target{f.workspace.id, tab.id}
	testing.expect_value(t, app.rename_target_commit(s, target, "Kept", .Automatic_Title),
		app.Rename_Outcome.Saved)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	outcome := app.rename_target_commit(s, target, "Dropped", .Automatic_Title)
	workspace_outcome := app.rename_target_commit(s, app.Rename_Workspace_Target{f.workspace.id}, "Dropped",
		.Workspace_Row)
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
	app.rename_open(s, w, app.Rename_Tab_Target{f.workspace.id, tab.id})
	dialog, shown := w.overlay.(app.Overlay_Rename)
	target, naming_tab := dialog.target.(app.Rename_Tab_Target)
	testing.expect(t, shown && naming_tab)
	testing.expect_value(t, target.tab, tab.id)
	testing.expect_value(t, ui.field_string(&w.rename), tab.name)
	ui.field_set(&w.rename, "  Modal  ")
	app.rename_finish(s, w, true)
	testing.expect(t, !app.rename_shown(w) && tab.name == "Modal" && tab.title == "Modal")
	app.rename_open(s, w, app.Rename_Tab_Target{f.workspace.id, tab.id})
	dialog, shown = w.overlay.(app.Overlay_Rename)
	_, naming_tab = dialog.target.(app.Rename_Tab_Target)
	testing.expect(t, shown && naming_tab)
	ui.field_set(&w.rename, "   ")
	app.rename_finish(s, w, true)
	testing.expect(t, !app.rename_shown(w) && tab.name == "" && tab.title == "Pane 10")
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil) {return}
	app.rename_open(s, w, app.Rename_Pane_Target{entry.id})
	dialog, shown = w.overlay.(app.Overlay_Rename)
	_, naming_pane := dialog.target.(app.Rename_Pane_Target)
	testing.expect(t, shown && naming_pane)
	ui.field_set(&w.rename, "Modal pane")
	app.rename_finish(s, w, true)
	testing.expect(t, !app.rename_shown(w) && s.sessions[0].name == "Modal pane")
	testing.expect_value(t, tab.title, "Modal pane")
}
