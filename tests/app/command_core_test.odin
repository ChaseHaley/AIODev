package app_test

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:term"

@(private = "file")
invoke :: proc(state: ^app.App, caller: u32, args: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Control_Request{caller}, invocation)
}

@(test)
control_commands_target_panes_without_moving_focus :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-core-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ninterface.font_size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(path, settings), nil) { return }
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.CommandCore.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	testing.expect(t, state.cli == nil, "the CLI pipe stays closed until control.enabled is on")
	w := state.windows[0]
	workspace := w.workspace
	first := state.sessions[0].id

	listed := invoke(&state, 0, "pane.list")
	testing.expect_value(t, listed.status, cli_protocol.Status.Ok)
	if !testing.expect_value(t, len(listed.payload.(app.Outcome_Panes)), 1) { return }
	testing.expect_value(t, listed.payload.(app.Outcome_Panes)[0].id, first)
	testing.expect_value(t, listed.payload.(app.Outcome_Panes)[0].tab, 1)
	testing.expect_value(t, listed.payload.(app.Outcome_Panes)[0].status, "running")
	// The pane's process is reported without process.padding_groups, which these settings leave unset.
	testing.expect_value(t, state.settings.process.padding_groups, "")
	process := listed.payload.(app.Outcome_Panes)[0].process
	testing.expectf(t, strings.equal_fold(process, "pwsh.exe"), "pane.list process %q", process)

	// New panes open in the background: the window keeps its tab and focus.
	created := invoke(&state, first, "tab.new", "--name", "agent")
	testing.expect_value(t, created.status, cli_protocol.Status.Ok)
	tab_pane := created.payload.(app.Outcome_Created).pane
	testing.expect(t, tab_pane != 0 && tab_pane != first)
	if !testing.expect_value(t, len(workspace.tabs), 2) { return }
	testing.expect_value(t, workspace.selected, 0)
	split := invoke(&state, first, "pane.split", "--pane", "agent", "--direction", "down")
	testing.expect_value(t, split.status, cli_protocol.Status.Ok)
	split_pane := split.payload.(app.Outcome_Created).pane
	testing.expect_value(t, app.tab_pane_count(workspace.tabs[1]), 2)
	testing.expect_value(t, workspace.selected, 0)
	testing.expect(t, app.window_tree(w) == &workspace.tabs[0].tree)

	// Text reaches the pane's shell, which learns its own id from AIODEV_PANE.
	id := strings.clone(fmt.tprintf("%d", split_pane))
	defer delete(id)
	expected := strings.clone(fmt.tprintf("pane=%d", split_pane))
	defer delete(expected)
	sent := invoke(&state, first, "pane.send", "--pane", id, "--enter", `Write-Output "pane=$env:AIODEV_PANE"`)
	testing.expectf(t, sent.status == .Ok, "pane.send: %v %s", sent.status, sent.message)
	seen := false
	for deadline := time.tick_now(); !seen && time.tick_since(deadline) < 15 * time.Second; {
		app.tick(&state)
		read := invoke(&state, 0, "pane.read", "--pane", id)
		seen = read.status == .Ok && strings.contains(string(read.payload.(app.Outcome_Text)), expected)
		if !seen { time.sleep(50 * time.Millisecond) }
	}
	testing.expect(t, seen, "the split pane printed its AIODEV_PANE")
	last := invoke(&state, 0, "pane.read", "--pane", id, "--lines", "1")
	testing.expect(t, !strings.contains(string(last.payload.(app.Outcome_Text)), "\n"))

	// Targets: the caller, a missing id, and a name two panes share.
	testing.expect_value(t, invoke(&state, 0, "pane.status", "--pane", "here").status, cli_protocol.Status.Target)
	here := invoke(&state, first, "pane.status")
	testing.expect_value(t, here.payload.(app.Outcome_Pane_Status).id, first)
	testing.expect_value(t, invoke(&state, first, "pane.status", "--pane", "4000000").status, cli_protocol.Status.Target)
	testing.expect_value(t, invoke(&state, first, "pane.rename", "--pane", id, "agent").status, cli_protocol.Status.Ok)
	ambiguous := invoke(&state, first, "pane.status", "--pane", "agent")
	testing.expect_value(t, ambiguous.status, cli_protocol.Status.Target)
	testing.expect(t, strings.contains(ambiguous.message, fmt.tprintf("%d", tab_pane)))

	// A command without a targeted form focuses its target first.
	testing.expect_value(t, invoke(&state, first, "pane.zoom", "--pane", id).status, cli_protocol.Status.Ok)
	testing.expect_value(t, workspace.selected, 1)
	shown := app.window_tree(w)
	focused := shown.nodes[shown.focus].(layout.Pane)
	testing.expect_value(t, focused.content.id, split_pane)
	testing.expect(t, shown.zoomed)

	// A targeted minimize command restores a minimized float instead of focusing and hiding it again.
	floating := invoke(&state, first, "pane.new_floating", "--pane", id)
	testing.expect_value(t, floating.status, cli_protocol.Status.Ok)
	float_id := strings.clone(fmt.tprintf("%d", floating.payload.(app.Outcome_Created).pane))
	defer delete(float_id)
	testing.expect_value(
		t, invoke(&state, first, "pane.minimize_floating", "--pane", float_id).status, cli_protocol.Status.Ok,
	)
	float_node := layout.find_content(shown, {.Terminal, floating.payload.(app.Outcome_Created).pane})
	float_state, float_ok := layout.float_of(shown, float_node)
	testing.expect(t, float_ok && float_state.minimized)
	testing.expect_value(
		t, invoke(&state, first, "pane.minimize_floating", "--pane", float_id).status, cli_protocol.Status.Ok,
	)
	float_state, float_ok = layout.float_of(shown, float_node)
	testing.expect(t, float_ok && !float_state.minimized)
	float_split := invoke(&state, first, "pane.split", "--pane", float_id, "--direction", "right")
	testing.expect_value(t, float_split.status, cli_protocol.Status.Ok)
	float_split_node := layout.find_content(shown, {.Terminal, float_split.payload.(app.Outcome_Created).pane})
	testing.expect_value(t, layout.float_root(shown, float_split_node), layout.float_root(shown, float_node))
	float_split_id := strings.clone(fmt.tprintf("%d", float_split.payload.(app.Outcome_Created).pane))
	defer delete(float_split_id)
	testing.expect_value(
		t, invoke(&state, first, "pane.close", "--pane", float_split_id).status, cli_protocol.Status.Ok,
	)
	testing.expect_value(t, invoke(&state, first, "pane.close", "--pane", float_id).status, cli_protocol.Status.Ok)

	sessions := len(state.sessions)
	testing.expect_value(t, invoke(&state, first, "pane.close", "--pane", id).status, cli_protocol.Status.Ok)
	testing.expect_value(t, len(state.sessions), sessions - 1)
	testing.expect_value(t, app.tab_pane_count(workspace.tabs[1]), 1)
	// A closed pane still reports how it ended; only pane.status looks past the open panes.
	ended := invoke(&state, first, "pane.status", "--pane", id)
	testing.expect_value(t, ended.status, cli_protocol.Status.Ok)
	testing.expect_value(t, ended.payload.(app.Outcome_Pane_Status).status, "closed")
	testing.expect_value(t, invoke(&state, first, "pane.read", "--pane", id).status, cli_protocol.Status.Target)

	// The pipe's answers: malformed requests and grammar errors are usage errors.
	testing.expect_value(t, app.control_cli_answer(&state, {"", "text", ""}).status,
		u8(cli_protocol.Status.Usage))
	testing.expect_value(t, app.control_cli_answer(&state, {"x", "text", "", "pane.list"}).status,
		u8(cli_protocol.Status.Usage))
	testing.expect_value(t, app.control_cli_answer(&state, {"", "text", "", "pane.read", "--lines", "0"}).status,
		u8(cli_protocol.Status.Usage))
	reply := app.control_cli_answer(&state, {"", "json", "", "pane.list"})
	testing.expect(t, reply.ok && strings.contains(reply.text, `"panes":[`))
	created_reply := app.control_cli_answer(&state, {"", "text", "", "tab.new"})
	testing.expect(t, created_reply.ok && created_reply.text != "")
	// A relative --cwd names a directory in aio's working directory, not in AIODev's.
	root, has_root := os.lookup_env("SystemRoot", context.temp_allocator)
	if testing.expect(t, has_root) {
		in_root := app.control_cli_answer(&state, {"", "text", root, "tab.new", "--cwd", "System32"})
		testing.expectf(t, in_root.ok, "tab.new --cwd System32: %s", in_root.text)
		system, _ := filepath.join({root, "System32"}, context.temp_allocator)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, system)
	}
	usage := app.control_cli_answer(&state, {"", "text", "", "app.commands", "pane.send"})
	testing.expect(t, usage.ok && strings.has_prefix(usage.text, "pane.send [--pane <pane>] <text> [--enter]"))
}

