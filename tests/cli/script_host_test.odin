package cli_test

import "aio:cli"
import "aio:cli_protocol"
import "aio:events"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
expect_failures :: proc(t: ^testing.T, cases: [][]string) {
	for args in cases {
		_, failure := cli.parse_options(args, "")
		testing.expectf(t, failure != "", "%v should fail", args)
	}
}

@(test)
exec_tells_script_files_from_actions :: proc(t: ^testing.T) {
	Case :: struct {
		word:   string,
		target: cli.Exec_Target,
	}
	cases := [?]Case {
		{"build.lua", .File},
		{"BUILD.LUA", .File},
		{`scripts\build`, .File},
		{"./build", .File},
		{"deploy", .Action},
		{"tab.next", .Action},
	}
	for c in cases {
		args := [2]string{"exec", c.word}
		o, problem := cli.parse_options(args[:], "")
		testing.expectf(t, problem == "", "%s: %s", c.word, problem)
		testing.expect(t, o.executing)
		testing.expectf(t, o.exec.target == c.target, "%s should be %v, not %v", c.word, c.target, o.exec.target)
		testing.expect_value(t, o.exec.source, c.word)
	}
	code_args := [?]string{"--json", "exec", "-e", "return 1", "n=2"}
	code, code_problem := cli.parse_options(code_args[:], "")
	testing.expect_value(t, code_problem, "")
	testing.expect(t, code.json && code.exec.target == .Code)
	testing.expect_value(t, code.exec.source, "return 1")
	testing.expect_value(t, len(code.exec.pairs), 1)
	stdin_args := [?]string{"exec", "-", "--fail-fast", "--for", "2m", "--json"}
	stdin, stdin_problem := cli.parse_options(stdin_args[:], "")
	testing.expect_value(t, stdin_problem, "")
	testing.expect(t, stdin.exec.target == .Stdin && stdin.exec.fail_fast && stdin.json)
	testing.expect_value(t, stdin.exec.for_ms, 120_000)
	json_args := [?]string{"exec", "deploy", "--args", `{"a":1}`}
	with_args, args_problem := cli.parse_options(json_args[:], "")
	testing.expect_value(t, args_problem, "")
	testing.expect_value(t, with_args.exec.args, `{"a":1}`)
	failures := [][]string {
		{"exec"},
		{"exec", "--json"},
		{"exec", "a.lua", "b.lua"},
		{"exec", "a.lua", "-e", "x"},
		{"exec", "-e"},
		{"exec", "a.lua", "=1"},
		{"exec", "a.lua", "--other"},
		{"exec", "a.lua", "--for", "soon"},
		{"exec", "a.lua", "--for", "0"},
		{"exec", "a.lua", "--args", "{}", "n=1"},
		{"exec", "a.lua", "--args", "{}", "--args", "{}"},
		{"exec", "deploy", "--fail-fast"},
		{"exec", "deploy", "--for", "1s"},
		{"--json", "exec", "a.lua", "--json"},
	}
	expect_failures(t, failures)
}

@(test)
exec_durations_take_a_unit_or_count_seconds :: proc(t: ^testing.T) {
	Case :: struct {
		text: string,
		ms:   int,
		ok:   bool,
	}
	cases := [?]Case {
		{"500ms", 500, true},
		{"30", 30_000, true},
		{"30s", 30_000, true},
		{"10m", 600_000, true},
		{"1h", 3_600_000, true},
		{"", 0, false},
		{"s", 0, false},
		{"1.5s", 0, false},
		{"5d", 0, false},
		{"-1", 0, false},
	}
	for c in cases {
		ms, ok := cli.duration_ms(c.text)
		testing.expectf(t, ms == c.ms && ok == c.ok, "%q gave %d %v", c.text, ms, ok)
	}
}

@(test)
exec_arguments_keep_numbers_and_booleans_typed :: proc(t: ^testing.T) {
	pairs := [?]string{"n=2", "on=true", "off=false", "name=build", "ratio=-0.5", "zip=07", "say=a=\"b\"", "e="}
	e := cli.Exec {
		pairs = pairs[:],
	}
	text, problem := cli.exec_args(e, context.temp_allocator)
	testing.expect_value(t, problem, "")
	testing.expect_value(
		t,
		text,
		`{"n":2,"on":true,"off":false,"name":"build","ratio":-0.5,"zip":"07","say":"a=\"b\"","e":""}`,
	)
	twice := [2]string{"n=1", "n=2"}
	repeated := cli.Exec {
		pairs = twice[:],
	}
	_, twice_problem := cli.exec_args(repeated, context.temp_allocator)
	testing.expect(t, twice_problem != "")
	empty: cli.Exec
	none, none_problem := cli.exec_args(empty, context.temp_allocator)
	testing.expect_value(t, none_problem, "")
	testing.expect_value(t, none, "")
}

