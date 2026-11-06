package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

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
		settings := idle_shell_settings(t, "cursor.blink = false\n")
		if !testing.expect_value(t, os.write_entire_file(path, settings), nil) {return false}
	} else {
		f.directory = reuse_directory
	}
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.PaneLinks.%d.%d", os.get_pid(), run)
	app.layout_state_enable(f.state, strings.concatenate({f.directory, "/layout.json"}))
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

@(private = "file")
activation_pending :: proc(w: ^app.Window) -> bool {
	link, linked := w.link.?
	return linked && link.activate
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
	testing.expect(t, w.header_height > 0)
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown)
	geometry := term.geometry(session.session)

	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_select(f.state, f.host, 1)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Hidden, "another tab hides the window")
	app.tab_select(f.state, f.host, 0)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown, "its tab brings the window back")
	testing.expect_value(t, term.geometry(session.session), geometry)
	testing.expect_value(t, term.process_id(session.session), pid)

	width, height := f.host.width, f.host.height
	app.window_resize(f.state, f.host, 0, 0)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Hidden, "minimizing the host hides the window")
	app.window_resize(f.state, f.host, width, height)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown)

	app.hide_to_tray(f.state, f.host)
	testing.expect(t, app.window_primary(f.state) == nil, "a linked window is not the app's window")
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Hidden, "hiding the host hides the window")
	testing.expect(t, app.session_find(f.state, f.content.id) != nil)
	app.show_window(f.state)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown)
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
		if app.window_linked(w) {testing.expect(t, w.phase == .Shown)}
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
	app.run_action(f.state, w, .Move_Pane_New_Workspace)
	testing.expect_value(t, len(f.state.workspaces), 1)
	testing.expect_value(t, len(w.panes), 1)
	app.run_action(f.state, w, .New_Tab)
	testing.expect_value(t, len(f.host.workspace.tabs), 2)
	testing.expect_value(t, len(view.tabs), 1)
	testing.expect(t, w.workspace == view)
	testing.expect_value(t, len(f.state.workspaces), 1)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Hidden, "the new tab is selected, so the pane's tab left the screen")
	app.run_action(f.state, w, .Tab_1)
	testing.expect_value(t, f.host.workspace.selected, 0)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown)
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
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown && !activation_pending(w), "the first show carries out the activation")
	app.pane_focus(f.state, f.host, f.node)
	testing.expect_value(t, f.tab.tree.focus, focus)
	testing.expect(t, activation_pending(w))
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
	testing.expect_value(t, app.window_link_workspace(w), destination.id)
	testing.expect(t, w.phase == .Shown, "the host now shows the moved tab")
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect(t, app.workspace_select(f.state, f.host, home_workspace))
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Hidden)
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
	testing.expect(t, restored.phase == .Hidden)
	testing.expect(t, app.window_primary(second.state) != restored)
	placement, placement_error := platform.window_placement(&second.state.platform, restored.id)
	testing.expect_value(t, placement_error, platform.Error.None)
	testing.expect_value(t, placement, target)
	app.pane_links_sync(second.state)
	testing.expect(t, restored.phase == .Shown)
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

// One pane linked, then split in its window: 1 in the host; 2 | 3 in the linked window.
@(private = "file")
fixture_split_linked :: proc(t: ^testing.T, f: ^Fixture) -> (w: ^app.Window, added: layout.Content, ok: bool) {
	if !fixture_split(t, f) {return}
	app.pane_link_toggle(f.state, f.host)
	w = linked_window(f)
	if !testing.expect(t, w != nil) {return}
	app.run_action(f.state, w, .Split_Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	added = w.panes[1].content
	if !testing.expect(t, added != f.content) {return}
	return w, added, true
}

@(test)
header_button_moves_a_pane_to_a_linked_window_and_back :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 30) {return}
	button := int(ui.Header_Action.Linked_Window) - 1
	click := proc(f: ^Fixture, w: ^app.Window, pane: layout.Pane_Rect, button: int) {
		r := pane.rect
		h := ui.header_layout({r.x, r.y, r.width, r.height}, w.scale)
		gesture_click_header(f.state, w, button, h)
	}
	click(&f, f.host, f.host.panes[0], button)
	testing.expect_value(t, len(f.state.windows), 1)
	if !fixture_split(t, &f) {return}
	click(&f, f.host, f.host.panes[1], button)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	testing.expect_value(t, len(f.host.panes), 1)
	click(&f, w, w.panes[0], button)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 2)
}

