package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:term"

@(private = "file")
Fixture :: struct {
	state:     ^app.App,
	directory: string,
	host:      ^app.Window,
	tab:       ^app.Tab,
	// The pane the tests link: the second pane of the first tab, focused.
	node:      layout.Node_Id,
	content:   layout.Content,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T, f: ^Fixture, run: int, reuse_directory := "") -> bool {
	f.state = new(app.App)
	if reuse_directory == "" {
		directory, directory_error := os.make_directory_temp("", "aio-pane-links-*", context.allocator)
		if !testing.expect_value(t, directory_error, nil) {return false}
		f.directory = directory
		path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
		settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"
		if !testing.expect_value(t, os.write_entire_file(path, settings), nil) {return false}
	} else {
		f.directory = reuse_directory
	}
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.PaneLinks.%d.%d", os.get_pid(), run)
	f.state.layout_path = strings.concatenate({f.directory, "/layout.json"})
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	if !testing.expect(t, app.app_init(f.state)) {return false}
	f.host = app.window_primary(f.state)
	return f.host != nil
}

@(private = "file")
fixture_split :: proc(t: ^testing.T, f: ^Fixture) -> bool {
	app.pane_split(f.state, f.host, .Right, 0.5)
	f.tab = app.selected_tab(f.host.workspace)
	f.node = f.tab.tree.focus
	pane, is_pane := f.tab.tree.nodes[f.node].(layout.Pane)
	if !testing.expect(t, is_pane) {return false}
	f.content = pane.content
	return true
}

@(private = "file")
fixture_stop :: proc(t: ^testing.T, f: ^Fixture, remove := true) {
	if f.state != nil {
		app.app_destroy(f.state)
		free(f.state)
		f.state = nil
	}
	if remove {
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
}

@(private = "file")
linked_window :: proc(f: ^Fixture) -> ^app.Window {
	return app.pane_link_window_of(f.state, f.content)
}

@(private = "file")
pane_is_linked :: proc(f: ^Fixture) -> bool {
	pane, is_pane := f.tab.tree.nodes[f.node].(layout.Pane)
	return is_pane && pane.linked
}

// Linking, in the states the feature exists for: the window follows the tab and the session never restarts.
@(test)
linked_window_follows_its_tab :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 1) {return}
	app.pane_link_toggle(f.state, f.host)
	testing.expect_value(t, len(f.state.windows), 1)
	if !fixture_split(t, &f) {return}
	session := app.session_find(f.state, f.content.id)
	pid := term.process_id(session.session)
	host_panes := len(f.host.panes)
	app.pane_link_toggle(f.state, f.host)
	testing.expect(t, pane_is_linked(&f))
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	testing.expect(t, f.tab.tree.focus != f.node, "focus stays on a pane the host shows")
	testing.expect_value(t, len(f.host.panes), host_panes - 1)
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, len(f.state.workspaces), 1)
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, w.header_height, f32(0))
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)
	app.pane_links_sync(f.state)
	testing.expect(t, w.link_shown)
	geometry := term.geometry(session.session)

	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_select(f.state, f.host, 1)
	app.pane_links_sync(f.state)
	testing.expect(t, !w.link_shown, "another tab hides the window")
	app.tab_select(f.state, f.host, 0)
	app.pane_links_sync(f.state)
	testing.expect(t, w.link_shown, "its tab brings the window back")
	testing.expect_value(t, term.geometry(session.session), geometry)
	testing.expect_value(t, term.process_id(session.session), pid)

	width, height := f.host.width, f.host.height
	app.window_resize(f.state, f.host, 0, 0)
	app.pane_links_sync(f.state)
	testing.expect(t, !w.link_shown, "minimizing the host hides the window")
	app.window_resize(f.state, f.host, width, height)
	app.pane_links_sync(f.state)
	testing.expect(t, w.link_shown)

	app.hide_to_tray(f.state, f.host)
	testing.expect(t, app.window_primary(f.state) == nil, "a linked window is not the app's window")
	app.pane_links_sync(f.state)
	testing.expect(t, !w.link_shown, "hiding the host hides the window")
	testing.expect(t, app.session_find(f.state, f.content.id) != nil)
	app.show_window(f.state)
	app.pane_links_sync(f.state)
	testing.expect(t, w.link_shown)
	testing.expect_value(t, len(f.state.windows), 2)
}

