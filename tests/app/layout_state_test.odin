package app_test

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"

@(private="file")
decode :: proc(nodes: []app.Saved_Node, focus := 0) -> (layout.Layout, bool) {
	saved := app.Saved_Tab{focus = focus, nodes = nodes}
	tree: layout.Layout
	ok := app.layout_tree_decode(&saved, &tree)
	return tree, ok
}

@(test)
layout_tree_decode_rebuilds_nested_splits :: proc(t: ^testing.T) {
	nodes := []app.Saved_Node{
		{split = true, axis = .Vertical, ratio = 0.3, first = 1, second = 2},
		{},
		{split = true, axis = .Horizontal, ratio = 2, first = 3, second = 4},
		{content = .Settings},
		{},
	}
	tree, ok := decode(nodes, focus = 3)
	defer layout.destroy(&tree)
	if !testing.expect(t, ok) { return }
	testing.expect_value(t, tree.root, layout.Node_Id(0))
	testing.expect_value(t, tree.focus, layout.Node_Id(3))
	root, is_split := tree.nodes[0].(layout.Split)
	if !testing.expect(t, is_split) { return }
	testing.expect_value(t, root.axis, layout.Axis.Vertical)
	testing.expect_value(t, root.ratio, f32(0.3))
	inner := tree.nodes[2].(layout.Split)
	testing.expect_value(t, inner.ratio, f32(0.95))
	settings := tree.nodes[3].(layout.Pane)
	testing.expect_value(t, settings.content, layout.Content{.Settings, 0})
	rects: [dynamic]layout.Pane_Rect
	defer delete(rects)
	layout.compute(&tree, {0, 0, 100, 100}, 0, &rects)
	testing.expect_value(t, len(rects), 3)
}

@(test)
layout_tree_decode_rejects_damaged_trees :: proc(t: ^testing.T) {
	cases := [?][]app.Saved_Node{
		{},
		{{split = true, first = 0, second = 1}, {}},
		{{split = true, first = 1, second = 1}, {}},
		{{split = true, first = 1, second = 5}, {}},
		{{split = true, first = 1, second = -1}, {}},
		{{}, {}},
		{{split = true, ratio = math.nan_f32(), first = 1, second = 2}, {}, {}},
		{{content = layout.Content_Kind(9)}},
	}
	for nodes, i in cases {
		tree, ok := decode(nodes)
		testing.expectf(t, !ok, "case %d decoded", i)
		testing.expectf(t, tree.nodes == nil, "case %d kept nodes", i)
	}
}

@(test)
layout_tree_decode_moves_focus_off_splits :: proc(t: ^testing.T) {
	nodes := []app.Saved_Node{{split = true, first = 1, second = 2}, {}, {}}
	for focus in ([?]int{0, -1, 7}) {
		tree, ok := decode(nodes, focus)
		testing.expect(t, ok)
		testing.expect_value(t, tree.focus, layout.Node_Id(1))
		layout.destroy(&tree)
	}
}

@(test)
layout_state_encode_round_trips_structure :: proc(t: ^testing.T) {
	state: app.App
	defer {
		for workspace in state.workspaces { app.workspace_destroy(workspace) }
		delete(state.workspaces)
	}
	workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, workspace != nil) { return }
	delete(workspace.name)
	workspace.name = strings.clone("Notes")
	workspace.icon = {preset = 2, emoji = strings.clone("🦊"), tint = 3}
	for name in ([?]string{"", "Docs"}) {
		tab := new(app.Tab)
		if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) { free(tab); return }
		tab.name = strings.clone(name)
		append(&workspace.tabs, tab)
	}
	second := &workspace.tabs[1].tree
	_, split_error := layout.split(second, 0, .Horizontal, 0.25, {.Terminal, 42})
	testing.expect_value(t, split_error, nil)
	workspace.selected = 1
	empty := app.workspace_create_empty(&state)
	testing.expect(t, empty != nil)
	text, ok := app.layout_state_encode(&state, context.temp_allocator)
	if !testing.expect(t, ok) { return }
	decoded: app.Layout_State
	if !testing.expect_value(t, json.unmarshal(transmute([]u8)text, &decoded,
		allocator = context.temp_allocator), nil) { return }
	testing.expect_value(t, decoded.version, app.LAYOUT_STATE_VERSION)
	testing.expect_value(t, decoded.workspace_number, u32(2))
	if !testing.expect_value(t, len(decoded.workspaces), 1) { return }
	saved := decoded.workspaces[0]
	testing.expect_value(t, saved.name, "Notes")
	testing.expect_value(t, saved.icon.preset, 2)
	testing.expect_value(t, saved.icon.emoji, "🦊")
	testing.expect_value(t, saved.icon.tint, 3)
	testing.expect_value(t, saved.selected, 1)
	testing.expect(t, !saved.open)
	if !testing.expect_value(t, len(saved.tabs), 2) { return }
	testing.expect_value(t, saved.tabs[1].name, "Docs")
	nodes := saved.tabs[1].nodes
	if !testing.expect_value(t, len(nodes), 3) { return }
	testing.expect(t, nodes[0].split)
	testing.expect_value(t, nodes[0].ratio, f32(0.25))
	testing.expect_value(t, nodes[nodes[0].first].content, layout.Content_Kind.Settings)
	testing.expect_value(t, nodes[nodes[0].second].content, layout.Content_Kind.Terminal)
	testing.expect_value(t, saved.tabs[1].focus, nodes[0].first)
	tree: layout.Layout
	testing.expect(t, app.layout_tree_decode(&saved.tabs[1], &tree))
	layout.destroy(&tree)
}