@(test)
linked_window_splits_keep_their_panes_in_the_tab :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 20) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	testing.expect(t, app.pane_link_window_of(f.state, added) == w)
	testing.expect(t, app.session_find(f.state, added.id) != nil)
	testing.expect_value(t, app.tab_pane_count(f.tab), 3)
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, layout.pane_count(w.tree), 2)
	app.pane_links_sync(f.state)
	testing.expect_value(t, layout.pane_count(w.tree), 2)
	testing.expect_value(t, len(w.panes), 2)
	testing.expect(t, w.header_height > 0)
}

@(test)
closing_a_split_linked_window_returns_every_pane :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 21) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	app.pane_link_return(f.state, w)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 3)
	testing.expect(t, app.session_find(f.state, added.id) != nil)
	testing.expect(t, app.session_find(f.state, f.content.id) != nil)
}

@(test)
resizing_in_a_linked_window_survives_its_return :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 22) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	root := w.tree.root
	branch := w.tree.nodes[root].(layout.Split)
	branch.ratio = 0.25
	w.tree.nodes[root] = branch
	app.pane_links_sync(f.state)
	testing.expect_value(t, w.tree.nodes[root].(layout.Split).ratio, f32(0.25))
	app.pane_link_return(f.state, w)
	testing.expect_value(t, len(f.host.panes), 3)
	first, second := f.host.panes[1].rect, f.host.panes[2].rect
	testing.expect(t, first.width < second.width, "the returned panes keep the window's arrangement")
}

@(test)
closing_a_pane_in_a_split_linked_window_keeps_the_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 23) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	app.run_action(f.state, w, .Close_Pane)
	testing.expect(t, app.session_find(f.state, added.id) == nil)
	app.pane_links_sync(f.state)
	testing.expect(t, linked_window(&f) == w, "the other pane keeps the window open")
	testing.expect_value(t, layout.pane_count(w.tree), 1)
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, w.panes[0].content, f.content)
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)

	// The pane that remains is the slot now, so closing it ends the window.
	app.run_action(f.state, w, .Close_Pane)
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, app.tab_pane_count(f.tab), 1)
}

@(test)
a_pane_closed_from_outside_a_split_linked_window_leaves_it :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 24) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	testing.expect(t, app.close_exited_session(f.state, f.content.id))
	app.pane_links_sync(f.state)
	testing.expect(t, app.pane_link_window_of(f.state, added) == w)
	testing.expect_value(t, layout.pane_count(w.tree), 1)
	testing.expect_value(t, len(w.panes), 1)
}

@(private = "file")
drag_pane_to :: proc(
	source_window, destination_window: ^app.Window,
	source, destination: ^app.Tab,
	node, target: layout.Node_Id,
	direction: layout.Direction,
	root := false,
) {
	source_window.pane_drag = {
		source = source,
		destination = destination,
		node = node,
		target = target,
		direction = direction,
		destination_window = destination_window.id,
		pressed = true,
		active = true,
		shown = true,
		root = root,
	}
}

@(test)
dragging_inside_a_linked_window_rearranges_it :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 31) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	// This is a local rearrangement; an overlapping host must not become the OS drop target.
	testing.expect_value(t, platform.window_hide(&f.state.platform, f.host.id), platform.Error.None)
	source, target := w.panes[0], w.panes[1]
	start := [2]f32{source.rect.x + 40, source.rect.y + 8}
	app.pane_drag_press(f.state, w, source.node, start.x, start.y)
	x := target.rect.x + target.rect.width / 2
	y := target.rect.y + target.rect.height - 8 * w.scale
	testing.expect(t, app.pane_drag_move(f.state, w, x, y, false))
	testing.expect(t, !w.pane_drag.new_window)
	testing.expect(t, app.pane_drag_release(f.state, w))
	root, is_split := w.tree.nodes[w.tree.root].(layout.Split)
	testing.expect(t, is_split && root.axis == .Vertical, "the drop stacks the panes")
	app.pane_links_sync(f.state)
	testing.expect_value(t, layout.pane_count(w.tree), 2)
	app.pane_link_return(f.state, w)
	first, second := f.host.panes[1].rect, f.host.panes[2].rect
	testing.expect_value(t, first.x, second.x)
	testing.expect(t, first.y != second.y, "the tab received the window's arrangement")
}

