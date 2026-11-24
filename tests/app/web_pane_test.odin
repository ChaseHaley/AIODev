package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "cosmos:platform"
import "cosmos:search"

@(private = "file")
Web_Fixture :: struct {
	state:     app.App,
	directory: string,
}

@(private = "file")
web_fixture_start :: proc(t: ^testing.T, f: ^Web_Fixture, name: string, run := 1, directory := "") -> bool {
	if directory == "" {
		made, err := os.make_directory_temp("", "aio-web-pane-*", context.allocator)
		if !testing.expect_value(t, err, nil) {return false}
		f.directory = made
		path := strings.concatenate({made, "/settings.ini"}, context.temp_allocator)
		settings := idle_shell_settings(t, "cursor.blink = false\n")
		if !testing.expect_value(t, os.write_entire_file(path, settings), nil) {return false}
	} else {
		f.directory = directory
	}
	f.state.options = {data_dir = f.directory, inactive = true}
	f.state.app_id = fmt.aprintf("AIODev.Test.WebPane.%s.%d.%d", name, os.get_pid(), run)
	app.layout_state_enable(&f.state, strings.concatenate({f.directory, "/layout.json"}))
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	if !testing.expect(t, app.app_init(&f.state)) {return false}
	app.window_resize(&f.state, f.state.windows[0], 1600, 900)
	return true
}

