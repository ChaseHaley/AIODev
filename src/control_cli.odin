package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:control"
import "aio:events"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
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

@(private)
CLI_EXECUTABLE :: "aio.exe"

// The aio command line as App embeds it: the pipe it reaches the app through, the directory holding
// aio.exe beside this executable, which each shell's PATH and AIODEV_CLI get (empty when aio.exe is
// missing), and the connections `aio events` turned into event streams.
Cli_State :: struct {
	cli:             Cli_Pipe,
	cli_directory:   string,
	cli_subscribers: [control.MAX_SERVER_CLIENTS]Cli_Subscriber,
}

// One event stream: its subscription request's id, which names the connection, and the events it
// asked for. A zero id is a free entry.
Cli_Subscriber :: struct {
	id:    u64,
	kinds: events.Kinds,
}

// Finds aio.exe beside this executable; the pipe starts with control_cli_sync once settings apply.
control_cli_init :: proc(app: ^App) {
	executable, err := os.get_executable_path(context.temp_allocator)
	if err != nil {return}
	directory := filepath.dir(executable)
	if cli, join_error := filepath.join({directory, CLI_EXECUTABLE}, context.temp_allocator);
	   join_error == nil && os.exists(cli) {
		app.cli_directory = strings.clone(directory)
	}
}

control_cli_destroy :: proc(app: ^App) {
	control_cli_stop(app)
	delete(app.cli_directory)
	app.cli_directory = ""
}

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
		notify(
			app,
			.Error,
			`Could not start command line control. Check the log, then turn "Command line control" off and ` +
			"on in Settings.",
		)
		app.cli = Cli_Pipe_Failed{}
		return
	}
	app.cli = server
}

control_cli_stop :: proc(app: ^App) {
	if server, running := app.cli.(^control.Server); running {control.destroy(server)}
	app.cli = nil
	app.cli_subscribers = {}
	events.set_interest(&app.events, .Cli, {})
}

// Each connection holds at most one request and the server polls them in turn, so this many polls
// answer every request queued when the tick began without waiting on any client.
control_cli_tick :: proc(app: ^App) {
	server, running := app.cli.(^control.Server)
	if !running {return}
	for _ in 0 ..< control.MAX_SERVER_CLIENTS {
		message := control.poll(server)
		if message == nil {break}
		request, well_formed := cli_protocol.request_decode(message.args)
		response: control.Response
		if well_formed && len(request.command) > 0 && request.command[0] == cli_protocol.EVENTS_COMMAND {
			response = control_cli_subscribe(app, server, message.id, request)
		} else {
			response = control_cli_answer(app, message.args)
		}
		err := control.respond(server, message.id, response)
		control.message_destroy(message)
		// Closed: the client left before its answer, which nobody is waiting for.
		if err != .None && err != .Closed {log.errorf("answering the command line failed: %v", err)}
	}
	// Streams that closed since the last delivery release their interest even on ticks without events.
	control_cli_events(app, nil)
}

// Turns the request's connection into a stream of the named events, or of all events without names.
// The acknowledgement reaches the client before any event line.
@(private, require_results)
control_cli_subscribe :: proc(
	app: ^App,
	server: ^control.Server,
	id: u64,
	request: cli_protocol.Request,
) -> control.Response {
	json_output := request.format == .Json
	if request.caller != "" {
		if _, valid := pane_id_parse(request.caller); !valid {
			return control_cli_reply(outcome_failure(.Usage, "AIODEV_PANE is not a pane id"), json_output)
		}
	}
	// aio sends each name as its own word, but the command's Text argument is one positional value.
	words := request.command
	joined: [2]string
	if len(words) > 1 {
		text := strings.join(words[1:], " ", context.temp_allocator)
		joined = {words[0], text}
		words = joined[:]
	}
	invocation, parse_error := commands.parse_invocation(&app.registry, words, context.temp_allocator)
	if parse_error.advice != "" {
		message := fmt.tprintf("%q: %s", parse_error.argument, parse_error.advice)
		return control_cli_reply(outcome_failure(.Usage, message), json_output)
	}
	kinds: events.Kinds
	names := strings.fields(invocation.text, context.temp_allocator)
	if len(names) == 0 {
		for kind in events.Kind {kinds += {kind}}
	}
	for name in names {
		kind, known := events.kind_named(name)
		if !known {
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "unknown event %q; events are", name)
			for each in events.Kind {
				strings.write_string(&b, each == min(events.Kind) ? " " : ", ")
				strings.write_string(&b, control_cli_event_name(each))
			}
			return control_cli_reply(outcome_failure(.Usage, strings.to_string(b)), json_output)
		}
		kinds += {kind}
	}
	// Frees the entries of streams that have closed; there is one entry per pipe instance.
	control_cli_events(app, nil)
	for &subscriber in app.cli_subscribers {
		if subscriber.id != 0 {continue}
		if control.stream_start(server, id) != .None {
			return control_cli_reply(outcome_failure(.Failed, "the subscribing client disconnected"), json_output)
		}
		subscriber = {id, kinds}
		control_cli_events(app, nil)
		return control_cli_reply(Outcome{}, json_output)
	}
	return control_cli_reply(outcome_failure(.Failed, "too many event subscribers"), json_output)
}

