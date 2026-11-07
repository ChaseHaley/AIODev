package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:control"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:strings"

// The aio command line's side of the CLI pipe; cli_protocol owns the request and reply shapes.

// The CLI pipe's state; nil is off. A pipe that failed to start stays failed while control.enabled
// stays on, so the settings syncs that follow do not retry it and repeat the notice; turning the
// setting off and on tries again, as the notice says.
Cli_Pipe :: union {
	^control.Server,
	Cli_Pipe_Failed,
}
Cli_Pipe_Failed :: struct {}

// Starts or stops the CLI pipe to match control.enabled (D-046). Settings apply at startup, on
// Reload Settings and on each Settings page change.
control_cli_sync :: proc(app: ^App) {
	if !app.settings.control.enabled {
		control_cli_stop(app)
		return
	}
	if app.cli != nil {return}
	name, err := control.cli_pipe_name(app.app_id, context.temp_allocator)
	server: ^control.Server
	if err == .None {server, err = control.create(name, {wake_platform, &app.platform})}
	if err != .None {
		log.errorf("starting the command line pipe failed: %v", err)
		notify(app, .Error, "Could not start command line control. Check the log, then turn it off and on.")
		app.cli = Cli_Pipe_Failed{}
		return
	}
	app.cli = server
}

control_cli_stop :: proc(app: ^App) {
	if server, running := app.cli.(^control.Server); running {control.destroy(server)}
	app.cli = nil
}

// Answers the pending CLI request, if any. The pipe serves one client at a time and no command
// waits, so one request per tick keeps every reply prompt.
control_cli_tick :: proc(app: ^App) {
	server, running := app.cli.(^control.Server)
	if !running {return}
	message := control.poll(server)
	if message == nil {return}
	defer control.message_destroy(message)
	if err := control.respond(server, message.id, control_cli_answer(app, message.args)); err != .None {
		log.errorf("answering the command line failed: %v", err)
	}
}

@(require_results)
control_cli_answer :: proc(app: ^App, args: []string) -> control.Response {
	request, well_formed := cli_protocol.request_decode(args)
	if !well_formed {
		return control_cli_reply(
			outcome_failure(.Usage, "malformed request; use the aio that came with this AIODev"),
			false,
		)
	}
	json_output := request.format == .Json
	caller: u32
	if request.caller != "" {
		id, valid := pane_id_parse(request.caller)
		if !valid {return control_cli_reply(outcome_failure(.Usage, "AIODEV_PANE is not a pane id"), json_output)}
		caller = id
	}
	invocation, parse_error := commands.parse_invocation(&app.registry, request.command, context.temp_allocator)
	if parse_error.advice != "" {
		message := fmt.tprintf("%q: %s", parse_error.argument, parse_error.advice)
		return control_cli_reply(outcome_failure(.Usage, message), json_output)
	}
	return control_cli_reply(command_invoke(app, nil, invocation, caller), json_output)
}

// The reply text follows whichever Outcome field the command filled: a failure's message, a
// created pane, one command's usage, the catalogue, the pane list, else the text.
@(private)
control_cli_reply :: proc(outcome: Outcome, json_output: bool) -> control.Response {
	response := cli_protocol.response(outcome.status, "")
	ok := response.ok
	if json_output {
		document := cli_protocol.Reply_Json {
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
			return cli_protocol.response(.Failed, "not enough memory for the reply")
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
