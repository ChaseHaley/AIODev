package app_test

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
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
	// Without aio's working directory, a new pane starts where the profile's panes do.
	profile_directory := state.sessions[0].header.launch_directory
	testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, profile_directory)
	// A remote working directory is refused as a remote --cwd is; the profile's is used (WORK-127).
	remote := app.control_cli_answer(&state, {"", "text", `\\server\share`, "tab.new"})
	testing.expectf(t, remote.ok, "tab.new from a share: %s", remote.text)
	testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, profile_directory)
	// A relative --cwd names a directory in aio's working directory, not in AIODev's.
	root, has_root := os.lookup_env("SystemRoot", context.temp_allocator)
	if testing.expect(t, has_root) {
		in_root := app.control_cli_answer(&state, {"", "text", root, "tab.new", "--cwd", "System32"})
		testing.expectf(t, in_root.ok, "tab.new --cwd System32: %s", in_root.text)
		system, _ := filepath.join({root, "System32"}, context.temp_allocator)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, system)

		// Without --cwd, a pane the request opens starts in aio's working directory (WORK-367).
		testing.expect(t, !strings.equal_fold(root, profile_directory))
		from_root := app.control_cli_answer(&state, {"", "text", root, "tab.new"})
		testing.expectf(t, from_root.ok, "tab.new from %s: %s", root, from_root.text)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, root)
		split_root := app.control_cli_answer(&state, {"", "text", root, "pane.split", "--pane", from_root.text})
		testing.expectf(t, split_root.ok, "pane.split from %s: %s", root, split_root.text)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, root)
		split_system := app.control_cli_answer(
			&state, {"", "text", root, "pane.split", "--pane", in_root.text, "--cwd", "System32"},
		)
		testing.expectf(t, split_system.ok, "pane.split --cwd System32: %s", split_system.text)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, system)
		// A float otherwise starts in its target's directory; aio's working directory comes first.
		float_root := app.control_cli_answer(&state, {"", "text", root, "pane.new_floating"})
		testing.expectf(t, float_root.ok, "pane.new_floating from %s: %s", root, float_root.text)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, root)

		// A key split still starts in its pane's directory, whatever the last request named.
		key_directory, _ := app.pane_directory(&state, app.focused_session(&state, w))
		testing.expect(t, key_directory != root)
		app.run_action(&state, w, .Split)
		testing.expect_value(t, state.sessions[len(state.sessions) - 1].header.launch_directory, key_directory)
	}
	usage := app.control_cli_answer(&state, {"", "text", "", "app.commands", "pane.send"})
	testing.expect(
		t,
		usage.ok && strings.has_prefix(usage.text, "pane.send [--pane <pane>] (<text> | --file <file>) [--enter]"),
	)
}

