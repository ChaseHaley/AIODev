package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"

@(test)
closed_panes_and_tabs_reopen_in_place :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-reopen-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	settings := idle_shell_settings(t, "cursor.blink = false\ninterface.confirm = shell_switch, multiline_paste\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return}
	state: app.App
	state.options = {data_dir = directory, inactive = true}
	state.app_id = fmt.aprintf("AIODev.Test.Reopen.%d", os.get_pid())
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		delete(state.app_id)
		return
	}
	state.platform_ready = true
	defer app.app_destroy(&state)
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	workspace := w.workspace

	// Nothing closed yet: the request is answered without changes.
	app.closed_reopen(&state, w)
	testing.expect_value(t, len(state.sessions), 1)

	// A named pane closed from the left of a split returns there with its share.
	app.pane_split(&state, w, .Right, 0.5)
	app.pane_split(&state, w, .Down, 0.5)
	tree := &workspace.tabs[0].tree
	left := layout.Node_Id(0)
	pane := tree.nodes[left].(layout.Pane)
	entry := app.session_find(&state, pane.content.id)
	entry.name = strings.clone("left")
	testing.expect_value(t, len(state.sessions), 3)
	app.pane_close_at(&state, workspace, 0, left)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, len(state.closed), 1)
	app.closed_reopen(&state, w)
	testing.expect_value(t, len(state.closed), 0)
	testing.expect_value(t, len(state.sessions), 3)
	root, is_split := tree.nodes[tree.root].(layout.Split)
	if !testing.expect(t, is_split) {return}
	testing.expect_value(t, root.axis, layout.Axis.Horizontal)
	testing.expect_value(t, root.ratio, f32(0.5))
	first, first_pane := tree.nodes[root.first].(layout.Pane)
	if !testing.expect(t, first_pane) {return}
	testing.expect_value(t, tree.focus, root.first)
	reopened := app.session_find(&state, first.content.id)
	if !testing.expect(t, reopened != nil) {return}
	testing.expect_value(t, reopened.name, "left")
	_, second_split := tree.nodes[root.second].(layout.Split)
	testing.expect(t, second_split)

	// A closed split tab returns whole at its position.
	_, created := app.tab_create(&state, workspace)
	testing.expect(t, created)
	app.tab_close(&state, w, 0)
	testing.expect_value(t, len(workspace.tabs), 1)
	testing.expect_value(t, len(state.sessions), 1)
	app.closed_reopen(&state, w)
	testing.expect_value(t, len(workspace.tabs), 2)
	testing.expect_value(t, len(state.sessions), 4)
	testing.expect_value(t, workspace.selected, 0)
	panes := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(&workspace.tabs[0].tree, workspace.tabs[0].tree.root, &panes)
	testing.expect_value(t, len(panes), 3)
}

// The owner's report: a tab of five panes closed pane by pane, the last close closing the tab, came back
// as five tabs. Reopening each pane rebuilds the one tab, in its arrangement and at its position.
@(test)
panes_of_a_closed_tab_reopen_into_one_tab :: proc(t: ^testing.T) {
	state: app.App
	w, directory, ready := reopen_app(t, &state)
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	defer app.app_destroy(&state)
	if !ready {return}
	workspace := w.workspace
	original, ok := reopen_five_pane_tab(t, &state, w)
	if !ok {return}

	// Closed one by one; the last close closes the tab.
	for name in ([]string{"A", "E", "B", "C", "D"}) {
		tree := &workspace.tabs[1].tree
		node := reopen_node_named(&state, tree, name)
		if !testing.expectf(t, node != layout.INVALID_NODE, "pane %s", name) {return}
		app.pane_close_at(&state, workspace, 1, node)
	}
	testing.expect_value(t, len(workspace.tabs), 2)
	testing.expect_value(t, len(state.closed), 5)

	// The last pane closed comes back first as the tab, at its position; the rest join it.
	for _ in 0 ..< 5 {app.closed_reopen(&state, w)}
	testing.expect_value(t, len(state.closed), 0)
	if !testing.expect_value(t, len(workspace.tabs), 3) {return}
	testing.expect_value(t, workspace.selected, 1)
	testing.expect_value(t, reopen_describe(&state, &workspace.tabs[1].tree), original)
}