// Queues each pending event's stream line for the subscribers that want it, then keeps the queue's
// Cli interest the union of what the remaining subscribers want, so unwanted events cost nothing.
// app_events_deliver calls it at the end of each tick; it never waits on a client.
control_cli_events :: proc(app: ^App, pending: []events.Event) {
	server, running := app.cli.(^control.Server)
	// control_cli_stop already released every stream and the Cli interest.
	if !running {return}
	wanted: events.Kinds
	for &subscriber in app.cli_subscribers {
		if subscriber.id != 0 && !control.stream_connected(server, subscriber.id) {subscriber = {}}
		wanted |= subscriber.kinds
	}
	for event in pending {
		if event.kind not_in wanted {continue}
		line := control_cli_event_line(event)
		for &subscriber in app.cli_subscribers {
			if event.kind not_in subscriber.kinds {continue}
			err := control.stream_push(server, subscriber.id, line)
			if err == .None {continue}
			// Closed is a client that left, or one stream_push disconnected because it fell behind.
			if err != .Closed {log.errorf("queuing an application event failed: %v", err)}
			if !control.stream_connected(server, subscriber.id) {subscriber = {}}
		}
	}
	wanted = {}
	for subscriber in app.cli_subscribers {wanted |= subscriber.kinds}
	if app.events.interest[.Cli] != wanted {events.set_interest(&app.events, .Cli, wanted)}
}

// The event's stream line: its fields object with "type" first. Concatenated rather than formatted,
// since fmt reads braces as argument placeholders.
@(private, require_results)
control_cli_event_line :: proc(event: events.Event) -> string {
	name := control_cli_event_name(event.kind)
	fields := strings.trim_space(event.fields)
	members := len(fields) >= 2 ? strings.trim_space(fields[1:len(fields) - 1]) : ""
	if members == "" {return strings.concatenate({`{"type":"`, name, `"}`}, context.temp_allocator)}
	return strings.concatenate({`{"type":"`, name, `",`, members, "}"}, context.temp_allocator)
}

// The static copy lets a kind known only at run time index the constant names.
@(private, require_results)
control_cli_event_name :: proc(kind: events.Kind) -> string {
	@(static, rodata)
	names := events.NAMES
	return names[kind]
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
	ctx := Control_Request{caller = caller, origin = .Cli}
	if len(request.command) >= 2 && request.command[1] == cli_protocol.FIELDS_OPTION {
		if len(request.command) != 3 && len(request.command) != 5 {
			usage := outcome_failure(.Usage, "use <command> --fields <object> [--origin <origin>]")
			return control_cli_reply(usage, json_output)
		}
		if len(request.command) == 5 {
			if request.command[3] != cli_protocol.ORIGIN_OPTION {
				return control_cli_reply(outcome_failure(.Usage, "expected --origin after --fields"), json_output)
			}
			found := false
			for word, origin in COMMAND_ORIGIN_WORDS {
				if word == request.command[4] {ctx.origin, found = origin, true; break}
			}
			if !found {return control_cli_reply(outcome_failure(.Usage, "unknown command origin"), json_output)}
		}
		if json_output {
			return command_run_fields(app, ctx, request.command[0], request.command[2], request.directory)
		}
		outcome := command_fields_execute(app, ctx, request.command[0], request.command[2], request.directory)
		return control_cli_reply(outcome, false)
	}
	invocation, parse_error := commands.parse_invocation(&app.registry, request.command, context.temp_allocator)
	if parse_error.advice != "" {
		message := fmt.tprintf("%q: %s", parse_error.argument, parse_error.advice)
		return control_cli_reply(outcome_failure(.Usage, message), json_output)
	}
	return control_cli_reply(command_run_resolved(app, ctx, invocation, request.directory), json_output)
}