@(test)
exec_arguments_come_from_json_or_a_file :: proc(t: ^testing.T) {
	literal := cli.Exec {
		args = ` [1, {"a": true}] `,
	}
	text, text_problem := cli.exec_args(literal, context.temp_allocator)
	testing.expect_value(t, text_problem, "")
	testing.expect_value(t, text, `[1, {"a": true}]`)
	bad := cli.Exec {
		args = `{"a":}`,
	}
	_, bad_problem := cli.exec_args(bad, context.temp_allocator)
	testing.expect(t, bad_problem != "")
	directory, directory_error := os.make_directory_temp("", "aio-exec-args-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := strings.concatenate({directory, `\args.json`}, context.temp_allocator)
	if !testing.expect_value(t, os.write_entire_file(path, "{\"pane\": 3}\n"), nil) {return}
	from_file := cli.Exec {
		args = strings.concatenate({"@", path}, context.temp_allocator),
	}
	file_text, file_problem := cli.exec_args(from_file, context.temp_allocator)
	testing.expect_value(t, file_problem, "")
	testing.expect_value(t, file_text, `{"pane": 3}`)
	missing := cli.Exec {
		args = strings.concatenate({"@", directory, `\missing.json`}, context.temp_allocator),
	}
	_, missing_problem := cli.exec_args(missing, context.temp_allocator)
	testing.expect(t, missing_problem != "")
}

@(test)
exec_results_print_as_json :: proc(t: ^testing.T) {
	testing.expect_value(t, cli.exec_result_text("", true, context.temp_allocator), "")
	compact := cli.exec_result_text(`{"b":1,"a":[]}`, false, context.temp_allocator)
	testing.expect_value(t, compact, `{"b":1,"a":[]}`)
	testing.expect_value(t, cli.exec_result_text(`"x"`, true, context.temp_allocator), `"x"`)
	indented := cli.exec_result_text(`{"b":1,"a":[2,{"s":"x,{y}"}],"e":{}}`, true, context.temp_allocator)
	testing.expect_value(
		t,
		indented,
		"{\n  \"b\": 1,\n  \"a\": [\n    2,\n    {\n      \"s\": \"x,{y}\"\n    }\n  ],\n  \"e\": {}\n}",
	)
	reply := `{"ok":true,"status":0,"text":"a \"result\": no","result":{"z":1,"a":[1,2]}}`
	result, found := cli.json_member(reply, "result")
	testing.expect(t, found)
	testing.expect_value(t, result, `{"z":1,"a":[1,2]}`)
	_, absent := cli.json_member(`{"ok":true,"status":0}`, "result")
	testing.expect(t, !absent)
	testing.expect_value(t, cli.stop_status(3), cli_protocol.Status(3))
	testing.expect_value(t, cli.stop_status(-1), cli_protocol.Status.Ok)
	testing.expect_value(t, cli.stop_status(999), cli_protocol.Status(255))
}

@(test)
script_event_lines_name_their_kind :: proc(t: ^testing.T) {
	kind, valid := cli.event_line_kind(`{"type":"pane.exited","pane":3,"code":0}`)
	testing.expect(t, valid)
	testing.expect_value(t, kind, events.Kind.Pane_Exited)
	_, unknown := cli.event_line_kind(`{"type":"pane.nothing"}`)
	testing.expect(t, !unknown)
	_, malformed := cli.event_line_kind(`{"pane":3}`)
	testing.expect(t, !malformed)
}

@(test)
config_check_takes_a_file_or_a_data_directory :: proc(t: ^testing.T) {
	args := [?]string{"config", "check", "--data-dir", `D:\data`, "my.lua"}
	o, problem := cli.parse_options(args[:], "")
	testing.expect_value(t, problem, "")
	testing.expect(t, o.checking)
	testing.expect_value(t, o.check.data_dir, `D:\data`)
	testing.expect_value(t, o.check.path, "my.lua")
	plain_args := [?]string{"config", "check"}
	plain, plain_problem := cli.parse_options(plain_args[:], "")
	testing.expect_value(t, plain_problem, "")
	testing.expect_value(t, plain.check.path, "")
	failures := [][]string {
		{"config"},
		{"config", "load"},
		{"config", "check", "a.lua", "b.lua"},
		{"config", "check", "--data-dir"},
		{"config", "check", "--other"},
	}
	expect_failures(t, failures)
}

@(test)
config_check_reports_counts_and_each_bad_declaration :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-config-check-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := strings.concatenate({directory, `\init.lua`}, context.temp_allocator)
	source :: "aio.bind('Ctrl+B>C', 'tab.next')\naio.bind('Ctrl+Nope', 'tab.next')\n"
	if !testing.expect_value(t, os.write_entire_file(path, source), nil) {return}
	report, status := cli.config_check(path, context.temp_allocator)
	testing.expect_value(t, status, cli_protocol.Status.Failed)
	expected := strings.concatenate(
		{path, "\nactions 0\nkeys 2\nmodes 0\ninit.lua:2: key \"Ctrl+Nope\" is not a valid key sequence"},
		context.temp_allocator,
	)
	testing.expect_value(t, report, expected)
	good :: "aio.bind('Ctrl+B>C', 'tab.next')\n"
	if !testing.expect_value(t, os.write_entire_file(path, good), nil) {return}
	clean, clean_status := cli.config_check(path, context.temp_allocator)
	testing.expect_value(t, clean_status, cli_protocol.Status.Ok)
	clean_expected := strings.concatenate({path, "\nactions 0\nkeys 1\nmodes 0"}, context.temp_allocator)
	testing.expect_value(t, clean, clean_expected)
	broken :: "local x = \naio.bind(\n"
	if !testing.expect_value(t, os.write_entire_file(path, broken), nil) {return}
	_, broken_status := cli.config_check(path, context.temp_allocator)
	testing.expect_value(t, broken_status, cli_protocol.Status.Failed)
}
