package cli_test

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
requests_carry_caller_and_format :: proc(t: ^testing.T) {
	o, _ := cli.parse_options({"--json", "pane.send", "--enter", "hi"}, "")
	request := cli.request(o, "12", context.temp_allocator)
	testing.expect_value(t, len(request), 5)
	expected := [?]string{"12", "json", "pane.send", "--enter", "hi"}
	for item, i in expected {testing.expect_value(t, request[i], item)}
	help, _ := cli.parse_options({"help", "pane.split"}, "")
	asked := cli.request(help, "", context.temp_allocator)
	testing.expect_value(t, len(asked), 4)
	testing.expect_value(t, asked[1], "text")
	testing.expect_value(t, asked[2], "app.commands")
	testing.expect_value(t, asked[3], "pane.split")
	listing, _ := cli.parse_options({"commands"}, "")
	testing.expect_value(t, cli.request(listing, "", context.temp_allocator)[2], "app.commands")
}