// A tab closed whole still returns in one step, and a pane closed from it before then rejoins it.
@(test)
panes_closed_before_their_tab_rejoin_it :: proc(t: ^testing.T) {
	state: app.App
	w, directory, ready := reopen_app(t, &state)
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	defer app.app_destroy(&state)
	if !ready {return}
	workspace := w.workspace
	original, ok := reopen_five_pane_tab(t, &state, w)
	if !ok {return}
	app.pane_close_at(&state, workspace, 1, reopen_node_named(&state, &workspace.tabs[1].tree, "E"))
	app.tab_close(&state, w, 1)
	testing.expect_value(t, len(workspace.tabs), 2)

	app.closed_reopen(&state, w)
	if !testing.expect_value(t, len(workspace.tabs), 3) {return}
	testing.expect_value(t, workspace.selected, 1)
	panes := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(&workspace.tabs[1].tree, workspace.tabs[1].tree.root, &panes)
	testing.expect_value(t, len(panes), 4)

	app.closed_reopen(&state, w)
	testing.expect_value(t, len(workspace.tabs), 3)
	testing.expect_value(t, reopen_describe(&state, &workspace.tabs[1].tree), original)
}

// Counts the web panes in a tree and returns the first one's address.
@(private = "file")
reopen_web_url :: proc(state: ^app.App, tree: ^layout.Layout) -> (url: string, count: int) {
	panes := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(tree, tree.root, &panes)
	for content in panes {
		if content.kind != .Web {continue}
		if count == 0 {url = app.web_find(state, content.id).url}
		count += 1
	}
	return
}

// A closed web pane comes back with its address beside the pane it was split from; a blank one is not kept.
@(test)
closed_web_pane_reopens_beside_its_neighbour :: proc(t: ^testing.T) {
	state: app.App
	w, directory, ready := reopen_app(t, &state)
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	defer app.app_destroy(&state)
	if !ready {return}
	workspace := w.workspace
	tree := &workspace.tabs[1].tree
	neighbour := tree.focus
	if !testing.expect(t, app.web_open_placed(&state, w, neighbour, "https://example.com/docs", .Split_Right)) {return}
	node: layout.Node_Id
	for candidate, id in tree.nodes {
		pane, is_pane := candidate.(layout.Pane)
		if is_pane && pane.content.kind == .Web {node = layout.Node_Id(id)}
	}
	app.pane_close_at(&state, workspace, 1, node)
	testing.expect_value(t, len(state.closed), 1)
	_, count := reopen_web_url(&state, tree)
	testing.expect_value(t, count, 0)

	app.closed_reopen(&state, w)
	url, reopened := reopen_web_url(&state, tree)
	if !testing.expect_value(t, reopened, 1) {return}
	testing.expect_value(t, url, "https://example.com/docs")
	root, is_split := tree.nodes[tree.root].(layout.Split)
	if !testing.expect(t, is_split) {return}
	first, _ := tree.nodes[root.first].(layout.Pane)
	second, _ := tree.nodes[root.second].(layout.Pane)
	testing.expect_value(t, first.content.kind, layout.Content_Kind.Terminal)
	testing.expect_value(t, second.content.kind, layout.Content_Kind.Web)

	// A pane that never went anywhere has nothing to bring back.
	app.web_open_blank(&state, w)
	for candidate, id in tree.nodes {
		pane, is_pane := candidate.(layout.Pane)
		if is_pane && pane.content.kind == .Web && app.web_find(&state, pane.content.id).url == "" {
			app.pane_close_at(&state, workspace, 1, layout.Node_Id(id))
			break
		}
	}
	testing.expect_value(t, len(state.closed), 0)
}

