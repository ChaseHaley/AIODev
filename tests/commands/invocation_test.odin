package commands_test

import "core:testing"
import "aio:commands"
import "aio:layout"

@(private)
invocation_registry :: proc(t: ^testing.T) -> commands.Registry {
	registry := commands.create()
	items := [?]commands.Command{
		{id = 1, name = "tab.next", title = "Next Tab"},
		{
			id = 2,
			name = "pane.split",
			title = "Split Pane",
			arguments = {.Direction, .Ratio, .Focus, .Directory, .Name, .Profile, .Program},
		},
		{
			id = 3,
			name = "pane.send",
			title = "Send Text",
			arguments = {.Text, .Enter},
			required = {.Text},
			hidden = true,
		},
		{id = 4, name = "pane.read", title = "Read Pane", arguments = {.Lines}, hidden = true},
		{id = 5, name = "pane.open_markdown", title = "Open Markdown", arguments = {.File, .Direction, .Focus}},
		{id = 6, name = "workspace.rename", title = "Rename Workspace", arguments = {.Text, .Workspace}},
		{id = 7, name = "tab.new", title = "New Tab", arguments = {.Focus, .Name, .Program, .Tab_Name}},
	}
	for item in items {testing.expect_value(t, commands.register(&registry, item), commands.Error.None)}
	return registry
}

@(test)
invocation_defaults_split_right_half :: proc(t: ^testing.T) {
	key := commands.invocation(7, focus = true)
	testing.expect_value(t, key.id, commands.Command_Id(7))
	testing.expect_value(t, key.direction, layout.Direction.Right)
	testing.expect_value(t, key.ratio, f32(0.5))
	testing.expect(t, key.focus)
	testing.expect(t, !commands.invocation(7, focus = false).focus)
}

@(test)
invocation_parses_every_argument :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	args := [?]string{
		"pane.split", "--pane", "build", "--direction", "down", "--ratio", "0.3", "--focus",
		"--cwd", `C:\work`, "--name", "agent", "--profile", "pwsh", "--", "claude", "--model", "two words",
	}
	result, err := commands.parse_invocation(&registry, args[:], context.temp_allocator)
	testing.expect_value(t, err, commands.Parse_Error{})
	testing.expect_value(t, result.id, commands.Command_Id(2))
	testing.expect_value(t, result.pane, "build")
	testing.expect_value(t, result.direction, layout.Direction.Down)
	testing.expect_value(t, result.ratio, f32(0.3))
	testing.expect(t, result.focus)
	testing.expect_value(t, result.directory, `C:\work`)
	testing.expect_value(t, result.name, "agent")
	testing.expect_value(t, result.profile, "pwsh")
	testing.expect_value(t, result.program, `claude --model "two words"`)
	testing.expect_value(
		t,
		result.given,
		commands.Arguments{.Direction, .Ratio, .Focus, .Directory, .Name, .Profile, .Program},
	)
	send := [?]string{"pane.send", "--enter", "echo hi"}
	sent, send_error := commands.parse_invocation(&registry, send[:], context.temp_allocator)
	testing.expect_value(t, send_error, commands.Parse_Error{})
	testing.expect_value(t, sent.text, "echo hi")
	testing.expect(t, sent.enter && !sent.focus)
	plain := [?]string{"tab.next"}
	next, next_error := commands.parse_invocation(&registry, plain[:], context.temp_allocator)
	testing.expect_value(t, next_error, commands.Parse_Error{})
	testing.expect_value(t, next.given, commands.Arguments{})
	testing.expect_value(t, next.pane, "")
}