@(test)
dragging_a_linked_pane_into_its_host_tab_returns_it :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 34) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	drag_pane_to(
		w,
		f.host,
		app.selected_tab(w.workspace),
		f.tab,
		w.panes[1].node,
		f.host.panes[0].node,
		.Right,
	)
	testing.expect(t, app.pane_drag_release(f.state, w))
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, app.tab_pane_count(f.tab), 3)
	testing.expect_value(t, len(f.host.panes), 2)
	node := layout.find_content(f.host.tree, added)
	if testing.expect(t, node != layout.INVALID_NODE) {
		pane := f.host.tree.nodes[node].(layout.Pane)
		testing.expect(t, !pane.linked)
	}
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, w.panes[0].content, f.content)
	content_node := layout.find_content(&f.tab.tree, f.content)
	if testing.expect(t, content_node != layout.INVALID_NODE) {
		testing.expect(
			t,
			layout.link_root(&f.tab.tree, content_node) != layout.INVALID_NODE,
			"the pane that stayed is still linked",
		)
	}
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Shown)
	app.pane_link_toggle(f.state, w)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 3)
}

@(test)
dragging_a_host_pane_into_a_linked_window_links_it :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 35) {return}
	app.pane_split(f.state, f.host, .Right, 0.5)
	app.pane_split(f.state, f.host, .Right, 0.5)
	f.tab = app.selected_tab(f.host.workspace)
	f.node = f.tab.tree.focus
	pane := f.tab.tree.nodes[f.node].(layout.Pane)
	f.content = pane.content
	app.pane_link_toggle(f.state, f.host)
	w := linked_window(&f)
	if !testing.expect(t, w != nil) {return}
	app.run_action(f.state, w, .Split_Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	moved := f.host.panes[0]
	source := layout.find_content(&f.tab.tree, moved.content)
	drag_pane_to(f.host, w, f.tab, app.selected_tab(w.workspace), source, w.panes[0].node, .Down)
	testing.expect(t, app.pane_drag_release(f.state, f.host))
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, len(w.panes), 3)
	testing.expect_value(t, app.tab_pane_count(f.tab), 4)
	node := layout.find_content(&f.tab.tree, moved.content)
	if testing.expect(t, node != layout.INVALID_NODE) {
		linked := f.tab.tree.nodes[node].(layout.Pane)
		testing.expect(t, !linked.linked)
		testing.expect(t, layout.link_root(&f.tab.tree, node) != layout.INVALID_NODE)
	}
	focused := w.tree.nodes[w.tree.focus].(layout.Pane)
	testing.expect_value(t, focused.content, moved.content)
	app.pane_link_return(f.state, w)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 4)
	for candidate in f.tab.tree.nodes {
		shown, is_pane := candidate.(layout.Pane)
		if is_pane {testing.expect(t, !shown.linked)}
	}
}

@(test)
dragging_a_linked_pane_into_another_linked_window_links_it_there :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 36) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	first := linked_window(&f)
	if !testing.expect(t, first != nil) {return}
	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_select(f.state, f.host, 1)
	app.pane_split(f.state, f.host, .Right, 0.5)
	second_tab := app.selected_tab(f.host.workspace)
	second_node := second_tab.tree.focus
	second_content := second_tab.tree.nodes[second_node].(layout.Pane).content
	app.pane_link_toggle(f.state, f.host)
	second := app.pane_link_window_of(f.state, second_content)
	if !testing.expect(t, second != nil) {return}
	testing.expect_value(t, len(f.state.windows), 3)
	drag_pane_to(
		first,
		second,
		app.selected_tab(first.workspace),
		app.selected_tab(second.workspace),
		first.tree.focus,
		second.tree.focus,
		.Right,
	)
	testing.expect(t, app.pane_drag_release(f.state, first))
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect(t, app.pane_link_window_of(f.state, f.content) == second)
	testing.expect(t, app.pane_link_window_of(f.state, second_content) == second)
	testing.expect_value(t, layout.pane_count(second.tree), 2)
	testing.expect_value(t, app.tab_pane_count(second_tab), 3)
	testing.expect_value(t, app.tab_pane_count(f.tab), 1)
	app.pane_link_return(f.state, second)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 3)
	testing.expect_value(t, app.tab_pane_count(second_tab), 3)
}