// A program's arguments and a pane's input come from files AIODev reads, so quotes, backslashes, a
// newline and non-ASCII text arrive byte for byte (WORK-366). The child reports what it received as
// base64, which pane.read shows as plain ASCII.
@(test)
control_commands_read_program_and_text_from_files :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-files-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	write :: proc(t: ^testing.T, directory, name, text: string) -> string {
		path, _ := filepath.join({directory, name}, context.temp_allocator)
		testing.expect_value(t, os.write_entire_file(path, text), nil)
		return path
	}
	write(t, directory, "settings.ini", idle_shell_settings(t, "cursor.blink = false\n"))
	script := write(
		t,
		directory,
		"argv.ps1",
		"$argument = [Environment]::GetCommandLineArgs()[-1]\n" +
		"Write-Output ('argv=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($argument)))\n" +
		"$line = $Host.UI.ReadLine()\n" +
		"Write-Output ('line=' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($line)))\n" +
		"$null = $Host.UI.ReadLine()\n",
	)
	argument :: "she said \"it's done\" \\\\server\\share C:\\dir with space\\ a\\\"b\nzweite Zeile \u00e9 \u65e5\u672c\\"
	command := []string{"pwsh.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, argument}
	command_json, marshal_error := json.marshal(command, allocator = context.temp_allocator)
	if !testing.expect_value(t, marshal_error, nil) { return }
	// Windows PowerShell's Set-Content -Encoding UTF8 starts a file with a byte order mark.
	write(t, directory, "argv.json", strings.concatenate({"\uFEFF", string(command_json)}, context.temp_allocator))
	prompt :: "it's \"quoted\" C:\\dir with space\\ \u00e9 \u65e5\u672c \\"
	write(t, directory, "prompt.txt", "\uFEFF" + prompt)
	write(t, directory, "bad.json", `["pwsh.exe", 3]`)

	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.CommandFiles.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }

	// Relative file names resolve against aio's working directory, as --cwd does.
	created := app.control_cli_answer(&state, {"", "text", directory, "tab.new", "--command-file", "argv.json"})
	if !testing.expectf(t, created.ok, "tab.new --command-file: %s", created.text) { return }
	pane, parsed := strconv.parse_uint(created.text, 10)
	if !testing.expect(t, parsed) { return }
	// Ticks free temporary memory, so what outlives one is owned.
	id := fmt.aprintf("%d", pane)
	defer delete(id)
	shown :: proc(state: ^app.App, id, label, text: string) -> bool {
		encoded := base64.encode(transmute([]u8)text, allocator = context.temp_allocator)
		marker := strings.concatenate({label, encoded})
		defer delete(marker)
		for deadline := time.tick_now(); time.tick_since(deadline) < 20 * time.Second; {
			app.tick(state)
			read := invoke(state, 0, "pane.read", "--pane", id)
			if read.status == .Ok {
				// A long marker wraps; the rows join with newlines.
				rows := string(read.payload.(app.Outcome_Text))
				screen, _ := strings.remove_all(rows, "\n", context.temp_allocator)
				if strings.contains(screen, marker) {return true}
			}
			time.sleep(50 * time.Millisecond)
		}
		return false
	}
	testing.expect(t, shown(&state, id, "argv=", argument), "the program's last argument arrived unchanged")

	sent := app.control_cli_answer(
		&state,
		{"", "text", directory, "pane.send", "--pane", id, "--enter", "--file", "prompt.txt"},
	)
	testing.expectf(t, sent.ok, "pane.send --file: %s", sent.text)
	testing.expect(t, shown(&state, id, "line=", prompt), "the text arrived unchanged, without its byte order mark")

	// Errors name the file; a bad file's content is a usage error, a missing file a failure.
	missing := app.control_cli_answer(&state, {"", "text", directory, "pane.send", "--pane", id, "--file", "gone.txt"})
	testing.expect_value(t, missing.status, u8(cli_protocol.Status.Failed))
	testing.expectf(t, strings.contains(missing.text, "gone.txt: no such file"), "missing: %s", missing.text)
	bad := app.control_cli_answer(&state, {"", "text", directory, "tab.new", "--command-file", "bad.json"})
	testing.expect_value(t, bad.status, u8(cli_protocol.Status.Usage))
	testing.expectf(t, strings.contains(bad.text, "bad.json: element 2 is not a string"), "bad: %s", bad.text)
	both := app.control_cli_answer(&state, {"", "text", directory, "tab.new", "--command-file", "argv.json", "--", "pwsh"})
	testing.expect_value(t, both.status, u8(cli_protocol.Status.Usage))
}

@(private = "file")
pane_workspace :: proc(state: ^app.App, id: u32) -> ^app.Workspace {
	workspace, _, _ := app.session_pane_find(state, id)
	return workspace
}