@(test)
invocation_rejects_bad_command_lines :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	Case :: struct {
		args:     []string,
		argument: string,
	}
	cases := [?]Case{
		{{}, "<command>"},
		{{""}, "<command>"},
		{{"pane.missing"}, "pane.missing"},
		{{"tab.next", "--direction", "left"}, "--direction"},
		{{"tab.next", "stray"}, "stray"},
		{{"tab.next", "--"}, "--"},
		{{"pane.split", "--"}, "--"},
		{{"pane.split", "--direction", "sideways"}, "sideways"},
		{{"pane.split", "--direction"}, "--direction"},
		{{"pane.split", "--ratio", "0.99"}, "0.99"},
		{{"pane.split", "--ratio", "nan"}, "nan"},
		{{"pane.split", "--focus", "--focus"}, "--focus"},
		{{"pane.split", "--cwd", ""}, "--cwd"},
		{{"pane.split", "--pane"}, "--pane"},
		{{"pane.split", "--pane", ""}, "--pane"},
		{{"pane.split", "--pane", "a", "--pane", "b"}, "--pane"},
		{{"pane.split", "--unknown"}, "--unknown"},
		{{"pane.send"}, "<text>"},
		{{"pane.send", "--enter"}, "<text>"},
		{{"pane.send", "one", "two"}, "two"},
		{{"pane.open_markdown", "one.md", "two.md"}, "two.md"},
		{{"pane.read", "--lines", "0"}, "0"},
		{{"pane.read", "--lines", "10001"}, "10001"},
		{{"pane.read", "--lines", "-3"}, "-3"},
		{{"workspace.rename", "--workspace"}, "--workspace"},
		{{"workspace.rename", "--workspace", ""}, "--workspace"},
		{{"workspace.rename", "--workspace", "a", "--workspace", "b"}, "--workspace"},
		{{"workspace.rename", "--tab-name", "Build"}, "--tab-name"},
		{{"tab.new", "--tab-name", ""}, "--tab-name"},
		{{"tab.new", "--tab-name", "a", "--tab-name", "b"}, "--tab-name"},
		{{"tab.new", "--workspace", "Tools"}, "--workspace"},
	}
	for item in cases {
		_, err := commands.parse_invocation(&registry, item.args, context.temp_allocator)
		testing.expectf(t, err.argument == item.argument && err.advice != "", "%v gave %v", item.args, err)
	}
}

@(test)
invocation_usage_names_accepted_arguments :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	testing.expect_value(
		t,
		commands.usage(commands.find(&registry, "pane.send"), context.temp_allocator),
		"pane.send [--pane <pane>] <text> [--enter]",
	)
	testing.expect_value(
		t,
		commands.usage(commands.find(&registry, "tab.next"), context.temp_allocator),
		"tab.next [--pane <pane>]",
	)
	testing.expect_value(
		t,
		commands.usage(commands.find(&registry, "pane.read"), context.temp_allocator),
		"pane.read [--pane <pane>] [--lines <rows>]",
	)
	testing.expect_value(
		t,
		commands.usage(commands.find(&registry, "pane.open_markdown"), context.temp_allocator),
		"pane.open_markdown [--pane <pane>] [--direction left|right|up|down] [--focus] [<file>]",
	)
	testing.expect_value(
		t,
		commands.usage(commands.find(&registry, "workspace.rename"), context.temp_allocator),
		"workspace.rename [--pane <pane>] [<text>] [--workspace <workspace>]",
	)
}

// --tab-name names the new tab beside --name for its pane; --workspace takes any nonempty word, digits
// included, which the app resolves as an id or a name.
@(test)
invocation_parses_tab_names_and_workspace_targets :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	open := [?]string{"tab.new", "--name", "agent", "--tab-name", "Build", "--", "pwsh.exe"}
	opened, open_error := commands.parse_invocation(&registry, open[:], context.temp_allocator)
	testing.expect_value(t, open_error, commands.Parse_Error{})
	testing.expect_value(t, opened.name, "agent")
	testing.expect_value(t, opened.tab_name, "Build")
	testing.expect_value(t, opened.program, "pwsh.exe")
	testing.expect_value(t, opened.given, commands.Arguments{.Name, .Program, .Tab_Name})
	rename := [?]string{"workspace.rename", "--workspace", "Tools", "Agents"}
	renamed, rename_error := commands.parse_invocation(&registry, rename[:], context.temp_allocator)
	testing.expect_value(t, rename_error, commands.Parse_Error{})
	testing.expect_value(t, renamed.workspace, "Tools")
	testing.expect_value(t, renamed.text, "Agents")
	testing.expect_value(t, renamed.given, commands.Arguments{.Text, .Workspace})
	numbered := [?]string{"workspace.rename", "--pane", "here", "--workspace", "2"}
	by_id, id_error := commands.parse_invocation(&registry, numbered[:], context.temp_allocator)
	testing.expect_value(t, id_error, commands.Parse_Error{})
	testing.expect_value(t, by_id.workspace, "2")
	testing.expect_value(t, by_id.pane, "here")
	testing.expect_value(t, by_id.given, commands.Arguments{.Workspace})
}

