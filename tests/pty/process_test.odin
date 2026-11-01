package pty_test

import "core:testing"
import "aio:pty"

@(test)
process_tree_tracks_children_and_shell_return :: proc(t: ^testing.T) {
	processes := [?]pty.Process_Info{
		{1, 0, "host"}, {2, 1, "pwsh.exe"}, {3, 2, "nvim.exe"},
		{4, 3, "rg.exe"}, {5, 1, "unrelated.exe"}, {6, 6, "self"}, {7, 8, "cycle"}, {8, 7, "cycle"},
	}
	testing.expect_value(t, pty.process_leaf(processes[:], 2), 3)
	testing.expect_value(t, pty.process_leaf(processes[:3], 2), 2)
	testing.expect_value(t, pty.process_leaf(processes[:2], 2), 1)
	testing.expect_value(t, pty.process_leaf(processes[:], 99), -1)
	testing.expect_value(t, pty.process_leaf(nil, 2), -1)
	testing.expect_value(t, pty.process_ancestor(processes[:], 3), 2)
	testing.expect_value(t, pty.process_ancestor(processes[:], 0), -1)
}

@(test)
process_program_prefers_reporters_then_the_shells_direct_child :: proc(t: ^testing.T) {
	processes := [?]pty.Process_Info{
		{1, 0, "aiodev.exe"}, {2, 1, "pwsh.exe"}, {3, 2, "node.exe"}, {4, 3, "codex.exe"},
		{5, 4, "git.exe"}, {6, 1, "claude.exe"},
	}
	// Without a report the direct child names the pane, not its helpers or a launched agent.
	testing.expect_value(t, pty.process_program(processes[:], 2, nil, 0), 2)
	// A reporter below a launcher wins, and is matched without its extension or letter case.
	testing.expect_value(t, pty.process_program(processes[:], 2, {"Codex"}, 0), 3)
	// Reports from programs outside this shell, or no longer running, fall back to the child.
	testing.expect_value(t, pty.process_program(processes[:], 2, {"claude", "nvim"}, 0), 2)
	testing.expect_value(t, pty.process_program(processes[:], 2, {"", "pwsh"}, 0), 2)
	// Earlier apps are preferred.
	testing.expect_value(t, pty.process_program(processes[:], 2, {"git", "codex"}, 0), 4)
	// With nothing below it, the shell keeps its own icon.
	testing.expect_value(t, pty.process_program(processes[:2], 2, {"pwsh"}, 0), -1)
	testing.expect_value(t, pty.process_program(nil, 2, nil, 0), -1)
}

@(test)
process_program_skips_console_hosts_and_keeps_a_sibling_choice :: proc(t: ^testing.T) {
	processes := [?]pty.Process_Info{
		{2, 1, "cmd.exe"}, {3, 2, "conhost.exe"}, {4, 2, "nvim.exe"}, {5, 2, "OpenConsole.exe"},
		{6, 2, "less.exe"}, {7, 7, "self"},
	}
	testing.expect_value(t, pty.process_program(processes[:4], 2, nil, 0), 2)
	testing.expect_value(t, pty.process_program(processes[:], 2, nil, 0), 4)
	testing.expect_value(t, pty.process_program(processes[:], 2, nil, 4), 2)
	testing.expect_value(t, pty.process_program(processes[:2], 2, nil, 0), -1)
	testing.expect_value(t, pty.process_program(processes[:], 7, {"self"}, 0), -1)
}

@(test)
launcher_arguments_name_the_program_they_run :: proc(t: ^testing.T) {
	for test in ([?]struct {
			arguments: []string,
			name:      string,
		} {
			{{"node", `C:\Users\me\AppData\Roaming\npm\node_modules\@openai\codex\bin\codex.js`}, "codex"},
			{{"node.exe", "--no-warnings", "/home/me/node_modules/@google/gemini-cli/dist/index.js"}, "gemini-cli"},
			{{"node", `C:\npm\node_modules\opencode-ai\bin\opencode`, "run"}, "opencode-ai"},
			{{"cmd.exe", "/d", "/s", "/c", `"C:\Program Files\nodejs\npx.cmd" vite`}, "npx"},
			{{"cmd", "/c", `C:\tools\codex.cmd --help`}, "codex"},
			{{"bun", "x", "tool"}, "x"},
			{{"node"}, ""},
			{{"node", "--inspect"}, ""},
			{nil, ""},
		}) {
		testing.expect_value(t, pty.process_script(test.arguments), test.name)
	}
}