// Moving a linked pane also leaves its tab's host, even though the host keeps the pane it shows.
@(test)
dragging_a_linked_pane_to_another_workspace_gives_the_host_its_focus_back :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 90) {return}
	if !fixture_split(t, &f) {return}
	app.pane_link_toggle(f.state, f.host)
	first := linked_window(&f)
	if !testing.expect(t, first != nil) {return}
	workspace := app.workspace_create_empty(f.state)
	if !testing.expect(t, workspace != nil && app.tab_create(f.state, workspace)) {return}
	if !testing.expect(t, app.window_open(f.state, workspace)) {return}
	second := app.window_for_workspace(f.state, workspace)
	testing.expect(t, focus_holds_shown(f.host))
	drag_pane_to(
		first,
		second,
		app.selected_tab(first.workspace),
		app.selected_tab(second.workspace),
		first.tree.focus,
		second.tree.focus,
		.Right,
	)
	testing.expect(t, app.pane_drag_release(f.state, first))
	testing.expect(t, focus_holds_shown(f.host))
	testing.expect(t, focus_holds_shown(second))
}

@(test)
dragging_a_linked_pane_into_another_tab_keeps_it_unlinked :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 37) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_select(f.state, f.host, 1)
	destination := app.selected_tab(f.host.workspace)
	drag_pane_to(
		w,
		f.host,
		app.selected_tab(w.workspace),
		destination,
		w.panes[1].node,
		destination.tree.focus,
		.Right,
	)
	testing.expect(t, app.pane_drag_release(f.state, w))
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, app.tab_pane_count(destination), 2)
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)
	node := layout.find_content(&destination.tree, added)
	if testing.expect(t, node != layout.INVALID_NODE) {
		pane := destination.tree.nodes[node].(layout.Pane)
		testing.expect(t, !pane.linked)
	}
}

@(test)
dragging_a_linked_pane_outside_every_window_tears_it_off :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 38) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	source := w.panes[0]
	start := [2]f32{source.rect.x + 40, source.rect.y + 8}
	app.pane_drag_press(f.state, w, source.node, start.x, start.y)
	testing.expect(t, app.pane_drag_move(f.state, w, -30_000, -30_000, false))
	testing.expect(t, w.pane_drag.new_window, "a linked pane can leave for a window of its own")
	testing.expect(t, w.pane_drag.preview_window != 0)
	testing.expect(t, w.pane_drag.shown)
	testing.expect(t, app.pane_drag_release(f.state, w))
	testing.expect_value(t, len(f.state.windows), 3)
	testing.expect_value(t, len(f.state.workspaces), 2)
	testing.expect_value(t, len(w.panes), 1)
	testing.expect(t, w.panes[0].content != source.content)
	detached: ^app.Window
	for candidate in f.state.windows {
		if candidate != f.host && candidate != w {detached = candidate}
	}
	if testing.expect(t, detached != nil) {
		tab := app.selected_tab(detached.workspace)
		pane := tab.tree.nodes[tab.tree.focus].(layout.Pane)
		testing.expect_value(t, pane.content, source.content)
		testing.expect(t, !pane.linked)
	}
	testing.expect(t, app.session_find(f.state, source.content.id) != nil)
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)
}

@(test)
dragging_a_linked_pane_to_a_new_host_tab_moves_it_there :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 40) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	w.pane_drag = {
		source = app.selected_tab(w.workspace),
		node = w.panes[1].node,
		destination_window = f.host.id,
		pressed = true,
		active = true,
		shown = true,
		new_tab = true,
	}
	testing.expect(t, app.pane_drag_release(f.state, w))
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, len(f.host.workspace.tabs), 2)
	testing.expect_value(t, len(w.panes), 1)
	tab := app.selected_tab(f.host.workspace)
	node := layout.find_content(&tab.tree, added)
	if testing.expect(t, node != layout.INVALID_NODE) {
		pane := tab.tree.nodes[node].(layout.Pane)
		testing.expect(t, !pane.linked)
	}
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)
}