// What a command's dialog asks for can come on the command line instead, and then no dialog opens. A
// workspace target names an id or a name; a missing or ambiguous one changes nothing.
@(test)
control_dialog_commands_take_names_and_workspace_targets :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-dialog-arguments-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path, idle_shell_settings(t, "cursor.blink = false\n")), nil) {
		return
	}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.DialogArguments.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	w := state.windows[0]
	main := w.workspace
	first := state.sessions[0].id
	first_id := fmt.tprintf("%d", first)

	// Without a name, tab.rename still opens its dialog.
	testing.expect_value(t, invoke(&state, first, "tab.rename").status, cli_protocol.Status.Ok)
	testing.expect(t, app.rename_shown(w))
	app.rename_finish(&state, w, false)

	// Names on the command line open nothing and leave the window showing what it did.
	testing.expect_value(t, invoke(&state, first, "tab.rename", "Build").status, cli_protocol.Status.Ok)
	testing.expect_value(t, main.tabs[0].name, "Build")
	created := invoke(&state, first, "tab.new", "--name", "agent", "--tab-name", "Agents")
	testing.expect_value(t, created.status, cli_protocol.Status.Ok)
	agent := created.payload.(app.Outcome_Created).pane
	agent_id := fmt.tprintf("%d", agent)
	if !testing.expect_value(t, len(main.tabs), 2) { return }
	testing.expect_value(t, main.tabs[1].name, "Agents")
	testing.expect_value(t, app.session_find(&state, agent).name, "agent")
	testing.expect_value(t, invoke(&state, first, "workspace.rename", "Main").status, cli_protocol.Status.Ok)
	testing.expect_value(t, main.name, "Main")
	testing.expect(t, !app.rename_shown(w) && w.workspace == main && main.selected == 0)

	// A new workspace opens in the background under its name and reports its pane.
	opened := invoke(&state, first, "workspace.new", "--name", "Tools")
	testing.expect_value(t, opened.status, cli_protocol.Status.Ok)
	if !testing.expect_value(t, len(state.workspaces), 2) { return }
	tools := state.workspaces[1]
	testing.expect_value(t, tools.name, "Tools")
	testing.expect(t, pane_workspace(&state, opened.payload.(app.Outcome_Created).pane) == tools)
	testing.expect(t, app.window_for_workspace(&state, tools) == nil)
	testing.expect(t, !app.rename_shown(w) && w.workspace == main && main.selected == 0)

	// A name two workspaces share, and a name or id no workspace has, change nothing.
	testing.expect_value(t, invoke(&state, first, "workspace.new", "--name", "Tools").status, cli_protocol.Status.Ok)
	if !testing.expect_value(t, len(state.workspaces), 3) { return }
	spare := state.workspaces[2]
	shared := invoke(&state, first, "pane.move_workspace", "--pane", agent_id, "--workspace", "Tools")
	testing.expect_value(t, shared.status, cli_protocol.Status.Target)
	testing.expectf(t, strings.contains(shared.message, fmt.tprintf("%d", tools.id)) &&
		strings.contains(shared.message, fmt.tprintf("%d", spare.id)), "ambiguous: %s", shared.message)
	missing := invoke(&state, first, "workspace.rename", "--workspace", "Nowhere", "Renamed")
	testing.expect_value(t, missing.status, cli_protocol.Status.Target)
	testing.expect_value(t, invoke(&state, first, "workspace.change", "--workspace", "4000000").status,
		cli_protocol.Status.Target)
	testing.expect(t, w.workspace == main && main.selected == 0 && len(main.tabs) == 2)
	testing.expect(t, tools.name == "Tools" && spare.name == "Tools" && main.name == "Main")
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))

	// An id names a workspace too; a workspace needs a nonempty name.
	spare_id := fmt.tprintf("%d", spare.id)
	testing.expect_value(t, invoke(&state, first, "workspace.rename", "--workspace", spare_id, "Spare").status,
		cli_protocol.Status.Ok)
	testing.expect_value(t, invoke(&state, first, "workspace.rename", "--workspace", spare_id, " ").status,
		cli_protocol.Status.Usage)
	testing.expect_value(t, invoke(&state, first, "workspace.rename", "--workspace", spare_id).status,
		cli_protocol.Status.Usage)
	testing.expect_value(t, spare.name, "Spare")

	// Moves go where choosing the workspace in the dialog sends them, and the window follows them there.
	moved_tab := invoke(&state, first, "tab.move_workspace", "--pane", agent_id, "--workspace", "Tools")
	testing.expectf(t, moved_tab.status == .Ok, "tab.move_workspace: %s", moved_tab.message)
	testing.expect_value(t, len(main.tabs), 1)
	testing.expect(t, pane_workspace(&state, agent) == tools && w.workspace == tools)
	// Commands that run as from a key need their pane's workspace shown; the agent's tab now is.
	changed := invoke(&state, first, "workspace.change", "--pane", agent_id, "--workspace", "Main")
	testing.expectf(t, changed.status == .Ok, "workspace.change: %s", changed.message)
	testing.expect(t, w.workspace == main && !app.workspace_picker_active(&w.workspace_picker))
	split := invoke(&state, first, "pane.split", "--pane", first_id)
	testing.expect_value(t, split.status, cli_protocol.Status.Ok)
	split_pane := split.payload.(app.Outcome_Created).pane
	split_id := fmt.tprintf("%d", split_pane)
	moved_pane := invoke(&state, first, "pane.move_workspace", "--pane", split_id, "--workspace", "Spare")
	testing.expectf(t, moved_pane.status == .Ok, "pane.move_workspace: %s", moved_pane.message)
	testing.expect_value(t, app.tab_pane_count(main.tabs[0]), 1)
	testing.expect(t, pane_workspace(&state, split_pane) == spare && w.workspace == spare)
	again := invoke(&state, first, "pane.move_workspace", "--pane", split_id, "--workspace", "Spare")
	testing.expect_value(t, again.status, cli_protocol.Status.Failed)

	// --focus shows the new workspace in the window of the target pane, or the first window.
	shown := invoke(&state, first, "workspace.new", "--name", "Shown", "--focus")
	testing.expect_value(t, shown.status, cli_protocol.Status.Ok)
	testing.expect_value(t, w.workspace.name, "Shown")
	testing.expect(t, !app.rename_shown(w))
}
