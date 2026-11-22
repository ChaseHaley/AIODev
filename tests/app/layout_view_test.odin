package app_test

import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "cosmos:platform"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:testing"

@(private = "file")
layout_view_invoke :: proc(state: ^app.App, caller: u32, args: ..string) -> app.Outcome {
	invocation, invalid := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if invalid.advice != "" {return {status = .Usage, message = invalid.advice}}
	return app.command_execute(state, app.Control_Request{caller = caller, origin = .Cli}, invocation)
}

@(private = "file")
OK :: cli_protocol.Status.Ok

@(private = "file")
layout_view_status :: proc(state: ^app.App, caller: u32, args: ..string) -> cli_protocol.Status {
	return layout_view_invoke(state, caller, ..args).status
}

@(private = "file")
layout_view_snapshot :: proc(t: ^testing.T, state: ^app.App) -> cli_protocol.View_Report {
	reply := app.control_cli_answer(state, {"", "json", "", "app.view"})
	if !testing.expectf(t, reply.ok, "app.view: %s", reply.text) {return {}}
	document: cli_protocol.Reply_Json
	unmarshalled := json.unmarshal_string(reply.text, &document, allocator = context.temp_allocator)
	if !testing.expect_value(t, unmarshalled, nil) {
		return {}
	}
	view, has_view := document.view.?
	if !testing.expect(t, has_view) {return {}}
	return view
}

// The node at a 1-based position in the tab's nodes; the zero node for 0 or a position out of range.
@(private = "file")
layout_view_node :: proc(tab: cli_protocol.View_Tab_Report, at: int) -> cli_protocol.View_Node_Report {
	if at < 1 || at > len(tab.nodes) {return {}}
	return tab.nodes[at - 1]
}

@(private = "file")
layout_view_contains :: proc(tab: cli_protocol.View_Tab_Report, at: int, pane: u32) -> bool {
	if at < 1 || at > len(tab.nodes) {return false}
	node := tab.nodes[at - 1]
	return node.pane == pane || layout_view_contains(tab, node.first, pane) ||
		layout_view_contains(tab, node.second, pane)
}