@(test)
dragging_the_last_shown_host_pane_into_a_linked_window_is_refused :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 41) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	moved := f.host.panes[0]
	drag_pane_to(f.host, w, f.tab, app.selected_tab(w.workspace), moved.node, w.panes[0].node, .Right)
	testing.expect(t, app.pane_drag_release(f.state, f.host))
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, f.host.panes[0].content, moved.content)
	testing.expect_value(t, len(w.panes), 2)
	testing.expect_value(t, app.tab_pane_count(f.tab), 3)
	node := layout.find_content(f.host.tree, moved.content)
	if testing.expect(t, node != layout.INVALID_NODE) {
		pane := f.host.tree.nodes[node].(layout.Pane)
		testing.expect(t, !pane.linked)
	}
}

@(test)
dragging_a_linked_pane_to_another_workspace_moves_its_content :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 42) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	destination := app.workspace_create_empty(f.state)
	if !testing.expect(t, destination != nil) {return}
	source := w.panes[0]
	app.pane_drag_press(f.state, w, source.node, source.rect.x + 40, source.rect.y + 8)
	w.pane_drag.active = true
	chip := app.workspace_button_rect(f.host)
	if !testing.expect(
		t,
		app.pane_workspace_drag_move(
			f.state,
			w,
			f.host,
			chip.x + chip.width / 2,
			chip.y + chip.height / 2,
			false,
		),
	) {return}
	testing.expect_value(t, w.pane_drag.picker_window, f.host.id)
	row := app.workspace_picker_row_rect(f.host, 0)
	if !testing.expect(
		t,
		app.pane_workspace_drag_move(
			f.state,
			w,
			f.host,
			row.x + row.width / 2,
			row.y + row.height / 2,
			false,
		),
	) {return}
	testing.expect_value(t, w.pane_drag.picker_hit, 0)
	testing.expect(t, app.pane_drag_release(f.state, w))
	testing.expect(t, f.host.workspace == destination)
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, len(f.state.workspaces), 2)
	testing.expect_value(t, len(destination.tabs), 1)
	tab := destination.tabs[0]
	node := layout.find_content(&tab.tree, source.content)
	if testing.expect(t, node != layout.INVALID_NODE) {
		pane := tab.tree.nodes[node].(layout.Pane)
		testing.expect(t, !pane.linked)
	}
	testing.expect_value(t, len(w.panes), 1)
	testing.expect_value(t, app.tab_pane_count(f.tab), 2)
	app.pane_links_sync(f.state)
	testing.expect(t, w.phase == .Hidden)
}

@(test)
closing_a_tab_closes_every_pane_of_its_split_linked_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 32) {return}
	_, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	if !testing.expect(t, app.tab_create(f.state, f.host.workspace)) {return}
	app.tab_close(f.state, f.host, 0)
	testing.expect(t, app.session_find(f.state, f.content.id) == nil)
	testing.expect(t, app.session_find(f.state, added.id) == nil)
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.state.sessions), 1)
}

@(test)
pane_reports_name_one_focused_pane_in_a_split_linked_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 33) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	w.focused = true
	focused := 0
	list := commands.invocation(commands.Command_Id(app.Action.Pane_List), .Control)
	for report in app.command_invoke(f.state, nil, list).panes {
		if report.focused {
			focused += 1
			testing.expect_value(t, report.id, added.id)
		}
	}
	testing.expect_value(t, focused, 1)
}

@(test)
returning_one_pane_leaves_the_others_in_the_window :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 25) {return}
	w, added, ok := fixture_split_linked(t, &f)
	if !ok {return}
	app.pane_link_toggle(f.state, w)
	testing.expect_value(t, len(f.state.windows), 2)
	testing.expect_value(t, layout.pane_count(w.tree), 1)
	testing.expect(t, app.pane_link_window_of(f.state, added) == nil, "the focused pane left")
	testing.expect(t, app.pane_link_window_of(f.state, f.content) == w)
	testing.expect_value(t, len(f.host.panes), 2)
	testing.expect_value(t, app.tab_pane_count(f.tab), 3)
	app.pane_links_sync(f.state)
	testing.expect_value(t, len(f.host.panes), 2)
	testing.expect_value(t, layout.pane_count(w.tree), 1)

	// The last pane returns the same way and takes the window with it.
	app.pane_link_toggle(f.state, w)
	testing.expect_value(t, len(f.state.windows), 1)
	testing.expect_value(t, len(f.host.panes), 3)
}

