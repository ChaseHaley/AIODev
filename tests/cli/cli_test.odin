package cli_test

import "core:strings"
import "core:testing"
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
	testing.expect_value(t, len(report.options), 4)
	for name in ([]string{"commands", "help"}) {
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