@(test)
linked_window_opens_at_the_configured_size :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 11) {return}
	if !fixture_split(t, &f) {return}
	expected := app.initial_geometry(f.state)
	app.window_resize(f.state, f.host, f.host.width + 300, f.host.height + 200)
	session := app.session_find(f.state, f.content.id)
	testing.expect(t, term.geometry(session.session).surface_width > expected.surface_width)
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	testing.expect_value(t, u32(w.width), expected.surface_width)
	testing.expect_value(t, u32(w.height), expected.surface_height)
	// The session held the larger window's geometry until now; it must take this window's.
	geometry := term.geometry(session.session)
	testing.expect_value(t, geometry.surface_width, expected.surface_width)
	testing.expect_value(t, geometry.surface_height, expected.surface_height)
}

@(test)
linked_pane_returns_to_its_slot :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 2) {return}
	if !fixture_split(t, &f) {return}
	before := f.host.panes[1].rect
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	testing.expect(t, f.host.panes[0].rect.width > before.width, "the sibling takes the space")
	app.pane_link_toggle(f.state, w)
	testing.expect(t, linked_window(&f) == nil)
	testing.expect(t, !pane_is_linked(&f))
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 2)
	testing.expect_value(t, f.host.panes[1].rect, before)
	testing.expect(t, app.session_find(f.state, f.content.id) != nil)
}

@(test)
closing_a_linked_pane_or_its_tab_closes_the_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 3) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	app.run_action(f.state, w, .Close_Pane)
	testing.expect(t, app.session_find(f.state, f.content.id) == nil)
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, app.tab_pane_count(f.tab), 1)

	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	if !testing.expect(t, linked_window(&f) != nil) {return}
	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_close(f.state, f.host, 0)
	testing.expect(t, app.session_find(f.state, f.content.id) == nil, "closing a tab closes its linked pane")
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.state.sessions), 1)
}

@(test)
last_pane_in_the_host_brings_the_linked_pane_back :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 4) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	if !testing.expect(t, linked_window(&f) != nil) {return}
	app.run_action(f.state, f.host, .Close_Pane)
	testing.expect(t, app.session_find(f.state, f.content.id) != nil)
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, f.host.panes[0].content, f.content)
}

@(test)
reopening_a_closed_tab_brings_back_its_linked_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 10) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	if !testing.expect(t, linked_window(&f) != nil) {return}
	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_close(f.state, f.host, 0)
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.state.windows), 1)
	app.closed_reopen(f.state, f.host)
	testing.expect_value(t, len(f.host.workspace.tabs), 2)
	testing.expect_value(t, f.host.workspace.selected, 0)
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, len(f.state.windows), 2)
	app.pane_links_sync(f.state)
	for w in f.state.windows {
		if w.linked {testing.expect(t, w.link_shown)}
	}
}

@(test)
linked_window_routes_commands :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 5) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	view := w.workspace
	sessions := len(f.state.sessions)
	app.run_action(f.state, w, .Split_Right)
	testing.expect_value(t, len(f.state.sessions), sessions)
	testing.expect_value(t, len(w.panes), 1)
	app.run_action(f.state, w, .New_Tab)
	testing.expect_value(t, len(f.host.workspace.tabs), 2)
	testing.expect_value(t, len(view.tabs), 1)
	testing.expect(t, w.workspace == view)
	testing.expect_value(t, len(f.state.workspaces), 1)
	app.pane_links_sync(f.state)
	testing.expect(t, !w.link_shown, "the new tab is selected, so the pane's tab left the screen")
	app.run_action(f.state, w, .Tab_1)
	testing.expect_value(t, f.host.workspace.selected, 0)
	app.pane_links_sync(f.state)
	testing.expect(t, w.link_shown)
}

