package cli

import "aio:cli_protocol"
import "aio:control"
import "aio:instance"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:text/regex"
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
// A second server this build trusts, relative to its own directory: the verify build's aio.exe also
// reaches the headless verify build (WORK-349). Empty in release builds.
@(private)
SERVER_ALTERNATE :: #config(AIO_SERVER_ALTERNATE, "")

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
	if len(args) == 0 || len(args) == 1 && (args[0] == "--help" || args[0] == "-h") {
		print_usage()
		return len(args) == 0 ? .Usage : .Ok
	}
	if args[0] == AGENT_SESSION_COMMAND {return agent_session_record(args[1:])}
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
	if len(o.args) == 1 && o.args[0] == "help" {
		print_usage()
		return .Ok
	}
	if report, local := local_help(o); local {return help_print(report, o.json)}
	app_id, id_error := instance.app_id({name = o.instance}, context.allocator)
	if id_error != nil {return .Failed}
	defer delete(app_id)
	pipe, pipe_error := control.cli_pipe_name(app_id)
	if pipe_error != .None {return .Failed}
	defer delete(pipe)
	if o.waiting {return wait(o, pipe, caller)}
	if o.version {return version(o, pipe, caller)}
	// A directory that cannot be read leaves relative paths as given.
	directory, _ := os.get_working_directory(context.temp_allocator)
	response, status := send(pipe, request(o, caller, directory, context.temp_allocator), true)
	if status == .Unreachable {return status}
	if response.text != "" {
		if response.ok || o.json {fmt.println(response.text)} else {fmt.eprintfln("aio: %s", response.text)}
	}
	return status
}

// The process image this build expects behind the control pipe, `name` beside this executable.
@(private, require_results)
server_identity :: proc(name: string, allocator := context.allocator) -> (control.Server_Identity, bool) {
	executable, err := os.get_executable_path(allocator)
	if err != nil {return {}, false}
	defer delete(executable, allocator)
	image, join_error := filepath.join({filepath.dir(executable), name}, allocator)
	if join_error != nil {return {}, false}
	return {image = image}, true
}

// This aio's build, as build_warning compares it. The text is temporary.
@(private, require_results)
own_build :: proc() -> string {
	return cli_protocol.build_text(
		cli_protocol.BUILD_VERSION, cli_protocol.BUILD_ID, cli_protocol.BUILD_KIND, context.temp_allocator,
	)
}

// aio's build line, then the running AIODev's. aio prints its own first, so it still shows when
// AIODev is unreachable; under --json the reply's text holds both lines.
@(private, require_results)
version :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	own := own_build()
	line := fmt.tprintf("aio %s", own)
	if !o.json {fmt.println(line)}
	response, status := send(pipe, request(o, caller, "", context.temp_allocator), false)
	if status != .Unreachable && status != .Impostor {
		if warning := build_warning(own, response.ok ? response.text : "", context.temp_allocator);
		   warning != "" {fmt.eprintln(warning)}
	}
	if o.json {
		reply := cli_protocol.Reply_Json {
			ok     = response.ok,
			status = u8(status),
			text   = response.ok ? fmt.tprintf("%s\n%s", line, response.text) : line,
		}
		if !response.ok {reply.error = response.text}
		text, err := json.marshal(reply, {}, context.temp_allocator)
		if err != nil {
			fmt.eprintln("aio: not enough memory for the reply")
			return .Failed
		}
		fmt.println(string(text))
	} else if response.ok {
		fmt.println(response.text)
	} else if response.text != "" {
		fmt.eprintfln("aio: %s", response.text)
	}
	return status
}

