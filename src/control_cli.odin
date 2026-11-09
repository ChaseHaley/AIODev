package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:control"
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

// The aio command line as App embeds it: the pipe it reaches the app through, and the directory holding
// aio.exe beside this executable, which each shell's PATH and AIODEV_CLI get; empty when aio.exe is
// missing.
Cli_State :: struct {
	cli:           Cli_Pipe,
	cli_directory: string,
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
	// AIODev has its own working directory, so a relative path means one in aio's, and a pane the
	// request opens starts in aio's unless --cwd names another, as a terminal's split starts where
	// its user is (WORK-367). An empty directory leaves each command's own default.
	if commands.invocation_paths_resolve(&invocation, request.directory, context.temp_allocator) != nil {
		return control_cli_reply(outcome_failure(.Failed, "not enough memory for the paths"), json_output)
	}
	if .Directory not_in invocation.given {invocation.directory = request.directory}
	return control_cli_reply(command_execute(app, Control_Request{caller}, invocation), json_output)
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
		switch payload in outcome.payload {
		case Outcome_Created:
			document.pane = payload.pane
		case Outcome_Text:
			document.text = string(payload)
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
		data, err := json.marshal(document, {}, context.temp_allocator)
		if err != nil {
			return cli_protocol.response(.Failed, "not enough memory for the reply")
		}
		response.text = string(data)
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
			fmt.sbprintf(&b, "%s\n%s", payload.usage, payload.title)
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