@(test)
layout_view_round_trips_trees_floats_and_targeted_edits :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-view-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path, _ := filepath.join({directory, "settings.ini"}, context.temp_allocator)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ninterface.font_size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.LayoutView.%d", os.get_pid())
	defer app.app_destroy(&state)
	initialized := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, initialized, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	workspace := w.workspace
	original := state.sessions[0].id
	layout_json :: `{"tab":"Tree","root":{"split":"right","ratio":0.65,` +
		`"first":{"split":"down","ratio":0.4,"first":{"name":"A"},"second":{"name":"B"}},` +
		`"second":{"name":"C"}},"floats":[{"bounds":[0.1,0.2,0.4,0.5],"pane":{"name":"F"}}]}`
	applied := layout_view_invoke(&state, original, "layout.apply", "--layout", layout_json)
	if !testing.expectf(t, applied.status == .Ok, "layout.apply: %s", applied.message) {return}
	// The reply lives in temporary memory, which tick frees; only the ids are used after it.
	panes := slice.clone(([]cli_protocol.Pane_Report)(applied.payload.(app.Outcome_Layout)))
	defer delete(panes)
	if !testing.expect_value(t, len(panes), 4) {return}
	names := [4]string{"A", "B", "C", "F"}
	for pane, i in panes {testing.expect_value(t, pane.name, names[i])}
	testing.expect_value(t, workspace.selected, 0)
	app.tick(&state)
	view := layout_view_snapshot(t, &state)
	if !testing.expect_value(t, len(view.workspaces), 1) {return}
	if !testing.expect_value(t, len(view.workspaces[0].tabs), 2) {return}
	tab := view.workspaces[0].tabs[1]
	testing.expect_value(t, tab.name, "Tree")
	testing.expect_value(t, tab.index, 2)
	testing.expect_value(t, tab.view, "split")
	root := layout_view_node(tab, tab.root)
	if !testing.expect(t, root.first != 0 && root.second != 0) {return}
	left, right := layout_view_node(tab, root.first), layout_view_node(tab, root.second)
	testing.expect_value(t, root.split, "right")
	testing.expect(t, abs(root.ratio - 0.65) < 0.0001)
	testing.expect_value(t, left.split, "down")
	testing.expect(t, abs(left.ratio - 0.4) < 0.0001)
	testing.expect_value(t, layout_view_node(tab, left.first).pane, panes[0].id)
	testing.expect_value(t, layout_view_node(tab, left.second).pane, panes[1].id)
	testing.expect_value(t, right.pane, panes[2].id)
	if !testing.expect_value(t, len(tab.floats), 1) {return}
	testing.expect_value(t, tab.floats[0].bounds, [4]f32{0.1, 0.2, 0.4, 0.5})
	testing.expect_value(t, layout_view_node(tab, tab.floats[0].root).pane, panes[3].id)
	testing.expect(t, tab.floats[0].cells == nil)

	// All explicit float operations can edit a hidden tab without selecting it.
	float_id := fmt.tprintf("%d", panes[3].id)
	changed := layout_view_invoke(&state, original, "float.set_bounds", "--pane", float_id, "--bounds",
		"0.2,0.1,0.5,0.4")
	testing.expect_value(t, changed.status, cli_protocol.Status.Ok)
	extra := layout_view_invoke(&state, panes[0].id, "pane.split", "--float", "--bounds", "0.3,0.3,0.3,0.3")
	if !testing.expect_value(t, extra.status, cli_protocol.Status.Ok) {return}
	extra_pane := extra.payload.(app.Outcome_Created).pane
	restack_commands := [2]string{"float.raise", "float.lower"}
	for command in restack_commands {
		testing.expect_value(t, layout_view_status(&state, original, command, "--pane", float_id), OK)
		tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
		if !testing.expect_value(t, len(tab.floats), 2) {return}
		first_stack, extra_stack: u64
		for floating in tab.floats {
			floating_pane := layout_view_node(tab, floating.root).pane
			if floating_pane == panes[3].id {first_stack = floating.stack}
			if floating_pane == extra_pane {extra_stack = floating.stack}
		}
		testing.expect(t, command == "float.raise" ? first_stack > extra_stack : first_stack < extra_stack)
	}
	testing.expect_value(t, layout_view_status(&state, original, "float.minimize", "--pane", float_id), OK)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	testing.expect(t, tab.floats[0].minimized)
	testing.expect_value(t, layout_view_status(&state, original, "float.restore", "--pane", float_id), OK)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	testing.expect(t, !tab.floats[0].minimized)
	testing.expect_value(t, tab.floats[0].bounds, [4]f32{0.2, 0.1, 0.5, 0.4})
	testing.expect_value(t, workspace.selected, 0)

	// Cross-tab moves and non-floating operations fail before touching either tab.
	float_commands := [6]string {
		"float.set_bounds", "float.raise", "float.lower", "float.dock", "float.minimize", "float.restore",
	}
	for command in float_commands {
		bad_float: app.Outcome
		if command == "float.set_bounds" {
			bad_float = layout_view_invoke(&state, original, command, "--bounds", "0,0,0.5,0.5")
		} else {
			bad_float = layout_view_invoke(&state, original, command)
		}
		testing.expect_value(t, bad_float.status, cli_protocol.Status.Failed)
		testing.expect_value(t, bad_float.message, fmt.tprintf("%d is not floating", original))
	}
	cross_tab := layout_view_invoke(&state, panes[0].id, "pane.move", "--beside", fmt.tprintf("%d", original),
		"--direction", "right")
	testing.expect_value(t, cross_tab.status, cli_protocol.Status.Failed)

	b_id, c_id := fmt.tprintf("%d", panes[1].id), fmt.tprintf("%d", panes[2].id)
	testing.expect_value(t, layout_view_status(&state, original, "pane.move", "--pane", b_id, "--beside", c_id,
		"--direction", "right"), OK)
	testing.expect_value(t, layout_view_status(&state, original, "pane.set_ratio", "--pane", b_id,
		"--ratio", "0.3"), OK)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	root = layout_view_node(tab, tab.root)
	right = layout_view_node(tab, root.second)
	testing.expect_value(t, layout_view_node(tab, root.first).pane, panes[0].id)
	testing.expect_value(t, right.split, "right")
	testing.expect_value(t, layout_view_node(tab, right.first).pane, panes[2].id)
	testing.expect_value(t, layout_view_node(tab, right.second).pane, panes[1].id)
	testing.expect(t, abs(right.ratio - 0.7) < 0.0001)
	testing.expect_value(t, layout_view_status(&state, original, "pane.resize", "--pane", b_id,
		"--direction", "left", "--cells", "2"), OK)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	right = layout_view_node(tab, layout_view_node(tab, tab.root).second)
	testing.expect(t, right.ratio < 0.7)
	area := app.window_content_area_in(&state, w, .None)
	gap := app.window_gap(&state, w)
	parent_width := (area.width - gap) * 0.35 - gap
	testing.expect(t, abs((0.7 - right.ratio) * parent_width - 2 * w.metrics.cell_width) < 0.1)
	testing.expect_value(t, workspace.selected, 0)

	testing.expect_value(t, layout_view_status(&state, original, "float.dock", "--pane", float_id), OK)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	testing.expect_value(t, len(tab.floats), 1)
	testing.expect(t, layout_view_contains(tab, tab.root, panes[3].id))
	restored := layout_view_status(&state, original, "float.restore", "--pane", float_id)
	testing.expect_value(t, restored, cli_protocol.Status.Failed)

	// Showing the tab adds cell geometry; plain app.view is the view document itself.
	testing.expect_value(t, layout_view_status(&state, original, "pane.focus", "--pane", b_id), OK)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	testing.expect(t, tab.floats[0].cells != nil)
	extra_id := fmt.tprintf("%d", extra_pane)
	testing.expect_value(t, layout_view_invoke(&state, original, "float.set_bounds", "--pane", extra_id,
		"--bounds", "2,3,30,10", "--unit", "cells").status, cli_protocol.Status.Ok)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	cells, placed := tab.floats[0].cells.?
	testing.expect(t, placed)
	testing.expect_value(t, cells, [4]int{2, 3, 30, 10})
	testing.expect_value(t, layout_view_invoke(&state, original, "float.set_bounds", "--pane", extra_id,
		"--bounds", "-1,2,3,4").status, cli_protocol.Status.Ok)
	tab = layout_view_snapshot(t, &state).workspaces[0].tabs[1]
	testing.expect_value(t, tab.floats[0].bounds, [4]f32{0, 0, 1, 1})
	// The revision advances once per tick that finds the arrangement changed.
	app.tick(&state)
	testing.expect(t, layout_view_snapshot(t, &state).revision > view.revision)
	plain := app.control_cli_answer(&state, {"", "text", "", "app.view"})
	plain_view: cli_protocol.View_Report
	testing.expect(t, plain.ok)
	plain_unmarshalled := json.unmarshal_string(plain.text, &plain_view, allocator = context.temp_allocator)
	testing.expect_value(t, plain_unmarshalled, nil)
	testing.expect_value(t, len(plain_view.panes), len(state.sessions))
	// Invalid inline layouts, including bad profiles in floats, are all-or-nothing.
	tabs, sessions := len(workspace.tabs), len(state.sessions)
	invalid_layouts := [2]string {
		`{"root":{"split":"right","first":{}}}`,
		`{"root":{},"floats":[{"bounds":[0,0,0.5,0.5],"pane":{"profile":"missing-layout-view"}}]}`,
	}
	for invalid in invalid_layouts {
		failed := layout_view_invoke(&state, original, "layout.apply", "--layout", invalid)
		testing.expect(t, failed.status != .Ok)
		testing.expect_value(t, len(workspace.tabs), tabs)
		testing.expect_value(t, len(state.sessions), sessions)
	}
}
