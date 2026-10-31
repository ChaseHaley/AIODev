package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:commands"
import "aio:layout"
import "aio:platform"

@(private = "file")
invoke :: proc(state: ^app.App, caller: u32, args: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_invoke(state, nil, invocation, caller)
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
	testing.expect_value(t, listed.status, commands.Status.Ok)
	if !testing.expect_value(t, len(listed.panes), 1) { return }
	testing.expect_value(t, listed.panes[0].id, first)
	testing.expect_value(t, listed.panes[0].tab, 1)
	testing.expect_value(t, listed.panes[0].status, "running")

	// New panes open in the background: the window keeps its tab and focus.
	created := invoke(&state, first, "tab.new", "--name", "agent")
	testing.expect_value(t, created.status, commands.Status.Ok)
	tab_pane := created.pane
	testing.expect(t, tab_pane != 0 && tab_pane != first)
	if !testing.expect_value(t, len(workspace.tabs), 2) { return }
	testing.expect_value(t, workspace.selected, 0)
	split := invoke(&state, first, "pane.split", "--pane", "agent", "--direction", "down")
	testing.expect_value(t, split.status, commands.Status.Ok)
	split_pane := split.pane
	testing.expect_value(t, app.tab_pane_count(workspace.tabs[1]), 2)
	testing.expect_value(t, workspace.selected, 0)
	testing.expect(t, w.tree == &workspace.tabs[0].tree)

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
		seen = read.status == .Ok && strings.contains(read.text, expected)
		if !seen { time.sleep(50 * time.Millisecond) }
	}
	testing.expect(t, seen, "the split pane printed its AIODEV_PANE")
	last := invoke(&state, 0, "pane.read", "--pane", id, "--lines", "1")
	testing.expect(t, !strings.contains(last.text, "\n"))

	// Targets: the caller, a missing id, and a name two panes share.
	testing.expect_value(t, invoke(&state, 0, "pane.status", "--pane", "here").status, commands.Status.Target)
	here := invoke(&state, first, "pane.status")
	if testing.expect_value(t, len(here.panes), 1) { testing.expect_value(t, here.panes[0].id, first) }
	testing.expect_value(t, invoke(&state, first, "pane.status", "--pane", "4000000").status, commands.Status.Target)
	testing.expect_value(t, invoke(&state, first, "pane.rename", "--pane", id, "agent").status, commands.Status.Ok)
	ambiguous := invoke(&state, first, "pane.status", "--pane", "agent")
	testing.expect_value(t, ambiguous.status, commands.Status.Target)
	testing.expect(t, strings.contains(ambiguous.message, fmt.tprintf("%d", tab_pane)))

	// A command without a targeted form focuses its target first.
	testing.expect_value(t, invoke(&state, first, "pane.zoom", "--pane", id).status, commands.Status.Ok)
	testing.expect_value(t, workspace.selected, 1)
	focused := w.tree.nodes[w.tree.focus].(layout.Pane)
	testing.expect_value(t, focused.content.id, split_pane)
	testing.expect(t, w.tree.zoomed)

	sessions := len(state.sessions)
	testing.expect_value(t, invoke(&state, first, "pane.close", "--pane", id).status, commands.Status.Ok)
	testing.expect_value(t, len(state.sessions), sessions - 1)
	testing.expect_value(t, app.tab_pane_count(workspace.tabs[1]), 1)
	// A closed pane still reports how it ended; only pane.status looks past the open panes.
	ended := invoke(&state, first, "pane.status", "--pane", id)
	testing.expect_value(t, ended.status, commands.Status.Ok)
	if testing.expect_value(t, len(ended.panes), 1) { testing.expect_value(t, ended.panes[0].status, "closed") }
	testing.expect_value(t, invoke(&state, first, "pane.read", "--pane", id).status, commands.Status.Target)

	// The pipe's answers: malformed requests and grammar errors are usage errors.
	testing.expect_value(t, app.control_cli_answer(&state, {"", "text"}).status, u8(commands.Status.Usage))
	testing.expect_value(t, app.control_cli_answer(&state, {"x", "text", "pane.list"}).status,
		u8(commands.Status.Usage))
	testing.expect_value(t, app.control_cli_answer(&state, {"", "text", "pane.read", "--lines", "0"}).status,
		u8(commands.Status.Usage))
	reply := app.control_cli_answer(&state, {"", "json", "pane.list"})
	testing.expect(t, reply.ok && strings.contains(reply.text, `"panes":[`))
	created_reply := app.control_cli_answer(&state, {"", "text", "tab.new"})
	testing.expect(t, created_reply.ok && created_reply.text != "")
	usage := app.control_cli_answer(&state, {"", "text", "app.commands", "pane.send"})
	testing.expect(t, usage.ok && strings.has_prefix(usage.text, "pane.send [--pane <pane>] <text> [--enter]"))
}
