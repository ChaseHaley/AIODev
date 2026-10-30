package main

import "aio:commands"
import "aio:control"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// The aio command line's side of the CLI pipe. A request is a JSON string array:
// [caller pane id or "", "text" or "json", command name, arguments...]. The reply's status is the
// CLI exit code (D-046).

@(private)
CLI_REQUEST_HEADER :: 2

// Starts or stops the CLI pipe to match control.enabled (D-046). Settings apply at startup, on
// Reload Settings and on each Settings page change.
control_cli_sync :: proc(app: ^App) {
	enabled := app.settings.control.enabled
	if enabled == (app.cli != nil) {return}
	if !enabled {
		control.destroy(app.cli)
		app.cli = nil
		return
	}
	name, err := control.cli_pipe_name(app.app_id, context.temp_allocator)
	if err == .None {app.cli, err = control.create(name, {wake_platform, &app.platform}, raw = true)}
	if err != .None {
		log.errorf("starting the command line pipe failed: %v", err)
		notify(app, .Error, "Could not start command line control. Check the log, then turn it off and on.")
	}
}

// Answers the pending CLI request, if any. The pipe serves one client at a time and no command
// waits, so one request per tick keeps every reply prompt.
control_cli_tick :: proc(app: ^App) {
	if app.cli == nil {return}
	message := control.poll(app.cli)
	if message == nil {return}
	defer control.message_destroy(message)
	if err := control.respond(app.cli, message.id, control_cli_answer(app, message.args)); err != .None {
		log.errorf("answering the command line failed: %v", err)
	}
}

@(require_results)
control_cli_answer :: proc(app: ^App, args: []string) -> control.Response {
	if len(args) <= CLI_REQUEST_HEADER || (args[1] != "text" && args[1] != "json") {
		return control_cli_reply(
			outcome_failure(.Usage, "malformed request; use the aio that came with this AIODev"),
			false,
		)
	}
	json_output := args[1] == "json"
	caller: u32
	if args[0] != "" {
		id, valid := pane_id_parse(args[0])
		if !valid {return control_cli_reply(outcome_failure(.Usage, "AIODEV_PANE is not a pane id"), json_output)}
		caller = id
	}
	invocation, parse_error := commands.parse_invocation(
		&app.registry,
		args[CLI_REQUEST_HEADER:],
		context.temp_allocator,
	)
	if parse_error.advice != "" {
		message := fmt.tprintf("%q: %s", parse_error.argument, parse_error.advice)
		return control_cli_reply(outcome_failure(.Usage, message), json_output)
	}
	return control_cli_reply(command_invoke(app, nil, invocation, caller), json_output)
}

@(private)
Cli_Json :: struct {
	ok:       bool,
	status:   u8,
	error:    string,
	pane:     u32,
	text:     string,
	panes:    []Pane_Report,
	commands: []Command_Report,
}

@(private)
control_cli_reply :: proc(outcome: Outcome, json_output: bool) -> control.Response {
	ok := outcome.status == .Ok
	response := control.Response {
		ok     = ok,
		status = u8(outcome.status),
	}
	if json_output {
		document := Cli_Json {
			ok       = ok,
			status   = u8(outcome.status),
			error    = outcome.message,
			pane     = outcome.pane,
			text     = outcome.text,
			panes    = outcome.panes,
			commands = outcome.catalogue,
		}
		data, err := json.marshal(document, {}, context.temp_allocator)
		if err != nil {
			return {ok = false, text = "not enough memory for the reply", status = u8(commands.Status.Failed)}
		}
		response.text = string(data)
		return response
	}
	b := strings.builder_make(context.temp_allocator)
	switch {
	case !ok:
		strings.write_string(&b, outcome.message)
		if outcome.pane != 0 {fmt.sbprintf(&b, " (pane %d)", outcome.pane)}
	case outcome.pane != 0:
		fmt.sbprintf(&b, "%d", outcome.pane)
	case len(outcome.catalogue) == 1:
		fmt.sbprintf(&b, "%s\n%s", outcome.catalogue[0].usage, outcome.catalogue[0].title)
	case outcome.catalogue != nil:
		for command, i in outcome.catalogue {
			if i > 0 {strings.write_byte(&b, '\n')}
			fmt.sbprintf(&b, "%-30s %s", command.name, command.title)
		}
	case outcome.panes != nil:
		// One tab-separated line per pane: id, focus mark, workspace, tab, status, process, title,
		// directory.
		for pane, i in outcome.panes {
			if i > 0 {strings.write_byte(&b, '\n')}
			title := pane.name != "" ? pane.name : pane.title
			fmt.sbprintf(&b, "%d\t%s\t%s\t%d\t%s\t%s\t%s\t%s", pane.id, pane.focused ? "*" : "",
				pane.workspace_name, pane.tab, pane.status, pane.process, title, pane.directory)
		}
	case:
		strings.write_string(&b, outcome.text)
	}
	response.text = strings.to_string(b)
	return response
}