@(test)
focusing_a_linked_pane_goes_to_its_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 6) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	focus := f.tab.tree.focus
	w.link_activate = false
	app.pane_focus(f.state, f.host, f.node)
	testing.expect_value(t, f.tab.tree.focus, focus)
	testing.expect(t, w.link_activate)
}

@(test)
linked_pane_follows_its_tab_to_another_workspace :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 7) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	destination := app.workspace_create_empty(f.state)
	if !testing.expect(t, destination != nil) {return}
	home_workspace := f.host.workspace
	request := app.workspace_move_request(f.host, true, 0)
	testing.expect(t, app.workspace_move_content(f.state, f.host, request, destination))
	testing.expect(t, f.host.workspace == destination)
	app.pane_links_sync(f.state)
	testing.expect_value(t, w.link_workspace, destination.id)
	testing.expect(t, w.link_shown, "the host now shows the moved tab")
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect(t, app.workspace_select(f.state, f.host, home_workspace))
	app.pane_links_sync(f.state)
	testing.expect(t, !w.link_shown)
}

@(test)
linked_window_survives_a_restart :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_start(t, &f, 8) {return}
	directory := f.directory
	defer {
		testing.expect_value(t, os.remove_all(directory), nil)
		delete(directory)
	}
	if !fixture_split(t, &f) {fixture_stop(t, &f, false); return}
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {fixture_stop(t, &f, false); return}
	target := platform.Window_Placement{100, 120, 900, 720, false}
	testing.expect_value(t, platform.window_set_placement(&f.state.platform, w.id, target), platform.Error.None)
	app.layout_state_save(f.state)
	fixture_stop(t, &f, false)

	second: Fixture
	if !fixture_start(t, &second, 9, directory) {fixture_stop(t, &second, false); return}
	defer fixture_stop(t, &second, false)
	testing.expect_value(t, len(second.state.windows), 2)
	workspace := second.state.workspaces[0]
	tab := workspace.tabs[0]
	linked_count := 0
	content: layout.Content
	for node in tab.tree.nodes {
		pane := node.(layout.Pane) or_continue
		if pane.linked {linked_count += 1; content = pane.content}
	}
	testing.expect_value(t, linked_count, 1)
	restored := app.pane_link_window_of(second.state, content)
	if !testing.expect(t, restored != nil) {return}
	testing.expect(t, !restored.link_shown)
	testing.expect(t, app.window_primary(second.state) != restored)
	placement, placement_error := platform.window_placement(&second.state.platform, restored.id)
	testing.expect_value(t, placement_error, platform.Error.None)
	testing.expect_value(t, placement, target)
	app.pane_links_sync(second.state)
	testing.expect(t, restored.link_shown)
	focused, is_pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
	testing.expect(t, is_pane && !focused.linked)
}

@(test)
saved_links_cannot_hide_every_pane_or_a_settings_page :: proc(t: ^testing.T) {
	nodes := []app.Saved_Node {
		{split = true, axis = .Horizontal, ratio = 0.5, first = 1, second = 2},
		{linked = true},
		{linked = true, content = .Settings},
	}
	saved := app.Saved_Tab{focus = 1, nodes = nodes}
	tree: layout.Layout
	defer layout.destroy(&tree)
	if !testing.expect(t, app.layout_tree_decode(&saved, &tree)) {return}
	testing.expect(t, tree.nodes[1].(layout.Pane).linked)
	testing.expect(t, !tree.nodes[2].(layout.Pane).linked)
	testing.expect_value(t, tree.focus, layout.Node_Id(2))

	all := []app.Saved_Node {
		{split = true, axis = .Horizontal, ratio = 0.5, first = 1, second = 2},
		{linked = true},
		{linked = true},
	}
	damaged := app.Saved_Tab{focus = 2, nodes = all}
	repaired: layout.Layout
	defer layout.destroy(&repaired)
	if !testing.expect(t, app.layout_tree_decode(&damaged, &repaired)) {return}
	testing.expect(t, !repaired.nodes[1].(layout.Pane).linked && !repaired.nodes[2].(layout.Pane).linked)
	testing.expect_value(t, repaired.focus, layout.Node_Id(2))
}