// One request on its own connection, so other clients can interleave between a wait's polls. With
// `check_build`, aio first asks AIODev's build on the same connection and warns when it differs.
@(private, require_results)
send :: proc(pipe: string, request: []string, check_build: bool) -> (control.Response, cli_protocol.Status) {
	client, connect_error := control.connect(pipe, CONNECT_TIMEOUT_MS, context.temp_allocator)
	if connect_error != .None {
		fmt.eprintln(
			"aio: AIODev is not reachable. Start it and turn on Command Line Control in Settings " +
			"(control.enabled).",
		)
		return {}, .Unreachable
	}
	defer control.close(&client)
	identity, identity_ok := server_identity(SERVER_NAME, context.temp_allocator)
	if !identity_ok {
		fmt.eprintln("aio: could not locate the AIODev executable to verify the control pipe.")
		return {}, .Unreachable
	}
	verify_error := control.verify_server(&client, identity)
	if verify_error == .Impostor && SERVER_ALTERNATE != "" {
		if alternate, ok := server_identity(SERVER_ALTERNATE, context.temp_allocator); ok {
			verify_error = control.verify_server(&client, alternate)
		}
	}
	if verify_error != .None {
		if verify_error == .Impostor {
			fmt.eprintfln(
				"aio: the control pipe is served by an unverified process (PID %d); refusing to send. " +
				"If AIODev runs from another folder, use the aio beside it ($env:AIODEV_CLI in its panes).",
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
	if check_build {
		version_command := [1]string{cli_protocol.VERSION_COMMAND}
		query := cli_protocol.request_encode({command = version_command[:]}, context.temp_allocator)
		reply, reply_error := control.call(&client, query, CALL_TIMEOUT_MS)
		if reply_error != .None {
			fmt.eprintfln("aio: lost the connection to AIODev (%v)", reply_error)
			return {}, .Unreachable
		}
		if warning := build_warning(own_build(), reply.ok ? reply.text : "", context.temp_allocator);
		   warning != "" {fmt.eprintln(warning)}
	}
	response, call_error := control.call(&client, request, CALL_TIMEOUT_MS)
	if call_error != .None {
		fmt.eprintfln("aio: lost the connection to AIODev (%v)", call_error)
		return {}, .Unreachable
	}
	return response, cli_protocol.response_status(response)
}

// Prints help aio answers itself, in the shape AIODev's help replies take.
@(private, require_results)
help_print :: proc(report: cli_protocol.Command_Report, json_output: bool) -> cli_protocol.Status {
	if !json_output {
		b := strings.builder_make(context.temp_allocator)
		cli_protocol.command_report_write(&b, report)
		fmt.println(strings.to_string(b))
		return .Ok
	}
	data, err := json.marshal(
		cli_protocol.Reply_Json{ok = true, commands = {report}},
		{},
		context.temp_allocator,
	)
	if err != nil {
		fmt.eprintln("aio: not enough memory for the help")
		return .Failed
	}
	fmt.println(string(data))
	return .Ok
}

// Polls until the pane shows the text or a matching line and, with --idle, its screen has stayed the
// same for that long, or until its program exits. No request holds the pipe.
@(private, require_results)
wait :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	pattern: Maybe(regex.Regular_Expression)
	if o.wait.regex != "" {
		compiled, problem := wait_pattern(o.wait.regex)
		if problem != "" {
			fmt.eprintfln("aio: %s; use aio help", problem)
			return .Usage
		}
		pattern = compiled
	}
	defer if compiled, ok := pattern.?; ok {regex.destroy_regex(compiled)}
	if !bool(w.SetConsoleCtrlHandler(on_interrupt, true)) {
		fmt.eprintln("aio: could not watch for Ctrl+C")
		return .Failed
	}
	// The screen is read with soft-wrapped rows joined, so text split by a wrap still matches.
	read_args := [4]string{cli_protocol.PANE_READ_COMMAND, "--unwrap", "--pane", o.wait.pane}
	status_args := [3]string{cli_protocol.PANE_STATUS_COMMAND, "--pane", o.wait.pane}
	query_args := o.wait.exit ? status_args[:] : read_args[:]
	query := Options {
		json = o.wait.exit,
		args = o.wait.pane == "" ? query_args[:len(query_args) - 2] : query_args,
	}
	start := time.tick_now()
	// The build is checked once, not on every poll.
	check_build := true
	// The screen's digest when it last changed, and when that poll saw it.
	screen: u64
	changed := start
	for polls := 0;; polls += 1 {
		response, status := send(pipe, request(query, caller, "", context.temp_allocator), check_build)
		check_build = false
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
		} else {
			digest := hash.fnv64a(transmute([]u8)response.text)
			if polls == 0 || digest != screen {screen, changed = digest, time.tick_now()}
			quiet := time.tick_since(changed) >= time.Duration(o.wait.idle_ms) * time.Millisecond
			if quiet && wait_found(o.wait, pattern, response.text) {
				if o.json {fmt.println(`{"ok":true,"status":0}`)}
				return .Ok
			}
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
