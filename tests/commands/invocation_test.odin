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
	}
	for item in items {testing.expect_value(t, commands.register(&registry, item), commands.Error.None)}
	return registry
}

@(test)
invocation_defaults_depend_on_origin :: proc(t: ^testing.T) {
	key := commands.invocation(7, .Key)
	testing.expect_value(t, key.id, commands.Command_Id(7))
	testing.expect_value(t, key.direction, layout.Direction.Right)
	testing.expect_value(t, key.ratio, f32(0.5))
	testing.expect(t, key.focus)
	testing.expect(t, !commands.invocation(7, .Control).focus)
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
	testing.expect_value(t, result.origin, commands.Origin.Control)
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
		{{"pane.read", "--lines", "0"}, "0"},
		{{"pane.read", "--lines", "10001"}, "10001"},
		{{"pane.read", "--lines", "-3"}, "-3"},
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