@(private = "file")
web_fixture_stop :: proc(t: ^testing.T, f: ^Web_Fixture, remove := true) {
	app.app_destroy(&f.state)
	if remove {
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
}

// The nodes of a tree that hold a web pane, in node order.
@(private = "file")
web_nodes :: proc(tree: ^layout.Layout) -> [dynamic]layout.Node_Id {
	nodes := make([dynamic]layout.Node_Id, context.temp_allocator)
	for candidate, id in tree.nodes {
		pane, is_pane := candidate.(layout.Pane)
		if is_pane && pane.content.kind == .Web {append(&nodes, layout.Node_Id(id))}
	}
	return nodes
}

@(private = "file")
Web_Open_Record :: struct {
	uri:   string,
	calls: int,
}

@(private = "file")
Web_Open_Calls: Web_Open_Record

@(private = "file")
web_open_stub :: proc(uri: string) -> bool {
	Web_Open_Calls.uri = uri
	Web_Open_Calls.calls += 1
	return true
}

// Defect guard: a headless build has no WebView2, so a link must not become a pane that can only show a
// message; it goes to the default browser instead.
@(test)
web_target_goes_to_the_opener_when_webview_is_unsupported :: proc(t: ^testing.T) {
	f: Web_Fixture
	defer web_fixture_stop(t, &f)
	if !web_fixture_start(t, &f, "opener") {return}
	if !testing.expect(t, !platform.webview_supported(), "the headless backend hosts no web view") {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.pane.web_links = true
	s.opener.url = web_open_stub
	Web_Open_Calls = {}
	app.target_open(s, w, app.Web_Target{"https://example.com/docs"})
	testing.expect_value(t, len(s.web_panes), 0)
	testing.expect_value(t, Web_Open_Calls.calls, 1)
	testing.expect_value(t, Web_Open_Calls.uri, "https://example.com/docs")
	testing.expect_value(t, len(web_nodes(&w.workspace.tabs[0].tree)), 0)
}

@(test)
web_open_focused_splits_right_floats_on_request_and_splits_inside_a_float :: proc(t: ^testing.T) {
	f: Web_Fixture
	defer web_fixture_stop(t, &f)
	if !web_fixture_start(t, &f, "place") {return}
	s, w := &f.state, f.state.windows[0]
	tree := &w.workspace.tabs[0].tree
	terminal := tree.focus

	if !testing.expect(t, app.web_open_focused(s, w, "https://example.com/one")) {return}
	testing.expect_value(t, len(s.web_panes), 1)
	root, is_split := tree.nodes[tree.root].(layout.Split)
	if !testing.expect(t, is_split) {return}
	testing.expect_value(t, root.axis, layout.Axis.Horizontal)
	first, _ := tree.nodes[root.first].(layout.Pane)
	second, _ := tree.nodes[root.second].(layout.Pane)
	testing.expect_value(t, root.first, terminal)
	testing.expect_value(t, first.content.kind, layout.Content_Kind.Terminal)
	testing.expect_value(t, second.content.kind, layout.Content_Kind.Web)
	testing.expect_value(t, app.web_find(s, second.content.id).url, "https://example.com/one")
	testing.expect(t, !layout.is_floating(tree, root.second))
	testing.expect_value(t, tree.focus, root.second)

	// pane.web_floating floats the pane over the tiles; the tiled tree keeps its shape.
	s.settings.pane.web_floating = true
	if !testing.expect(t, app.web_open_focused(s, w, "https://example.com/two")) {return}
	if !testing.expect_value(t, len(web_nodes(tree)), 2) {return}
	// The focused pane was tiled, so the new pane floats.
	floating_node := tree.focus
	testing.expect(t, layout.is_floating(tree, floating_node))
	shown, _ := layout.float_counts(tree)
	testing.expect_value(t, shown, 1)
	pane, _ := tree.nodes[floating_node].(layout.Pane)
	testing.expect_value(t, app.web_find(s, pane.content.id).url, "https://example.com/two")

	// Inside a float, a web pane splits that float rather than starting another.
	if !testing.expect(t, app.web_open_focused(s, w, "https://example.com/three")) {return}
	testing.expect_value(t, len(web_nodes(tree)), 3)
	testing.expect(t, layout.is_floating(tree, tree.focus), "the new pane stays in the float")
	shown, _ = layout.float_counts(tree)
	testing.expect_value(t, shown, 1)
	pane, _ = tree.nodes[tree.focus].(layout.Pane)
	testing.expect_value(t, app.web_find(s, pane.content.id).url, "https://example.com/three")
}

@(test)
web_pane_url_zoom_and_documents_survive_a_layout_restart :: proc(t: ^testing.T) {
	first: Web_Fixture
	if !web_fixture_start(t, &first, "restore", 1) {
		app.app_destroy(&first.state)
		return
	}
	w := first.state.windows[0]
	if !testing.expect(t, app.web_open_focused(&first.state, w, "https://example.com/docs")) {
		web_fixture_stop(t, &first)
		return
	}
	zoomed := app.web_find(&first.state, w.workspace.tabs[0].tree.nodes[w.workspace.tabs[0].tree.focus].(layout.Pane).content.id)
	zoomed.zoom = 1.25
	app.documents_copy(&zoomed.documents, []app.Document{{target = "https://example.com/pinned"}})
	if !testing.expect(t, app.web_open_focused(&first.state, w, "https://example.org")) {
		web_fixture_stop(t, &first)
		return
	}
	text, encoded := app.layout_state_encode(&first.state, context.temp_allocator)
	testing.expect(t, encoded)
	// The encoder writes 0 for a zoom of 1 (the restore reads it back as 100%), so only the zoomed pane
	// carries a value.
	testing.expect_value(t, strings.count(text, `"web_zoom": 1.25`), 1)
	testing.expect_value(t, strings.count(text, `"web_zoom": 1.0`), 0)
	app.layout_state_save(&first.state)
	directory := first.directory
	app.app_destroy(&first.state)

	second: Web_Fixture
	defer web_fixture_stop(t, &second)
	if !web_fixture_start(t, &second, "restore", 2, directory) {return}
	s := &second.state
	if !testing.expect_value(t, len(s.web_panes), 2) {return}
	restored := 0
	for pane in s.web_panes {
		switch pane.url {
		case "https://example.com/docs":
			testing.expect_value(t, pane.zoom, 1.25)
			if testing.expect_value(t, len(pane.documents), 1) {
				testing.expect_value(t, pane.documents[0].target, "https://example.com/pinned")
			}
			restored += 1
		case "https://example.org":
			testing.expect_value(t, pane.zoom, 1.0)
			testing.expect_value(t, len(pane.documents), 0)
			restored += 1
		case:
			testing.expectf(t, false, "unexpected restored url %q", pane.url)
		}
	}
	testing.expect_value(t, restored, 2)
	tree := &s.windows[0].workspace.tabs[0].tree
	testing.expect_value(t, len(web_nodes(tree)), 2)
}

@(test)
web_zoom_step_walks_chromes_steps_and_clamps :: proc(t: ^testing.T) {
	testing.expect_value(t, app.web_zoom_step(1, 1), 1.1)
	testing.expect_value(t, app.web_zoom_step(1.1, 1), 1.25)
	testing.expect_value(t, app.web_zoom_step(1, -1), 0.9)
	testing.expect_value(t, app.web_zoom_step(5, 1), 5.0)
	testing.expect_value(t, app.web_zoom_step(0.25, -1), 0.25)
	testing.expect_value(t, app.web_zoom_step(1.25, 0), 1.0)
	testing.expect_value(t, app.web_zoom_step(0, 0), 1.0)
	// A zoom between steps lands on the next one in its direction.
	testing.expect_value(t, app.web_zoom_step(1.05, 1), 1.1)
	testing.expect_value(t, app.web_zoom_step(1.05, -1), 1.0)
}

@(test)
web_zoom_focused_changes_only_the_focused_web_panes_zoom :: proc(t: ^testing.T) {
	f: Web_Fixture
	defer web_fixture_stop(t, &f)
	if !web_fixture_start(t, &f, "zoom") {return}
	s, w := &f.state, f.state.windows[0]
	testing.expect(t, !app.web_zoom_focused(s, w, 1), "a terminal has no page to zoom")
	if !testing.expect(t, app.web_open_focused(s, w, "https://example.com")) {return}
	pane := app.web_focused_pane(s, w)
	if !testing.expect(t, pane != nil) {return}
	testing.expect(t, app.web_zoom_focused(s, w, 1))
	testing.expect_value(t, pane.zoom, 1.1)
	testing.expect(t, app.web_zoom_focused(s, w, 1))
	testing.expect_value(t, pane.zoom, 1.25)
	testing.expect(t, app.web_zoom_focused(s, w, -1))
	testing.expect_value(t, pane.zoom, 1.1)
	testing.expect(t, app.web_zoom_focused(s, w, 0))
	testing.expect_value(t, pane.zoom, 1.0)
}

@(test)
web_find_summary_maps_the_webview_index_to_a_zero_based_selection :: proc(t: ^testing.T) {
	none := app.Web_Pane{find_count = 0, find_index = -1}
	testing.expect_value(
		t,
		app.web_find_summary(&none),
		search.Summary{progress = .Complete, total = 0, selected = -1, order = .Document_Order},
	)
	third := app.Web_Pane{find_count = 5, find_index = 3}
	testing.expect_value(
		t,
		app.web_find_summary(&third),
		search.Summary{progress = .Complete, total = 5, selected = 2, order = .Document_Order},
	)
	first := app.Web_Pane{find_count = 2, find_index = 1}
	testing.expect_value(t, app.web_find_summary(&first).selected, 0)
	unselected := app.Web_Pane{find_count = 4, find_index = -1}
	testing.expect_value(t, app.web_find_summary(&unselected).selected, -1)
	testing.expect_value(t, app.web_find_summary(&unselected).total, 4)
	failed := app.Web_Pane{find_count = 3, find_index = 2, find_failed = true}
	testing.expect_value(t, app.web_find_summary(&failed).progress, search.Progress.Failed)
	testing.expect_value(t, app.web_find_summary(&failed).order, search.Order.Document_Order)
	testing.expect_value(t, app.web_find_summary(&failed).selected, -1)
}

// Only .html and .htm count as HTML files; their web pane address encodes the path as filename bytes and
// keeps a link's fragment.
@(test)
html_files_are_html_and_htm_and_open_at_their_file_url :: proc(t: ^testing.T) {
	for path in ([?]string{`C:\r\page.html`, `C:\r\PAGE.HTM`, `C:\r\old.htm`}) {
		testing.expectf(t, app.html_is_path(path), "%s is HTML", path)
	}
	for path in ([?]string{`C:\r\page.xhtml`, `C:\r\icon.svg`, `C:\r\page.html.txt`, `C:\r\html`, `C:\r\a.md`}) {
		testing.expectf(t, !app.html_is_path(path), "%s is not HTML", path)
	}
	url, ok := app.html_file_url(`C:\My Reports\agent #1.html`, "")
	testing.expect(t, ok)
	testing.expect_value(t, url, "file:///C:/My%20Reports/agent%20%231.html")
	url, ok = app.html_file_url(`D:\r\page.htm`, "results")
	testing.expect(t, ok)
	testing.expect_value(t, url, "file:///D:/r/page.htm#results")
}
