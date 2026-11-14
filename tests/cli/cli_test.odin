package cli_test

import "core:strings"
import "core:testing"
import "core:text/regex"
import "aio:cli"

@(test)
global_options_come_before_the_command :: proc(t: ^testing.T) {
	o, problem := cli.parse_options({"--instance", "work_2", "--json", "pane.split", "--json", "--", "x"}, "")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, o.instance, "work_2")
	testing.expect(t, o.json && !o.waiting)
	// Options after the command belong to the command, so AIODev reports them.
	testing.expect_value(t, len(o.args), 4)
	testing.expect_value(t, o.args[0], "pane.split")
	testing.expect_value(t, o.args[1], "--json")
	from_environment, _ := cli.parse_options({"pane.list"}, "named")
	testing.expect_value(t, from_environment.instance, "named")
	overridden, _ := cli.parse_options({"--instance", "other", "pane.list"}, "named")
	testing.expect_value(t, overridden.instance, "other")
	for args in ([][]string{
		{},
		{"--json"},
		{"--json", "--json", "pane.list"},
		{"--instance"},
		{"--instance", "bad name", "pane.list"},
		{"--instance", "a", "--instance", "b", "pane.list"},
	}) {
		_, failure := cli.parse_options(args, "")
		testing.expectf(t, failure != "", "%v should fail", args)
	}
}

@(test)
wait_needs_one_condition :: proc(t: ^testing.T) {
	o, problem := cli.parse_options({"wait", "--pane", "7", "--text", "ready"}, "")
	testing.expect_value(t, problem, "")
	testing.expect(t, o.waiting && !o.wait.exit)
	testing.expect_value(t, o.wait.pane, "7")
	testing.expect_value(t, o.wait.text, "ready")
	testing.expect_value(t, o.wait.timeout_ms, cli.WAIT_DEFAULT_TIMEOUT_MS)
	exit, exit_problem := cli.parse_options({"wait", "--exit", "--timeout", "0"}, "")
	testing.expect_value(t, exit_problem, "")
	testing.expect(t, exit.wait.exit)
	testing.expect_value(t, exit.wait.timeout_ms, 0)
	for args in ([][]string{
		{"wait"},
		{"wait", "--exit", "--text", "x"},
		{"wait", "--exit", "--exit"},
		{"wait", "--text", ""},
		{"wait", "--text"},
		{"wait", "--exit", "--timeout", "-1"},
		{"wait", "--exit", "--timeout", "soon"},
		{"wait", "--exit", "--pane", "1", "--pane", "2"},
		{"wait", "--exit", "--other", "1"},
	}) {
		_, failure := cli.parse_options(args, "")
		testing.expectf(t, failure != "", "%v should fail", args)
	}
}

@(test)
wait_combines_idle_with_one_screen_condition :: proc(t: ^testing.T) {
	pattern, problem := cli.parse_options({"wait", "--regex", `ready \d+`, "--idle", "250"}, "")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, pattern.wait.regex, `ready \d+`)
	testing.expect_value(t, pattern.wait.idle_ms, 250)
	idle, idle_problem := cli.parse_options({"wait", "--idle", "1000", "--pane", "agent"}, "")
	testing.expect_value(t, idle_problem, "")
	testing.expect(t, idle.wait.text == "" && idle.wait.regex == "" && !idle.wait.exit)
	text, text_problem := cli.parse_options({"wait", "--text", "done", "--idle", "1"}, "")
	testing.expect_value(t, text_problem, "")
	testing.expect_value(t, text.wait.idle_ms, 1)
	for args in ([][]string{
		{"wait", "--text", "a", "--regex", "b"},
		{"wait", "--regex", "b", "--exit"},
		{"wait", "--exit", "--idle", "100"},
		{"wait", "--regex", ""},
		{"wait", "--regex", "a", "--regex", "b"},
		{"wait", "--idle", "0"},
		{"wait", "--idle", "-5"},
		{"wait", "--idle", "soon"},
		{"wait", "--idle", "5", "--idle", "5"},
		{"wait", "--idle"},
	}) {
		_, failure := cli.parse_options(args, "")
		testing.expectf(t, failure != "", "%v should fail", args)
	}
}