// Config and pipe callers share parsing, path resolution and the exact JSON reply shape.
@(require_results)
command_run_fields :: proc(
	app: ^App,
	ctx: Command_Context,
	name, fields, directory: string,
) -> control.Response {
	return control_cli_reply(command_fields_execute(app, ctx, name, fields, directory), true)
}

@(private, require_results)
command_fields_execute :: proc(app: ^App, ctx: Command_Context, name, fields, directory: string) -> Outcome {
	invocation, parse_error := commands.parse_fields(&app.registry, name, fields, context.temp_allocator)
	if parse_error.advice != "" {
		return outcome_failure(.Usage, fmt.tprintf("%q: %s", parse_error.argument, parse_error.advice))
	}
	return command_run_resolved(app, ctx, invocation, directory)
}

@(private, require_results)
command_run_resolved :: proc(
	app: ^App,
	ctx: Command_Context,
	invocation: commands.Invocation,
	directory: string,
) -> Outcome {
	invocation := invocation
	// Paths belong to the requester, and a newly opened pane inherits its directory unless --cwd overrides it.
	if commands.invocation_paths_resolve(&invocation, directory, context.temp_allocator) != nil {
		return outcome_failure(.Failed, "not enough memory for the paths")
	}
	if .Directory not_in invocation.given {invocation.directory = directory}
	return command_execute(app, ctx, invocation)
}

