package cli

import "aio:commands"
import "aio:control"
import "aio:instance"
import "core:encoding/json"
import "core:fmt"
import "core:os"
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

@(private)
interrupted: bool

main :: proc() {
	code := start()
	free_all(context.temp_allocator)
	os.exit(int(code))
}

@(private, require_results)
start :: proc() -> commands.Status {
	args, argument_error := instance.command_line(context.allocator)
	if argument_error != .None {
		fmt.eprintln("aio: could not read the command line")
		return .Usage
	}
	defer instance.command_line_destroy(args, context.allocator)
	if len(args) == 0 || len(args) == 1 && (args[0] == "help" || args[0] == "--help" || args[0] == "-h") {
		fmt.print(USAGE)
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
	response, status := send(pipe, request(o, caller, context.temp_allocator))
	if status == .Unreachable {return status}
	if response.text != "" {
		if response.ok || o.json {fmt.println(response.text)} else {fmt.eprintfln("aio: %s", response.text)}
	}
	return status
}

// One request on its own connection, so other clients can interleave between a wait's polls.
@(private, require_results)
send :: proc(pipe: string, request: []string) -> (control.Response, commands.Status) {
	client, connect_error := control.connect(pipe, CONNECT_TIMEOUT_MS, context.temp_allocator)
	if connect_error != .None {
		fmt.eprintln(
			"aio: AIODev is not reachable. Start it and turn on Command Line Control in Settings " +
			"(control.enabled).",
		)
		return {}, .Unreachable
	}
	defer control.close(&client)
	response, call_error := control.call(&client, request, CALL_TIMEOUT_MS)
	if call_error != .None {
		fmt.eprintfln("aio: lost the connection to AIODev (%v)", call_error)
		return {}, .Unreachable
	}
	if response.status != 0 {return response, commands.Status(response.status)}
	return response, response.ok ? .Ok : .Failed
}

@(private)
Wait_Reply :: struct {
	error: string,
	panes: []struct {
		status:    string,
		exit_code: u32,
	},
}

// Polls until the pane shows the text or its program exits, so no request holds the pipe.
@(private, require_results)
wait :: proc(o: Options, pipe, caller: string) -> commands.Status {
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
		reply: Wait_Reply
		parsed := o.wait.exit &&
			json.unmarshal_string(response.text, &reply, allocator = context.temp_allocator) == nil
		if status != .Ok {
			if status != .Unreachable {fmt.eprintfln("aio: %s", parsed ? reply.error : response.text)}
			return status
		}
		if o.wait.exit {
			if !parsed || len(reply.panes) != 1 {
				fmt.eprintln("aio: AIODev sent an unexpected pane status")
				return .Failed
			}
			// AIODev remembers how recently closed panes ended, so a program that exits before the
			// first poll still reports its code. A pane closed while running reports closed.
			switch pane := reply.panes[0]; pane.status {
			case "running":
			case "closed":
				fmt.println(o.json ? response.text : "closed")
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