@(test)
wait_patterns_match_one_line_at_a_time :: proc(t: ^testing.T) {
	screen := "PS C:\\work> build\nbuilt 12 targets in 3.5s\nPS C:\\work>"
	compiled, problem := cli.wait_pattern(`built \d+ targets`)
	if !testing.expect_value(t, problem, "") {return}
	defer regex.destroy_regex(compiled)
	testing.expect(t, cli.wait_found({}, compiled, screen))
	testing.expect(t, !cli.wait_found({}, compiled, "built many targets"))
	// A line ends the match, so a pattern cannot span a hard line break.
	spanning, spanning_problem := cli.wait_pattern(`build.built`)
	if !testing.expect_value(t, spanning_problem, "") {return}
	defer regex.destroy_regex(spanning)
	testing.expect(t, !cli.wait_found({}, spanning, screen))
	anchored, anchored_problem := cli.wait_pattern(`^PS .*>$`)
	if !testing.expect_value(t, anchored_problem, "") {return}
	defer regex.destroy_regex(anchored)
	testing.expect(t, cli.wait_found({}, anchored, screen))
	testing.expect(t, !cli.wait_found({}, anchored, "PS C:\\work> build"))
	// Text matches anywhere in the screen; waiting for idleness alone looks for nothing.
	testing.expect(t, cli.wait_found({text = "work> build\nbuilt"}, nil, screen))
	testing.expect(t, !cli.wait_found({text = "missing"}, nil, screen))
	testing.expect(t, cli.wait_found({idle_ms = 100}, nil, ""))
	for bad in ([]string{`(unclosed`, `a{2`, `[z-a`}) {
		_, failure := cli.wait_pattern(bad)
		testing.expectf(t, failure != "", "%q should not compile", bad)
	}
}

@(test)
requests_carry_caller_format_and_directory :: proc(t: ^testing.T) {
	o, _ := cli.parse_options({"--json", "pane.send", "--enter", "hi"}, "")
	request := cli.request(o, "12", `C:\work`, context.temp_allocator)
	testing.expect_value(t, len(request), 6)
	expected := [?]string{"12", "json", `C:\work`, "pane.send", "--enter", "hi"}
	for item, i in expected {testing.expect_value(t, request[i], item)}
	help, _ := cli.parse_options({"help", "pane.split"}, "")
	asked := cli.request(help, "", "", context.temp_allocator)
	testing.expect_value(t, len(asked), 5)
	testing.expect_value(t, asked[1], "text")
	testing.expect_value(t, asked[3], "app.commands")
	testing.expect_value(t, asked[4], "pane.split")
	listing, _ := cli.parse_options({"commands"}, "")
	testing.expect_value(t, cli.request(listing, "", "", context.temp_allocator)[3], "app.commands")
}

@(test)
version_asks_the_app_build_as_text :: proc(t: ^testing.T) {
	for args in ([][]string{{"version"}, {"--version"}, {"--json", "--instance", "w1", "--version"}}) {
		o, problem := cli.parse_options(args, "")
		testing.expect_value(t, problem, "")
		testing.expect(t, o.version && !o.waiting)
		// aio prints its own build beside AIODev's, so even a --json version asks for text.
		request := cli.request(o, "3", "", context.temp_allocator)
		testing.expect_value(t, len(request), 4)
		testing.expect_value(t, request[1], "text")
		testing.expect_value(t, request[3], "app.version")
	}
	other, _ := cli.parse_options({"pane.list", "version"}, "")
	testing.expect(t, !other.version)
	// AIODev fails the version command only when it is too old to know it, so aio keeps it bare.
	_, extra := cli.parse_options({"version", "--json"}, "")
	testing.expect(t, extra != "")
}

@(test)
build_warning_only_when_builds_differ :: proc(t: ^testing.T) {
	own := "0.10.0 (4dc71c8, release)"
	testing.expect_value(t, cli.build_warning(own, "AIODev 0.10.0 (4dc71c8, release)", context.temp_allocator), "")
	unknown :: "dev (unknown, development)"
	testing.expect_value(t, cli.build_warning(unknown, "AIODev " + unknown, context.temp_allocator), "")
	for app in ([]string{
		"AIODev dev (510462e+dirty, verify)",
		"AIODev 0.10.0 (4dc71c8+dirty, release)",
		"AIODev 0.10.0 (4dc71c8, debug)",
		"aio 0.10.0 (4dc71c8, release)",
	}) {
		warning := cli.build_warning(own, app, context.temp_allocator)
		testing.expectf(t, strings.contains(warning, own) && strings.contains(warning, app), "%q: %q", app, warning)
		testing.expect(t, !strings.contains(warning, "\n"))
	}
	// An AIODev too old to answer the version command differs too, but cannot name its build.
	old := cli.build_warning(own, "", context.temp_allocator)
	testing.expectf(t, strings.contains(old, own) && strings.contains(old, "does not report its build"), "%q", old)
}