@(test)
focusing_a_pane_in_a_split_linked_window_selects_it_there :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 26) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	home := layout.find_content(f.host.tree, f.content)
	app.pane_focus(f.state, f.host, home)
	testing.expect(t, activation_pending(w))
	focused := w.tree.nodes[w.tree.focus].(layout.Pane)
	testing.expect_value(t, focused.content, f.content)
}

@(test)
reopening_a_pane_closed_in_a_linked_window_returns_it_there :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_stop(t, &f)
	if !fixture_start(t, &f, 27) {return}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {return}
	app.run_action(f.state, w, .Close_Pane)
	app.pane_links_sync(f.state)
	testing.expect_value(t, layout.pane_count(w.tree), 1)
	app.run_action(f.state, w, .Reopen_Closed)
	app.pane_links_sync(f.state)
	testing.expect_value(t, layout.pane_count(w.tree), 2)
	testing.expect_value(t, len(w.panes), 2)
	testing.expect_value(t, len(f.host.panes), 1)
	testing.expect_value(t, app.tab_pane_count(f.tab), 3)
}

@(test)
split_linked_window_survives_a_restart :: proc(t: ^testing.T) {
	f: Fixture
	if !fixture_start(t, &f, 28) {return}
	directory := f.directory
	defer {
		testing.expect_value(t, os.remove_all(directory), nil)
		delete(directory)
	}
	w, _, ok := fixture_split_linked(t, &f)
	if !ok {fixture_stop(t, &f, false); return}
	target := platform.Window_Placement{100, 120, 900, 720, false}
	testing.expect_value(t, platform.window_set_placement(&f.state.platform, w.id, target), platform.Error.None)
	app.layout_state_save(f.state)
	fixture_stop(t, &f, false)

	second: Fixture
	if !fixture_start(t, &second, 29, directory) {fixture_stop(t, &second, false); return}
	defer fixture_stop(t, &second, false)
	testing.expect_value(t, len(second.state.windows), 2)
	restored: ^app.Window
	for candidate in second.state.windows {if app.window_linked(candidate) {restored = candidate}}
	if !testing.expect(t, restored != nil) {return}
	testing.expect_value(t, layout.pane_count(restored.tree), 2)
	app.pane_links_sync(second.state)
	testing.expect(t, restored.phase == .Shown)
	testing.expect_value(t, len(restored.panes), 2)
	placement, placement_error := platform.window_placement(&second.state.platform, restored.id)
	testing.expect_value(t, placement_error, platform.Error.None)
	testing.expect_value(t, placement, target)
	testing.expect_value(t, len(second.host.panes), 1)
}

@(test)
saved_slots_hold_no_slots_or_settings :: proc(t: ^testing.T) {
	nodes := []app.Saved_Node {
		{split = true, axis = .Horizontal, ratio = 0.5, first = 1, second = 2},
		{},
		{split = true, linked = true, axis = .Vertical, ratio = 0.5, first = 3, second = 4},
		{linked = true},
		{},
	}
	saved := app.Saved_Tab{focus = 1, nodes = nodes}
	tree: layout.Layout
	defer layout.destroy(&tree)
	if !testing.expect(t, app.layout_tree_decode(&saved, &tree)) {return}
	testing.expect(t, tree.nodes[2].(layout.Split).linked)
	testing.expect(t, !tree.nodes[3].(layout.Pane).linked, "a pane in a slot is not a slot")

	with_settings := []app.Saved_Node {
		{split = true, axis = .Horizontal, ratio = 0.5, first = 1, second = 2},
		{},
		{split = true, linked = true, axis = .Vertical, ratio = 0.5, first = 3, second = 4},
		{},
		{content = .Settings},
	}
	settings := app.Saved_Tab{focus = 1, nodes = with_settings}
	shown: layout.Layout
	defer layout.destroy(&shown)
	if !testing.expect(t, app.layout_tree_decode(&settings, &shown)) {return}
	testing.expect(t, !shown.nodes[2].(layout.Split).linked)
}