// Path-ness follows the argument kind: --cwd and a command's file resolve against the sender's
// directory wherever they appear, while text and other values stay as given.
@(test)
invocation_paths_resolve_against_the_senders_directory :: proc(t: ^testing.T) {
	registry := invocation_registry(t)
	defer commands.destroy(&registry)
	open := [?]string{"pane.open_markdown", "--pane", "agent", "--direction", "down", `docs\plan.md`}
	file, file_error := commands.parse_invocation(&registry, open[:], context.temp_allocator)
	testing.expect_value(t, file_error, commands.Parse_Error{})
	testing.expect_value(t, file.given, commands.Arguments{.Direction, .File})
	testing.expect_value(t, commands.invocation_paths_resolve(&file, `C:\work`, context.temp_allocator), nil)
	testing.expect_value(t, file.file, `C:\work\docs\plan.md`)
	testing.expect_value(t, file.pane, "agent")
	split := [?]string{"pane.split", "--cwd", `..\other`, "--name", "build"}
	relative, relative_error := commands.parse_invocation(&registry, split[:], context.temp_allocator)
	testing.expect_value(t, relative_error, commands.Parse_Error{})
	resolved := commands.invocation_paths_resolve(&relative, `C:\work\repo`, context.temp_allocator)
	testing.expect_value(t, resolved, nil)
	testing.expect_value(t, relative.directory, `C:\work\other`)
	testing.expect_value(t, relative.name, "build")
	absolute := [?]string{"pane.split", "--cwd", `D:\code`}
	kept, _ := commands.parse_invocation(&registry, absolute[:], context.temp_allocator)
	testing.expect_value(t, commands.invocation_paths_resolve(&kept, `C:\work`, context.temp_allocator), nil)
	testing.expect_value(t, kept.directory, `D:\code`)
	send := [?]string{"pane.send", `docs\plan.md`}
	text, _ := commands.parse_invocation(&registry, send[:], context.temp_allocator)
	testing.expect_value(t, commands.invocation_paths_resolve(&text, `C:\work`, context.temp_allocator), nil)
	testing.expect_value(t, text.text, `docs\plan.md`)
	unknown := [?]string{"pane.split", "--cwd", "work"}
	unresolved, _ := commands.parse_invocation(&registry, unknown[:], context.temp_allocator)
	testing.expect_value(t, commands.invocation_paths_resolve(&unresolved, "", context.temp_allocator), nil)
	testing.expect_value(t, unresolved.directory, "work")
}

@(test)
command_line_join_round_trips_through_windows_quoting :: proc(t: ^testing.T) {
	Case :: struct {
		args: []string,
		line: string,
	}
	cases := [?]Case{
		{{"claude"}, "claude"},
		{{"git", "commit", "-m", "two words"}, `git commit -m "two words"`},
		{{""}, `""`},
		{{`say "hi"`}, `"say \"hi\""`},
		{{`C:\path with space\`}, `"C:\path with space\\"`},
		{{`a\\"b`}, `"a\\\\\"b"`},
		{{`plain\path`}, `plain\path`},
		{{"tab\there"}, "\"tab\there\""},
	}
	for item in cases {
		line, err := commands.command_line_join(item.args, context.temp_allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, line, item.line)
	}
}