// wait, commands and help run in aio, so aio answers their help; AIODev answers the rest.
@(test)
help_for_client_commands_is_answered_locally :: proc(t: ^testing.T) {
	wait, _ := cli.parse_options({"help", "wait"}, "")
	report, local := cli.local_help(wait)
	testing.expect(t, local)
	testing.expect_value(t, report.name, "wait")
	testing.expect_value(t, len(report.options), 6)
	for name in ([]string{"events", "commands", "help", "version", "agent-session"}) {
		o, _ := cli.parse_options({"help", name}, "")
		_, answered := cli.local_help(o)
		testing.expectf(t, answered, "help %s should be answered by aio", name)
	}
	for args in ([][]string{{"help", "pane.split"}, {"help"}, {"wait", "--exit"}, {"help", "wait", "x"}}) {
		o, _ := cli.parse_options(args, "")
		_, answered := cli.local_help(o)
		testing.expectf(t, !answered, "%v should not be answered by aio", args)
	}
}

@(test)
events_subscribe_to_names_and_take_json_anywhere :: proc(t: ^testing.T) {
	o, problem := cli.parse_options({"events", "pane.focused", "--json", "pane.exited"}, "")
	testing.expect_value(t, problem, "")
	testing.expect(t, o.streaming && o.json && !o.waiting && !o.version)
	request := cli.request(o, "4", "", context.temp_allocator)
	expected := [?]string{"4", "json", "", "app.events", "pane.focused", "pane.exited"}
	if testing.expect_value(t, len(request), len(expected)) {
		for item, i in expected {testing.expect_value(t, request[i], item)}
	}
	every, _ := cli.parse_options({"--json", "events"}, "")
	all := cli.request(every, "", "", context.temp_allocator)
	testing.expect_value(t, len(all), 4)
	testing.expect_value(t, all[3], "app.events")
	for args in ([][]string{{"--json", "events", "--json"}, {"events", "--pane", "3"}}) {
		_, failure := cli.parse_options(args, "")
		testing.expectf(t, failure != "", "%v should fail", args)
	}
}

@(test)
event_lines_print_name_then_fields :: proc(t: ^testing.T) {
	fields, ok := cli.event_plain(`{"type":"pane.exited","pane":3,"exit_code":1}`, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, fields, "pane.exited\t{\"pane\":3,\"exit_code\":1}")
	bare, bare_ok := cli.event_plain(`{"type":"app.quitting"}`, context.temp_allocator)
	testing.expect(t, bare_ok)
	testing.expect_value(t, bare, "app.quitting\t{}")
	for line in ([]string{`{"pane":3,"type":"pane.bell"}`, `{"type":"pane.bell"`, `{"type":""}`, ``}) {
		_, valid := cli.event_plain(line, context.temp_allocator)
		testing.expectf(t, !valid, "%q should not parse", line)
	}
}

// aio hands an unverified pipe server's call to AIODEV_CLI only when that names another aio, and never
// from an aio that was itself handed a call.
@(test)
delegation_targets_only_another_aio :: proc(t: ^testing.T) {
	own := `C:\Tools\AIODev\aio.exe`
	other := `D:\Dev\AIODev\build\aio.exe`
	testing.expect_value(t, cli.delegation_target(own, other, false, context.temp_allocator), other)
	forward := cli.delegation_target(own, "D:/Dev/AIODev/build/aio.exe", false, context.temp_allocator)
	testing.expect_value(t, forward, other)
	testing.expect_value(t, cli.delegation_target(own, other, true, context.temp_allocator), "")
	testing.expect_value(t, cli.delegation_target(own, "", false, context.temp_allocator), "")
	testing.expect_value(t, cli.delegation_target(own, own, false, context.temp_allocator), "")
	upper := cli.delegation_target(own, `c:\TOOLS\aiodev\AIO.EXE`, false, context.temp_allocator)
	testing.expect_value(t, upper, "")
	slashes := cli.delegation_target(own, "C:/Tools/AIODev/aio.exe", false, context.temp_allocator)
	testing.expect_value(t, slashes, "")
	dotted := cli.delegation_target(own, `C:\Tools\AIODev\..\AIODev\aio.exe`, false, context.temp_allocator)
	testing.expect_value(t, dotted, "")
}
