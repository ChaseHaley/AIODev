package app_test

import "core:testing"
import app "../../src"
import "aio:layout"

@(private="file")
Inventory_Fixture :: struct {
	state:     app.App,
	workspace: ^app.Workspace,
}

@(private="file")
inventory_tab :: proc(
	t: ^testing.T,
	workspace: ^app.Workspace,
	content: layout.Content,
) -> bool {
	tab, tab_error := new(app.Tab)
	if !testing.expect_value(t, tab_error, nil) {return false}
	if !testing.expect_value(t, layout.init(&tab.tree, content), nil) {
		free(tab)
		return false
	}
	if _, append_error := append(&workspace.tabs, tab); append_error == nil {return true}
	app.tab_record_free(tab)
	return false
}

@(private="file")
inventory_fixture_init :: proc(t: ^testing.T, f: ^Inventory_Fixture) -> bool {
	f.workspace = app.workspace_create_empty(&f.state)
	if !testing.expect(t, f.workspace != nil) {return false}
	if !inventory_tab(t, f.workspace, {.Terminal, 7}) {return false}
	_, split_error := layout.split_direction(
		&f.workspace.tabs[0].tree,
		f.workspace.tabs[0].tree.root,
		.Right,
		0.5,
		{.Settings, 0},
	)
	if !testing.expect_value(t, split_error, nil) {return false}
	if !inventory_tab(t, f.workspace, {.Terminal, 8}) {return false}
	if !inventory_tab(t, f.workspace, {.Settings, 0}) {return false}
	if _, append_error := append(&f.state.sessions, app.Session_Entry{id = 7});
	   append_error != nil {
		return false
	}
	if _, append_error := append(&f.state.sessions, app.Session_Entry{id = 8});
	   append_error != nil {
		return false
	}
	return true
}

@(private="file")
inventory_fixture_destroy :: proc(f: ^Inventory_Fixture) {
	clear(&f.state.workspaces)
	if f.workspace != nil {
		app.workspace_destroy(f.workspace)
		f.workspace = nil
	}
	delete(f.state.workspaces)
	delete(f.state.sessions)
}

@(test)
workspace_inventory_counts_panes_separately_from_sessions :: proc(t: ^testing.T) {
	f: Inventory_Fixture
	defer inventory_fixture_destroy(&f)
	if !inventory_fixture_init(t, &f) {return}
	counts := app.workspace_pane_counts(f.workspace)
	testing.expect_value(t, counts.tabs, 3)
	testing.expect_value(t, counts.panes, 4)
	testing.expect_value(t, counts.sessions, 2)
	testing.expect_value(t, app.tab_pane_count(f.workspace.tabs[0]), 2)
	testing.expect_value(t, app.tab_pane_count(f.workspace.tabs[2]), 1)
}

@(test)
workspace_inventory_yields_tab_node_content_and_session :: proc(t: ^testing.T) {
	f: Inventory_Fixture
	defer inventory_fixture_destroy(&f)
	if !inventory_fixture_init(t, &f) {return}
	expected := [?]app.Workspace_Pane{
		{tab = 0, node = 0, content = {.Terminal, 7}},
		{tab = 0, node = 1, content = {.Settings, 0}},
		{tab = 1, node = 0, content = {.Terminal, 8}},
		{tab = 2, node = 0, content = {.Settings, 0}},
	}
	walk := app.workspace_panes(&f.state, f.workspace)
	count := 0
	for pane, ok := app.workspace_pane_next(&walk); ok; pane, ok = app.workspace_pane_next(&walk) {
		if !testing.expect(t, count < len(expected)) {break}
		testing.expect_value(t, pane.tab, expected[count].tab)
		testing.expect_value(t, pane.node, expected[count].node)
		testing.expect_value(t, pane.content, expected[count].content)
		if pane.content.kind == .Terminal {
			if testing.expect(t, pane.session != nil) {
				testing.expect_value(t, pane.session.id, pane.content.id)
			}
		} else {
			testing.expect(t, pane.session == nil)
		}
		count += 1
	}
	testing.expect_value(t, count, len(expected))
}

