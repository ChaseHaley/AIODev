package cli

import "aio:cli_protocol"
import "aio:control"
import "aio:instance"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:time"

@(private)
CONNECT_TIMEOUT_MS :: 1000
@(private)
CALL_TIMEOUT_MS :: 15000
@(private)
WAIT_INTERVAL :: 100 * time.Millisecond
// The app executable built beside this CLI. build.ps1 supplies the exact name for verify builds.
@(private)
SERVER_NAME :: #config(AIO_SERVER_NAME, "aiodev.exe")

@(private)
interrupted: bool

main :: proc() {
	code := start()
	free_all(context.temp_allocator)
	os.exit(int(code))
}

@(private, require_results)
start :: proc() -> cli_protocol.Status {
	args, argument_error := instance.command_line(context.allocator)
	if argument_error != .None {
		fmt.eprintln("aio: could not read the command line")
		return .Usage
	}
	defer instance.command_line_destroy(args, context.allocator)
	if len(args) == 0 || len(args) == 1 && (args[0] == "help" || args[0] == "--help" || args[0] == "-h") {
		print_usage()
		return len(args) == 0 ? .Usage : .Ok
	}
	// These outlive wait's per-poll release of the temporary allocator.
	named, _ := os.lookup_env("AIODEV_INSTANCE", context.allocator)
	defer delete(named)
	caller, _ := os.lookup_env("AIODEV_PANE", context.allocator)
	defer delete(caller)
	o, problem := parse_options(args, named)
	if problem != "" {
		fmt.eprintfln("aio: %s; use aio help", problem)
		return .Usage
	}
	app_id, id_error := instance.app_id({name = o.instance}, context.allocator)
	if id_error != nil {return .Failed}
	defer delete(app_id)
	pipe, pipe_error := control.cli_pipe_name(app_id)
	if pipe_error != .None {return .Failed}
	defer delete(pipe)
	if o.waiting {return wait(o, pipe, caller)}
	if directory, directory_error := os.get_working_directory(context.temp_allocator); directory_error == nil {
		o.args = absolute_file_argument(o.args, directory, context.temp_allocator)
	}
	response, status := send(pipe, request(o, caller, context.temp_allocator))
	if status == .Unreachable {return status}
	if response.text != "" {
		if response.ok || o.json {fmt.println(response.text)} else {fmt.eprintfln("aio: %s", response.text)}
	}
	return status
}

// The process image this build expects behind the control pipe.
@(private, require_results)
server_identity :: proc(allocator := context.allocator) -> (control.Server_Identity, bool) {
	executable, err := os.get_executable_path(allocator)
	if err != nil {return {}, false}
	defer delete(executable, allocator)
	image, join_error := filepath.join({filepath.dir(executable), SERVER_NAME}, allocator)
	if join_error != nil {return {}, false}
	return {image = image}, true
}

// One request on its own connection, so other clients can interleave between a wait's polls.
@(private, require_results)
send :: proc(pipe: string, request: []string) -> (control.Response, cli_protocol.Status) {
	client, connect_error := control.connect(pipe, CONNECT_TIMEOUT_MS, context.temp_allocator)
	if connect_error != .None {
		fmt.eprintln(
			"aio: AIODev is not reachable. Start it and turn on Command Line Control in Settings " +
			"(control.enabled).",
		)
		return {}, .Unreachable
	}
	defer control.close(&client)
	identity, identity_ok := server_identity(context.temp_allocator)
	if !identity_ok {
		fmt.eprintln("aio: could not locate the AIODev executable to verify the control pipe.")
		return {}, .Unreachable
	}
	if verify_error := control.verify_server(&client, identity); verify_error != .None {
		if verify_error == .Impostor {
			fmt.eprintfln(
				"aio: the control pipe is served by an unverified process (PID %d); refusing to send.",
				client.process_id,
			)
			return {}, .Impostor
		}
		fmt.eprintfln(
			"aio: could not verify the control pipe server (%v); refusing to send.",
			verify_error,
		)
		return {}, .Unreachable
	}
	response, call_error := control.call(&client, request, CALL_TIMEOUT_MS)
	if call_error != .None {
		fmt.eprintfln("aio: lost the connection to AIODev (%v)", call_error)
		return {}, .Unreachable
	}
	return response, cli_protocol.response_status(response)
}

// Polls until the pane shows the text or its program exits, so no request holds the pipe.
@(private, require_results)
wait :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	if !bool(w.SetConsoleCtrlHandler(on_interrupt, true)) {
		fmt.eprintln("aio: could not watch for Ctrl+C")
		return .Failed
	}
	query_args := [3]string{o.wait.exit ? "pane.status" : "pane.read", "--pane", o.wait.pane}
	query := Options {
		json = o.wait.exit,
		args = query_args[:o.wait.pane == "" ? 1 : 3],
	}
	start := time.tick_now()
	for {
		response, status := send(pipe, request(query, caller, context.temp_allocator))
		reply: cli_protocol.Reply_Json
		parsed := o.wait.exit &&
			json.unmarshal_string(response.text, &reply, allocator = context.temp_allocator) == nil
		if status != .Ok {
			if status != .Unreachable && status != .Impostor {
				fmt.eprintfln("aio: %s", parsed ? reply.error : response.text)
			}
			return status
		}
		if o.wait.exit {
			if !parsed || len(reply.panes) != 1 {
				fmt.eprintln("aio: AIODev sent an unexpected pane status")
				return .Failed
			}
			// AIODev remembers how recently closed panes ended, so a program that exits before the
			// first poll still reports its code. A pane closed while running reports closed.
			pane := reply.panes[0]
			pane_status, known := cli_protocol.pane_status_parse(pane.status)
			switch {
			case known && pane_status == .Running:
			case known && pane_status == .Closed:
				fmt.println(o.json ? response.text : cli_protocol.PANE_STATUS_WORDS[.Closed])
				return .Ok
			case:
				fmt.println(o.json ? response.text : fmt.tprintf("%d", pane.exit_code))
				return .Ok
			}
		} else if strings.contains(response.text, o.wait.text) {
			if o.json {fmt.println(`{"ok":true,"status":0}`)}
			return .Ok
		}
		if sync.atomic_load(&interrupted) {return .Interrupted}
		if o.wait.timeout_ms > 0 && time.tick_since(start) >= time.Duration(o.wait.timeout_ms) * time.Millisecond {
			fmt.eprintln("aio: timed out waiting for the pane")
			return .Failed
		}
		time.sleep(WAIT_INTERVAL)
		free_all(context.temp_allocator)
	}
}

@(private)
on_interrupt :: proc "system" (kind: w.DWORD) -> w.BOOL {
	if kind != w.CTRL_C_EVENT && kind != w.CTRL_BREAK_EVENT {return false}
	sync.atomic_store(&interrupted, true)
	return true
}
