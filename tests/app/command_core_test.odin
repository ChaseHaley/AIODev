package app_test

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
	// Panes opened from here name the aio beside AIODev in AIODEV_CLI.
	delete(state.cli_directory)
	state.cli_directory = strings.clone(`C:\aio-cli-test`)
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

	// Text reaches the pane's shell, which learns its own id from AIODEV_PANE and its aio from AIODEV_CLI.
	id := strings.clone(fmt.tprintf("%d", split_pane))
	defer delete(id)
	expected := strings.clone(fmt.tprintf(`pane=%d cli=C:\aio-cli-test\aio.exe`, split_pane))
	defer delete(expected)
	echo :: `Write-Output "pane=$env:AIODEV_PANE cli=$env:AIODEV_CLI"`
	sent := invoke(&state, first, "pane.send", "--pane", id, "--enter", echo)
	testing.expectf(t, sent.status == .Ok, "pane.send: %v %s", sent.status, sent.message)
	seen := false
	for deadline := time.tick_now(); !seen && time.tick_since(deadline) < 15 * time.Second; {
		app.tick(&state)
		read := invoke(&state, 0, "pane.read", "--pane", id)
		seen = read.status == .Ok && strings.contains(string(read.payload.(app.Outcome_Text)), expected)
		if !seen { time.sleep(50 * time.Millisecond) }
	}
	testing.expect(t, seen, "the split pane printed its AIODEV_PANE and AIODEV_CLI")
	last := invoke(&state, 0, "pane.read", "--pane", id, "--lines", "1")
	testing.expect(t, !strings.contains(string(last.payload.(app.Outcome_Text)), "\n"))

	// Targets: the caller, a missing id, and a name two panes share.
	testing.expect_value(t, invoke(&state, 0, "pane.status", "--pane", "here").status, cli_protocol.Status.Target)
	here := invoke(&state, first, "pane.status")
	if testing.expect_value(t, len(here.payload.(app.Outcome_Panes)), 1) { testing.expect_value(t, here.payload.(app.Outcome_Panes)[0].id, first) }
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
	if testing.expect_value(t, len(ended.payload.(app.Outcome_Panes)), 1) { testing.expect_value(t, ended.payload.(app.Outcome_Panes)[0].status, "closed") }
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
	// aio compares this line with its own build to warn when the two differ.
	version := app.control_cli_answer(&state, {"", "text", "", "app.version"})
	testing.expectf(t, version.ok && strings.has_prefix(version.text, "AIODev dev (" + cli_protocol.BUILD_ID + ", "),
		"app.version: %s", version.text)
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