@(test)
workspace_inventory_session_walks_keep_the_content_rule :: proc(t: ^testing.T) {
	f: Inventory_Fixture
	defer inventory_fixture_destroy(&f)
	if !inventory_fixture_init(t, &f) {return}
	session_walk := app.workspace_session_panes(&f.state, f.workspace)
	session_count := 0
	for pane, ok := app.workspace_pane_next(&session_walk);
	    ok;
	    pane, ok = app.workspace_pane_next(&session_walk) {
		switch session_count {
		case 0:
			testing.expect_value(t, pane.tab, 0)
			testing.expect_value(t, pane.content, layout.Content{.Terminal, 7})
		case 1:
			testing.expect_value(t, pane.tab, 1)
			testing.expect_value(t, pane.content, layout.Content{.Terminal, 8})
		}
		session_count += 1
	}
	testing.expect_value(t, session_count, 2)

	other_walk := app.tab_other_panes(&f.state, &f.workspace.tabs[0].tree, 0)
	other_count := 0
	for pane, ok := app.workspace_pane_next(&other_walk);
	    ok;
	    pane, ok = app.workspace_pane_next(&other_walk) {
		testing.expect_value(t, pane.tab, 0)
		testing.expect_value(t, pane.node, layout.Node_Id(1))
		testing.expect_value(t, pane.content, layout.Content{.Settings, 0})
		other_count += 1
	}
	testing.expect_value(t, other_count, 1)

	other_walk = app.tab_other_panes(&f.state, &f.workspace.tabs[2].tree, 2)
	other_count = 0
	for pane, ok := app.workspace_pane_next(&other_walk);
	    ok;
	    pane, ok = app.workspace_pane_next(&other_walk) {
		testing.expect_value(t, pane.tab, 2)
		testing.expect_value(t, pane.node, layout.Node_Id(0))
		testing.expect_value(t, pane.content, layout.Content{.Settings, 0})
		other_count += 1
	}
	testing.expect_value(t, other_count, 1)

	tab_walk := app.tab_session_panes(&f.state, &f.workspace.tabs[0].tree, 0)
	tab_count := 0
	for pane, ok := app.workspace_pane_next(&tab_walk); ok; pane, ok = app.workspace_pane_next(&tab_walk) {
		testing.expect_value(t, pane.tab, 0)
		testing.expect_value(t, pane.content, layout.Content{.Terminal, 7})
		tab_count += 1
	}
	testing.expect_value(t, tab_count, 1)
}

@(test)
workspace_inventory_first_and_focused_queries_keep_mutation_identity :: proc(t: ^testing.T) {
	f: Inventory_Fixture
	defer inventory_fixture_destroy(&f)
	if !inventory_fixture_init(t, &f) {return}
	found, found_ok := app.workspace_first_session(&f.state, f.workspace, 8)
	if testing.expect(t, found_ok) {
		testing.expect_value(t, found.tab, 1)
		testing.expect_value(t, found.node, layout.Node_Id(0))
		testing.expect_value(t, found.content, layout.Content{.Terminal, 8})
	}
	_, missing := app.workspace_first_session(&f.state, f.workspace, 9)
	testing.expect(t, !missing)

	focused, focused_ok := app.workspace_focused_session_pane(&f.state, f.workspace, 0)
	if testing.expect(t, focused_ok) {
		testing.expect_value(t, focused.tab, 0)
		testing.expect_value(t, focused.node, layout.Node_Id(0))
		testing.expect_value(t, focused.content, layout.Content{.Terminal, 7})
	}
	_, settings_focused := app.workspace_focused_session_pane(&f.state, f.workspace, 2)
	testing.expect(t, !settings_focused)
	_, invalid_tab := app.workspace_focused_session_pane(&f.state, f.workspace, 3)
	testing.expect(t, !invalid_tab)

	_, settings_node := app.workspace_session_pane_at(&f.state, f.workspace, 0, 1)
	testing.expect(t, !settings_node)
	terminal_node, terminal_ok := app.workspace_session_pane_at(&f.state, f.workspace, 0, 0)
	if testing.expect(t, terminal_ok) {
		testing.expect_value(t, terminal_node.content, layout.Content{.Terminal, 7})
	}
}

@(test)
workspace_inventory_maps_content_to_its_session :: proc(t: ^testing.T) {
	f: Inventory_Fixture
	defer inventory_fixture_destroy(&f)
	if !inventory_fixture_init(t, &f) {return}
	entry := app.workspace_session_for_content(&f.state, layout.Content{.Terminal, 7})
	if testing.expect(t, entry != nil) {
		testing.expect_value(t, entry.id, u32(7))
	}
	testing.expect(
		t,
		app.workspace_session_for_content(&f.state, layout.Content{.Settings, 0}) == nil,
	)
	testing.expect(
		t,
		app.workspace_session_for_content(&f.state, layout.Content{.Terminal, 9}) == nil,
	)
}
