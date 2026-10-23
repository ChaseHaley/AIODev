package app_test

import "base:runtime"
import "core:testing"
import app "../../src"
import "aio:layout"

@(private="file")
record_free_tabs :: proc(workspace: ^app.Workspace) {
	for tab in workspace.tabs {app.tab_record_free(tab)}
	delete(workspace.tabs)
}

@(test)
tab_record_commit_derives_the_title_without_a_later_focus_pass :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 7, name = "Build"})
	workspace: app.Workspace
	defer record_free_tabs(&workspace)
	tab, record_error := app.tab_record_reserve(&workspace)
	if !testing.expect_value(t, record_error, app.Tab_Record_Error.None) {return}
	testing.expect_value(t, tab.id, u32(0))
	testing.expect_value(t, len(workspace.tabs), 0)
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 7}), nil) {
		app.tab_record_free(tab)
		return
	}
	app.tab_record_commit(&state, &workspace, tab)
	testing.expect_value(t, tab.title, "Build")
	testing.expect_value(t, tab.id, u32(1))
	testing.expect_value(t, workspace.next_tab_id, u32(1))
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect(t, len(workspace.tabs) == 1 && workspace.tabs[0] == tab)
}

@(test)
tab_record_commit_names_a_settings_tab_from_its_content :: proc(t: ^testing.T) {
	state: app.App
	workspace: app.Workspace
	defer record_free_tabs(&workspace)
	tab, record_error := app.tab_record_reserve(&workspace)
	if !testing.expect_value(t, record_error, app.Tab_Record_Error.None) {return}
	if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {
		app.tab_record_free(tab)
		return
	}
	app.tab_record_commit(&state, &workspace, tab)
	testing.expect_value(t, tab.title, "Settings")
}

@(test)
tab_record_destroy_leaves_borrowed_sessions_open :: proc(t: ^testing.T) {
	state: app.App
	append(&state.sessions, app.Session_Entry{id = 7, name = "Build"})
	workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, workspace != nil) {
		delete(state.sessions)
		return
	}
	defer {
		delete(state.workspaces)
		delete(state.sessions)
	}
	tab, record_error := app.tab_record_reserve(workspace)
	if !testing.expect_value(t, record_error, app.Tab_Record_Error.None) {return}
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 7}), nil) {
		app.tab_record_free(tab)
		return
	}
	app.tab_record_commit(&state, workspace, tab)
	app.workspace_destroy(workspace)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, state.sessions[0].id, u32(7))
}

@(test)
tab_record_free_accepts_a_record_that_never_received_a_tree :: proc(t: ^testing.T) {
	workspace: app.Workspace
	defer delete(workspace.tabs)
	tab, record_error := app.tab_record_reserve(&workspace)
	if !testing.expect_value(t, record_error, app.Tab_Record_Error.None) {return}
	app.tab_record_free(tab)
	testing.expect_value(t, len(workspace.tabs), 0)
}

@(test)
tab_record_reserve_reports_allocation_and_capacity_failure :: proc(t: ^testing.T) {
	workspace: app.Workspace
	defer delete(workspace.tabs)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	tab, record_error := app.tab_record_reserve(&workspace)
	context.allocator = allocator
	testing.expect(t, tab == nil)
	testing.expect_value(t, record_error, app.Tab_Record_Error.Allocation)
	testing.expect_value(t, len(workspace.tabs), 0)
	workspace.tabs.allocator = runtime.nil_allocator()
	tab, record_error = app.tab_record_reserve(&workspace)
	testing.expect(t, tab == nil)
	testing.expect_value(t, record_error, app.Tab_Record_Error.Capacity)
	testing.expect_value(t, len(workspace.tabs), 0)
}