@(private="file")
Restore_Fixture :: struct {
	state: app.App,
	ready: bool,
}

@(private="file")
restore_start :: proc(t: ^testing.T, f: ^Restore_Fixture, directory, layout_path: string, run: int) -> bool {
	f.state.options = {data_dir = directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.LayoutRestore.%d.%d", os.get_pid(), run)
	f.state.layout_path = strings.clone(layout_path)
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	f.ready = testing.expect(t, app.app_init(&f.state))
	return f.ready
}

@(test)
layout_state_restores_workspaces_tabs_and_directories :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-layout-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	layout_path := strings.concatenate({directory, "/layout.json"}, context.temp_allocator)
	pane_directory := strings.concatenate({directory, "\\work"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(pane_directory), nil)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) { return }

	first: Restore_Fixture
	if !restore_start(t, &first, directory, layout_path, 1) { app.app_destroy(&first.state); return }
	w := first.state.windows[0]
	app.pane_split(&first.state, w, .Right, 0.4)
	first_root := w.workspace.tabs[0].tree.root
	saved_ratio := w.workspace.tabs[0].tree.nodes[first_root].(layout.Split).ratio
	if !testing.expect(t, app.tab_create(&first.state, w.workspace, directory = pane_directory)) {
		app.app_destroy(&first.state)
		return
	}
	app.tab_select(&first.state, w, 1)
	w.workspace.tabs[1].name = strings.clone("Build")
	first.state.sessions[len(first.state.sessions) - 1].name = strings.clone("server")
	delete(w.workspace.name)
	w.workspace.name = strings.clone("Project")
	w.workspace.icon.tint = 4
	app.layout_state_save(&first.state)
	app.app_destroy(&first.state)
	_, read_error := os.stat(layout_path, context.temp_allocator)
	if !testing.expect_value(t, read_error, nil) { return }

	second: Restore_Fixture
	defer app.app_destroy(&second.state)
	if !restore_start(t, &second, directory, layout_path, 2) { return }
	if !testing.expect_value(t, len(second.state.workspaces), 1) { return }
	if !testing.expect_value(t, len(second.state.windows), 1) { return }
	workspace := second.state.workspaces[0]
	testing.expect_value(t, workspace.name, "Project")
	testing.expect_value(t, workspace.icon.tint, 4)
	testing.expect_value(t, workspace.selected, 1)
	testing.expect_value(t, second.state.windows[0].workspace, workspace)
	if !testing.expect_value(t, len(workspace.tabs), 2) { return }
	testing.expect_value(t, len(second.state.sessions), 3)
	split, is_split := workspace.tabs[0].tree.nodes[workspace.tabs[0].tree.root].(layout.Split)
	testing.expect(t, is_split)
	testing.expect_value(t, split.ratio, saved_ratio)
	testing.expect_value(t, workspace.tabs[1].name, "Build")
	pane := workspace.tabs[1].tree.nodes[workspace.tabs[1].tree.root].(layout.Pane)
	entry := app.session_find(&second.state, pane.content.id)
	if !testing.expect(t, entry != nil) { return }
	testing.expect_value(t, entry.name, "server")
	testing.expect_value(t, entry.header.launch_directory, pane_directory)
}

@(test)
layout_state_sets_aside_unreadable_files :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-layout-bad-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	layout_path := strings.concatenate({directory, "/layout.json"}, context.temp_allocator)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) { return }
	if !testing.expect_value(t, os.write_entire_file(layout_path, "{not json"), nil) { return }
	f: Restore_Fixture
	defer app.app_destroy(&f.state)
	if !restore_start(t, &f, directory, layout_path, 3) { return }
	testing.expect_value(t, len(f.state.workspaces), 1)
	testing.expect_value(t, len(f.state.workspaces[0].tabs), 1)
	kept := strings.concatenate({layout_path, ".bad"}, context.temp_allocator)
	testing.expect(t, os.exists(kept))
	testing.expect(t, !os.exists(layout_path))
}