// A tab closed with a web pane in it returns with the pane.
@(test)
closed_tab_with_web_pane_reopens_it :: proc(t: ^testing.T) {
	state: app.App
	w, directory, ready := reopen_app(t, &state)
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	defer app.app_destroy(&state)
	if !ready {return}
	workspace := w.workspace
	tree := &workspace.tabs[1].tree
	if !testing.expect(t, app.web_open_placed(&state, w, tree.focus, "https://example.com/docs", .Split_Right)) {return}
	app.tab_close(&state, w, 1)
	testing.expect_value(t, len(workspace.tabs), 2)
	app.closed_reopen(&state, w)
	if !testing.expect_value(t, len(workspace.tabs), 3) {return}
	url, count := reopen_web_url(&state, &workspace.tabs[1].tree)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, url, "https://example.com/docs")
}

// An app with three tabs, the middle one shown, whose shells idle.
@(private = "file")
reopen_app :: proc(t: ^testing.T, state: ^app.App) -> (w: ^app.Window, directory: string, ok: bool) {
	directory_error: os.Error
	directory, directory_error = os.make_directory_temp("", "aio-reopen-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
	settings := idle_shell_settings(t, "cursor.blink = false\ninterface.confirm = shell_switch, multiline_paste\n")
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return}
	state.options = {data_dir = directory, inactive = true}
	state.app_id = fmt.aprintf("AIODev.Test.ReopenTab.%d.%p", os.get_pid(), state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(state)) {return}
	w = state.windows[0]
	// Room for five panes above the minimum size.
	app.window_resize(state, w, 3000, 1200)
	for _ in 0 ..< 2 {
		_, created := app.tab_create(state, w.workspace)
		if !testing.expect(t, created) {return}
	}
	app.tab_select(state, w, 1)
	return w, directory, true
}

// Splits the shown tab into A | (B / (C | (D / E))), panes named by letter, and describes it.
@(private = "file")
reopen_five_pane_tab :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window) -> (string, bool) {
	tree := &w.workspace.tabs[w.workspace.selected].tree
	directions := []layout.Direction{.Right, .Down, .Right, .Down}
	ratios := []f32{0.4, 0.5, 0.6, 0.3}
	for direction, i in directions {app.pane_split(state, w, direction, ratios[i])}
	panes := make([dynamic]layout.Content, context.temp_allocator)
	layout.contents(tree, tree.root, &panes)
	if !testing.expect_value(t, len(panes), 5) {return "", false}
	// Pane order follows the tree, left to right and top to bottom.
	names := []string{"A", "B", "C", "D", "E"}
	for content, i in panes {
		entry := app.session_find(state, content.id)
		entry.name = strings.clone(names[i])
	}
	described := reopen_describe(state, tree)
	testing.expect_value(t, described, "(H 0.60 A (V 0.50 B (H 0.40 C (V 0.70 D E))))")
	return described, true
}

@(private = "file")
reopen_node_named :: proc(state: ^app.App, tree: ^layout.Layout, name: string) -> layout.Node_Id {
	for node, id in tree.nodes {
		pane, is_pane := node.(layout.Pane)
		if !is_pane {continue}
		if entry := app.session_find(state, pane.content.id); entry != nil && entry.name == name {
			return layout.Node_Id(id)
		}
	}
	return layout.INVALID_NODE
}

// The tree's shape with splits' axes and ratios and panes' names, in temporary memory.
@(private = "file")
reopen_describe :: proc(state: ^app.App, tree: ^layout.Layout) -> string {
	b := strings.builder_make(context.temp_allocator)
	reopen_describe_node(state, tree, tree.root, &b)
	return strings.to_string(b)
}

@(private = "file")
reopen_describe_node :: proc(state: ^app.App, tree: ^layout.Layout, node: layout.Node_Id, b: ^strings.Builder) {
	switch n in tree.nodes[node] {
	case layout.Vacant:
		strings.write_string(b, "?")
	case layout.Pane:
		entry := app.session_find(state, n.content.id)
		strings.write_string(b, entry != nil ? entry.name : "?")
	case layout.Split:
		fmt.sbprintf(b, "(%s %.2f ", n.axis == .Horizontal ? "H" : "V", n.ratio)
		reopen_describe_node(state, tree, n.first, b)
		strings.write_string(b, " ")
		reopen_describe_node(state, tree, n.second, b)
		strings.write_string(b, ")")
	}
}
