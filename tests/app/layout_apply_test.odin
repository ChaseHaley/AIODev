package app_test

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:cli_protocol"
import "aio:layout"
import "aio:platform"

@(test)
layout_apply_opens_a_tab_of_named_panes_or_nothing :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-layout-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_path, _ := filepath.join({directory, "settings.ini"}, context.temp_allocator)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ninterface.font_size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings), nil) {return}
	layout_text :: `{"tab": "Review", "cwd": "..", "columns": [
		[{"name": "L1", "command": ["cmd.exe", "/k", "echo one"]}, {"name": "L2", "command": ["cmd.exe"]}],
		[{"name": "R1"}]
	]}`
	layout_path, _ := filepath.join({directory, "layout.json"}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(layout_path, layout_text), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.LayoutApply.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	workspace := state.windows[0].workspace
	// The layout's cwd ".." is relative to the folder holding the file. Panes start outside that folder,
	// so their programs never hold it open when it is deleted.
	cleaned, _ := filepath.clean(directory, context.temp_allocator)
	folder := filepath.dir(cleaned)

	// A relative file is aio's; the reply lists the new panes column by column, top to bottom.
	reply := app.control_cli_answer(&state, {"", "text", directory, "layout.apply", "layout.json"})
	if !testing.expectf(t, reply.ok, "layout.apply: %s", reply.text) {return}
	if !testing.expect_value(t, len(workspace.tabs), 2) {return}
	testing.expect_value(t, workspace.selected, 0)
	tab := workspace.tabs[1]
	testing.expect_value(t, tab.name, "Review")
	lines := strings.split(reply.text, "\n", context.temp_allocator)
	if !testing.expect_value(t, len(lines), 3) {return}
	Expected :: struct {
		name, command: string,
	}
	expected := [3]Expected{{"L1", `cmd.exe /k "echo one"`}, {"L2", "cmd.exe"}, {"R1", "pwsh.exe -NoLogo -NoProfile"}}
	nodes: [3]layout.Node_Id
	for line, i in lines {
		id, parsed := strconv.parse_uint(line, 10)
		if !testing.expectf(t, parsed, "pane id %q", line) {return}
		entry := app.session_find(&state, u32(id))
		if !testing.expect(t, entry != nil) {return}
		testing.expect_value(t, entry.name, expected[i].name)
		// A pwsh pane's line gains AIODev's prompt integration after the given program line.
		command := entry.header.command
		testing.expectf(t, strings.has_prefix(command, expected[i].command), "%s ran %q", entry.name, command)
		testing.expect_value(t, entry.header.launch_directory, folder)
		nodes[i] = layout.find_content(&tab.tree, {.Terminal, u32(id)})
	}
	// Two even columns; the left one's panes share its height evenly.
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(&tab.tree, {0, 0, 1200, 800}, 0, &rects)
	if !testing.expect_value(t, len(rects), 3) {return}
	for pane in rects {
		switch pane.node {
		case nodes[0]:
			testing.expect_value(t, pane.rect, layout.Rect{0, 0, 600, 400})
		case nodes[1]:
			testing.expect_value(t, pane.rect, layout.Rect{0, 400, 600, 400})
		case nodes[2]:
			testing.expect_value(t, pane.rect, layout.Rect{600, 0, 600, 800})
		case:
			testing.expectf(t, false, "unexpected pane %v", pane)
		}
	}
	json_reply := app.control_cli_answer(&state, {"", "json", directory, "layout.apply", "--focus", layout_path})
	testing.expectf(t, json_reply.ok && strings.contains(json_reply.text, `"panes":[{"id":`), "%s", json_reply.text)
	testing.expect_value(t, workspace.selected, 2)

	// A bad file, or a pane that cannot start, leaves the tabs and sessions as they were.
	tabs, sessions := len(workspace.tabs), len(state.sessions)
	Case :: struct {
		text:   string,
		status: cli_protocol.Status,
	}
	cases := [?]Case{
		{`{"columns": [[{"name": "x"}], [{"profile": "no-such-profile"}]]}`, .Failed},
		{`{"columns": [[{"name": "x", "cwd": "C:\\no\\such\\folder-365"}]]}`, .Failed},
		{`{"columns": [[{"name": "x"}], [{"command": ["no-such-program-365.exe"]}]]}`, .Failed},
		{`{"columns": [[{"name": "x"}]], "rows": 2}`, .Usage},
	}
	for item in cases {
		if !testing.expect_value(t, os.write_entire_file(layout_path, item.text), nil) {return}
		failed := app.control_cli_answer(&state, {"", "text", "", "layout.apply", layout_path})
		testing.expectf(t, failed.status == u8(item.status), "%s: %v %s", item.text, failed.status, failed.text)
		testing.expect(t, strings.contains(failed.text, "columns[") || strings.contains(failed.text, "rows"))
		testing.expect_value(t, len(workspace.tabs), tabs)
		testing.expect_value(t, len(state.sessions), sessions)
	}
	missing := app.control_cli_answer(&state, {"", "text", directory, "layout.apply", "missing.json"})
	testing.expect_value(t, missing.status, u8(cli_protocol.Status.Failed))
	testing.expect_value(t, len(workspace.tabs), tabs)
}