// The payload kind selects the reply shape; status and message report failures independently. Plain
// lists start with a row naming their tab-separated columns, which `ConvertFrom-Csv -Delimiter "`t"`
// reads, and show an empty field as "-".
@(private)
control_cli_reply :: proc(outcome: Outcome, json_output: bool) -> control.Response {
	response := cli_protocol.response(outcome.status, "")
	ok := response.ok
	if json_output {
		document := cli_protocol.Reply_Json {
			ok       = ok,
			status   = u8(outcome.status),
			error    = outcome.message,
		}
		status_pane: [1]cli_protocol.Pane_Report
		raw_result: string
		switch payload in outcome.payload {
		case Outcome_Created:
			document.pane = payload.pane
		case Outcome_Text:
			document.text = string(payload)
		case Outcome_Process:
			document.process = cli_protocol.Process_Report(payload)
		case Outcome_Json:
			raw_result = string(payload)
		case Outcome_Panes:
			document.panes = ([]cli_protocol.Pane_Report)(payload)
		case Outcome_Layout:
			document.panes = ([]cli_protocol.Pane_Report)(payload)
		case Outcome_Pane_Status:
			status_pane[0] = cli_protocol.Pane_Report(payload)
			document.panes = status_pane[:]
		case Outcome_Tabs:
			document.tabs = ([]cli_protocol.Tab_Report)(payload)
		case Outcome_Workspaces:
			document.workspaces = ([]cli_protocol.Workspace_Report)(payload)
		case Outcome_Catalogue:
			document.commands = ([]cli_protocol.Command_Report)(payload)
		case Outcome_Usage:
			document.commands = []cli_protocol.Command_Report{cli_protocol.Command_Report(payload)}
		}
		builder := strings.builder_make(context.temp_allocator)
		options: json.Marshal_Options
		if json.marshal_to_builder(&builder, document, &options) != nil {
			return cli_protocol.response(.Failed, "not enough memory for the reply")
		}
		if raw_result != "" {
			// Preserve raw script JSON verbatim, including numbers beyond the decoder's precision.
			resize(&builder.buf, len(builder.buf) - 1)
			strings.write_string(&builder, ",\"result\":")
			strings.write_string(&builder, raw_result)
			strings.write_byte(&builder, '}')
		}
		response.text = strings.to_string(builder)
		return response
	}
	b := strings.builder_make(context.temp_allocator)
	if !ok {
		strings.write_string(&b, outcome.message)
		if created, present := outcome.payload.(Outcome_Created); present && created.pane != 0 {
			fmt.sbprintf(&b, " (pane %d)", created.pane)
		}
	} else {
		switch payload in outcome.payload {
		case Outcome_Created:
			fmt.sbprintf(&b, "%d", payload.pane)
		case Outcome_Usage:
			cli_protocol.command_report_write(&b, cli_protocol.Command_Report(payload))
		case Outcome_Catalogue:
			for command, i in payload {
				if i > 0 {strings.write_byte(&b, '\n')}
				fmt.sbprintf(&b, "%-30s %s", command.name, command.title)
			}
		case Outcome_Panes:
			strings.write_string(&b, PANE_COLUMNS)
			for pane in payload {
				strings.write_byte(&b, '\n')
				plain_pane_row(&b, pane)
			}
		case Outcome_Pane_Status:
			plain_pane_row(&b, cli_protocol.Pane_Report(payload))
		case Outcome_Tabs:
			strings.write_string(&b, "workspace\ttab\tfocused\tselected\tpanes\tname")
			for tab in payload {
				fmt.sbprintf(&b, "\n%s\t%d\t%s\t%s\t%d\t%s", plain_text(tab.workspace_name), tab.tab,
					plain_flag(tab.focused), plain_flag(tab.selected), tab.panes, plain_text(tab.name))
			}
		case Outcome_Workspaces:
			strings.write_string(&b, "id\tfocused\twindow\ttabs\tname")
			for workspace in payload {
				window := workspace.visible ? "visible" : workspace.window ? "hidden" : "-"
				fmt.sbprintf(&b, "\n%d\t%s\t%s\t%d\t%s", workspace.id, plain_flag(workspace.focused), window,
					workspace.tabs, plain_text(workspace.name))
			}
		case Outcome_Layout:
			for pane, i in payload {
				if i > 0 {strings.write_byte(&b, '\n')}
				fmt.sbprintf(&b, "%d", pane.id)
			}
		case Outcome_Text:
			strings.write_string(&b, string(payload))
		case Outcome_Process:
			data, err := json.marshal(cli_protocol.Process_Report(payload), {}, context.temp_allocator)
			if err != nil {return cli_protocol.response(.Failed, "not enough memory for the reply")}
			strings.write_string(&b, string(data))
		case Outcome_Json:
			strings.write_string(&b, string(payload))
		}
	}
	response.text = strings.to_string(b)
	return response
}

// The columns of a plain pane row; a pane's name stands in for its title. New columns go last, so
// scripts that read columns by position keep working.
@(private = "file")
PANE_COLUMNS :: "id\tfocused\tworkspace\ttab\tstatus\tprocess\ttitle\tdirectory\tpid\ttab_name\tgrid"

@(private = "file")
plain_pane_row :: proc(b: ^strings.Builder, pane: cli_protocol.Pane_Report) {
	title := pane.name != "" ? pane.name : pane.title
	tab := pane.tab > 0 ? fmt.tprintf("%d", pane.tab) : ""
	pid := ""
	if id, found := pane.pid.?; found {pid = fmt.tprintf("%d", id)}
	grid := ""
	if size, found := pane.grid.?; found {grid = fmt.tprintf("%dx%d", size.columns, size.rows)}
	fmt.sbprintf(b, "%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", pane.id, plain_flag(pane.focused),
		plain_text(pane.workspace_name), plain_text(tab), pane.status, plain_text(pane.process),
		plain_text(title), plain_text(pane.directory), plain_text(pid), plain_text(pane.tab_name),
		plain_text(grid))
}

@(private = "file")
plain_text :: proc(text: string) -> string {
	return text != "" ? text : "-"
}

@(private = "file")
plain_flag :: proc(set: bool) -> string {
	return set ? "*" : "-"
}