@(test)
control_lists_report_programs_geometry_tabs_and_workspaces :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-lists-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ninterface.font_size = 12\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(path, settings), nil) { return }
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.CommandLists.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	w := state.windows[0]
	workspace := w.workspace
	first := state.sessions[0].id
	split := invoke(&state, first, "pane.split", "--direction", "right")
	if !testing.expect_value(t, split.status, cli_protocol.Status.Ok) { return }
	second := split.payload.(app.Outcome_Created).pane
	second_id := strings.clone(fmt.tprintf("%d", second))
	defer delete(second_id)
	testing.expect_value(t, invoke(&state, first, "tab.new").status, cli_protocol.Status.Ok)

	// The second shell runs ping; the first stays at its prompt, so it names itself.
	sent := invoke(&state, first, "pane.send", "--pane", second_id, "--enter", "ping.exe -n 60 127.0.0.1")
	testing.expectf(t, sent.status == .Ok, "pane.send: %v %s", sent.status, sent.message)
	panes: app.Outcome_Panes
	for deadline := time.tick_now(); time.tick_since(deadline) < 15 * time.Second; {
		app.tick(&state)
		panes = invoke(&state, 0, "pane.list").payload.(app.Outcome_Panes)
		if len(panes) == 3 && strings.equal_fold(panes[1].process, "ping.exe") { break }
		time.sleep(50 * time.Millisecond)
	}
	if !testing.expect_value(t, len(panes), 3) { return }
	left, right := panes[0], panes[1]
	testing.expect_value(t, right.id, second)
	testing.expectf(t, strings.equal_fold(right.process, "ping.exe"), "running program %q", right.process)
	testing.expectf(t, strings.equal_fold(left.process, "pwsh.exe"), "idle shell %q", left.process)
	left_pid, left_has_pid := left.pid.?
	right_pid, right_has_pid := right.pid.?
	testing.expect(t, left_has_pid && left_pid == term.process_id(state.sessions[0].session))
	testing.expect(t, right_has_pid && right_pid != left_pid)
	testing.expect_value(t, left.tab_name, app.tab_display_title(workspace.tabs[0], 1))
	testing.expect_value(t, panes[2].tab, 2)

	// Side by side across the window's pane area, one gap apart, in DIPs.
	area := app.window_content_area_in(&state, w, .None)
	width, height := int(area.width / w.scale), int(area.height / w.scale)
	gap := int(app.window_gap(&state, w) / w.scale)
	left_rect, left_placed := left.rect.?
	right_rect, right_placed := right.rect.?
	if !testing.expect(t, left_placed && right_placed) { return }
	testing.expect_value(t, left_rect.x, 0)
	testing.expect_value(t, left_rect.y, 0)
	testing.expect_value(t, right_rect.y, 0)
	testing.expectf(t, abs(right_rect.x - (left_rect.width + gap)) <= 1, "%v then %v", left_rect, right_rect)
	testing.expectf(t, abs(right_rect.x + right_rect.width - width) <= 1, "%v ends at %d", right_rect, width)
	testing.expectf(t, abs(left_rect.height - height) <= 1 && left_rect.height == right_rect.height,
		"%v and %v in %d", left_rect, right_rect, height)
	left_grid, left_sized := left.grid.?
	right_grid, right_sized := right.grid.?
	testing.expect(t, left_sized && right_sized && left_grid.columns > 0 && left_grid.rows == right_grid.rows)

	tabs := invoke(&state, 0, "tab.list").payload.(app.Outcome_Tabs)
	if testing.expect_value(t, len(tabs), 2) {
		testing.expect_value(t, tabs[0], cli_protocol.Tab_Report{
			workspace = workspace.id, workspace_name = workspace.name, tab = 1, name = left.tab_name,
			panes = 2, selected = true, focused = w.focused,
		})
		testing.expect_value(t, tabs[1].tab, 2)
		testing.expect_value(t, tabs[1].panes, 1)
		testing.expect(t, !tabs[1].selected && !tabs[1].focused)
	}
	workspaces := invoke(&state, 0, "workspace.list").payload.(app.Outcome_Workspaces)
	if testing.expect_value(t, len(workspaces), 1) {
		testing.expect_value(t, workspaces[0], cli_protocol.Workspace_Report{
			id = workspace.id, name = workspace.name, window = true, visible = app.window_drawable(w),
			tabs = 2, focused = w.focused,
		})
	}

	// Plain lists name their columns first and mark empty fields.
	plain := app.control_cli_answer(&state, {"", "text", "", "pane.list"}).text
	lines := strings.split_lines(plain, context.temp_allocator)
	if testing.expect_value(t, len(lines), 4) {
		testing.expect(t, strings.has_prefix(lines[0], "id\tfocused\tworkspace\ttab\tstatus\tprocess"))
		testing.expect_value(t, strings.count(lines[1], "\t"), strings.count(lines[0], "\t"))
	}
	testing.expectf(t, !strings.contains(plain, "\t\t") && !strings.has_suffix(plain, "\t"), "%q", plain)
	tab_lines := app.control_cli_answer(&state, {"", "text", "", "tab.list"}).text
	testing.expect(t, strings.has_prefix(tab_lines, "workspace\ttab\tfocused\tselected\tpanes\tname\n"))

	// A failure carries only ok, status and the error; aio reads a pane's status back from JSON.
	missing := app.control_cli_answer(&state, {"", "json", "", "pane.read", "--pane", "4000000"})
	testing.expect_value(t, missing.text, `{"ok":false,"status":3,"error":"no pane has that id; use aio pane.list"}`)
	status := app.control_cli_answer(&state, {"", "json", "", "pane.status", "--pane", second_id})
	reply: cli_protocol.Reply_Json
	unmarshal_error := json.unmarshal_string(status.text, &reply, allocator = context.temp_allocator)
	if testing.expect_value(t, unmarshal_error, nil) && testing.expect_value(t, len(reply.panes), 1) {
		read_rect, read_placed := reply.panes[0].rect.?
		read_pid, _ := reply.panes[0].pid.?
		testing.expect(t, read_placed && read_rect == right_rect && read_pid == right_pid)
		testing.expect(t, reply.ok && reply.commands == nil && reply.pane == nil)
	}
}
