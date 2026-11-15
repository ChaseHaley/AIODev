package cli

import "aio:cli_protocol"
import "aio:commands"
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
// How long aio events waits for a line before it checks for Ctrl+C again.
@(private)
STREAM_POLL_MS :: 100
// The app executable built beside this CLI. build.ps1 supplies the exact name for verify builds.
@(private)
SERVER_NAME :: #config(AIO_SERVER_NAME, "aiodev.exe")
// A second server this build trusts, relative to its own directory: the verify build's aio.exe also
// reaches the headless verify build (WORK-349). Empty in release builds.
@(private)
SERVER_ALTERNATE :: #config(AIO_SERVER_ALTERNATE, "")

// The aio a pane's environment names, and the variable marking an aio another one handed its call to.
@(private)
CLI_VARIABLE :: "AIODEV_CLI"
@(private)
DELEGATED_VARIABLE :: "AIODEV_CLI_DELEGATED"

@(private)
interrupted: bool
// Set once aio may have acted on its own, by printing, reading standard input or running Lua, so a
// later connection cannot hand the call to another aio, which would repeat that.
@(private)
delegation_closed: bool

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
	if args[0] == TURN_HOOK_COMMAND {return turn_hook_run(args[1:])}
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
	// Config check reads init.lua locally; it only asks a running AIODev where init.lua is.
	if o.checking {return config_check_run(o, pipe)}
	if o.waiting {return wait(o, pipe, caller)}
	if o.version {return version(o, pipe, caller)}
	if o.streaming {return stream_events(o, pipe, caller)}
	if o.executing {return exec_run(o, pipe, caller)}
	if o.typing {return types_run(o, pipe, caller)}
	// A directory that cannot be read leaves relative paths as given.
	directory, _ := os.get_working_directory(context.temp_allocator)
	response, status := send(pipe, request(o, caller, directory, context.temp_allocator), true)
	if status == .Unreachable {return status}
	if response.text != "" {
		if response.ok || o.json {fmt.println(response.text)} else {fmt.eprintfln("aio: %s", response.text)}
	}
	return status
}

// The process image `name` in `folder`, as verify_server checks it.
@(private, require_results)
server_identity :: proc(
	folder, name: string,
	allocator := context.allocator,
) -> (
	control.Server_Identity,
	bool,
) {
	parts := [2]string{folder, name}
	image, join_error := filepath.join(parts[:], allocator)
	if join_error != nil {return {}, false}
	return {image = image}, true
}

// Checks the connected server against SERVER_NAME, then SERVER_ALTERNATE, in `folder`.
@(private, require_results)
verify_beside :: proc(client: ^control.Client, folder: string) -> control.Error {
	identity, identity_ok := server_identity(folder, SERVER_NAME, context.temp_allocator)
	if !identity_ok {return .Out_Of_Memory}
	verify_error := control.verify_server(client, identity)
	if verify_error != .Impostor || SERVER_ALTERNATE == "" {return verify_error}
	alternate, alternate_ok := server_identity(folder, SERVER_ALTERNATE, context.temp_allocator)
	if !alternate_ok {return .Out_Of_Memory}
	return control.verify_server(client, alternate)
}

// The aio to hand an unverified pipe server's call to: `cli`, the AIODEV_CLI value, made absolute,
// when it names another aio than `own`, this one's path, compared absolute, in any case and with
// either separator, and this aio is not itself a hand-over. "" otherwise. The caller still checks
// that the file exists and that the pipe's server runs from its folder.
@(require_results)
delegation_target :: proc(own, cli: string, delegated: bool, allocator := context.allocator) -> string {
	if delegated || cli == "" {return ""}
	target, target_error := filepath.abs(cli, allocator)
	if target_error != nil {return ""}
	self, self_error := filepath.abs(own, context.temp_allocator)
	if self_error != nil || strings.equal_fold(target, self) {return ""}
	return target
}

// Hands the call to the aio a pane names in AIODEV_CLI when the pipe's server runs from that aio's
// folder: runs it with this aio's arguments, inheriting the console and environment, and exits with
// its code. AIODEV_CLI comes from the pane's environment, never from the server. Returns "" without
// acting when the hand-over does not apply, or the problem when that aio cannot start. Nothing was
// sent on `client`, which it closes first.
@(private, require_results)
delegate :: proc(client: ^control.Client, own: string) -> string {
	if delegation_closed {return ""}
	cli, _ := os.lookup_env(CLI_VARIABLE, context.temp_allocator)
	_, delegated := os.lookup_env(DELEGATED_VARIABLE, context.temp_allocator)
	target := delegation_target(own, cli, delegated, context.temp_allocator)
	if target == "" || !os.exists(target) {return ""}
	if control.verify_server_folder(client, filepath.dir(target)) != .None {return ""}
	control.close(client)
	argv := make([]string, len(os.args), context.temp_allocator)
	argv[0] = target
	copy(argv[1:], os.args[1:])
	line, line_error := commands.command_line_join(argv, context.temp_allocator)
	application := w.utf8_to_wstring(target, context.temp_allocator)
	command := w.utf8_to_wstring(line, context.temp_allocator)
	if line_error != nil || application == nil || command == nil || os.set_env(DELEGATED_VARIABLE, "1") != nil {
		return fmt.tprintf("aio: handing the call over to %s failed: out of memory.", target)
	}
	startup := w.STARTUPINFOW {
		cb         = size_of(w.STARTUPINFOW),
		dwFlags    = w.STARTF_USESTDHANDLES,
		hStdInput  = w.GetStdHandle(w.STD_INPUT_HANDLE),
		hStdOutput = w.GetStdHandle(w.STD_OUTPUT_HANDLE),
		hStdError  = w.GetStdHandle(w.STD_ERROR_HANDLE),
	}
	// The child inherits only these: the control pipe is closed and aio opens no other handles.
	standard := [3]w.HANDLE{startup.hStdInput, startup.hStdOutput, startup.hStdError}
	for handle in standard {
		if handle == nil || handle == w.INVALID_HANDLE_VALUE {continue}
		w.SetHandleInformation(handle, w.HANDLE_FLAG_INHERIT, w.HANDLE_FLAG_INHERIT)
	}
	info: w.PROCESS_INFORMATION
	if !bool(w.CreateProcessW(application, command, nil, nil, true, 0, nil, nil, &startup, &info)) {
		return fmt.tprintf("aio: handing the call over to %s failed (Win32 %d).", target, w.GetLastError())
	}
	w.CloseHandle(info.hThread)
	// Only the child handles Ctrl+C now, so its exit code, 130 included, becomes aio's.
	w.SetConsoleCtrlHandler(nil, true)
	w.WaitForSingleObject(info.hProcess, w.INFINITE)
	code: w.DWORD
	if !bool(w.GetExitCodeProcess(info.hProcess, &code)) {code = w.DWORD(cli_protocol.Status.Failed)}
	os.exit(int(code))
}

// For a command that acts before it reaches AIODev, such as a script: hands the call over now, before
// it acts, if a connection would, and never afterwards. An unreachable or verified AIODev changes nothing.
@(private)
delegate_before_acting :: proc(pipe: string) {
	defer delegation_closed = true
	allocator := context.temp_allocator
	client, connect_error := control.connect(pipe, CONNECT_TIMEOUT_MS, allocator, wait_absent = false)
	if connect_error != .None {return}
	defer control.close(&client)
	executable, executable_error := os.get_executable_path(context.temp_allocator)
	if executable_error != nil || verify_beside(&client, filepath.dir(executable)) != .Impostor {return}
	if problem := delegate(&client, executable); problem != "" {fmt.eprintln(problem)}
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
	// aio prints its own build before it asks AIODev's.
	delegate_before_acting(pipe)
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
	client, status := connect_verified(pipe)
	if status != .Ok {return {}, status}
	defer control.close(&client)
	return send_on(&client, request, check_build)
}

// One request on a verified connection; see send.
@(private, require_results)
send_on :: proc(
	client: ^control.Client,
	request: []string,
	check_build: bool,
) -> (
	control.Response,
	cli_protocol.Status,
) {
	if check_build {
		version_command := [1]string{cli_protocol.VERSION_COMMAND}
		query := cli_protocol.request_encode({command = version_command[:]}, context.temp_allocator)
		reply, reply_error := control.call(client, query, CALL_TIMEOUT_MS)
		if reply_error != .None {
			fmt.eprintfln("aio: lost the connection to AIODev (%v)", reply_error)
			return {}, .Unreachable
		}
		if warning := build_warning(own_build(), reply.ok ? reply.text : "", context.temp_allocator);
		   warning != "" {fmt.eprintln(warning)}
	}
	response, call_error := control.call(client, request, CALL_TIMEOUT_MS)
	if call_error != .None {
		fmt.eprintfln("aio: lost the connection to AIODev (%v)", call_error)
		return {}, .Unreachable
	}
	return response, cli_protocol.response_status(response)
}

// The init.lua the AIODev on a verified connection loads, so aio types and aio config check find the
// folder of an instance started with --data-dir; "" when it does not say. The text is temporary.
@(private, require_results)
lua_path_ask :: proc(client: ^control.Client) -> string {
	command := [1]string{LUA_PATH_COMMAND}
	request := cli_protocol.Request {
		command = command[:],
	}
	query := cli_protocol.request_encode(request, context.temp_allocator)
	reply, err := control.call(client, query, CALL_TIMEOUT_MS)
	if err != .None || !reply.ok {return ""}
	return reply.text
}

// Connects to the pipe and checks that the expected AIODev serves it, reporting either failure; the
// caller closes the client it returns with Ok. A `probe` neither waits for an AIODev that is not
// running, whose pipe does not exist, nor reports it unreachable; it still waits for a busy pipe.
@(private, require_results)
connect_verified :: proc(
	pipe: string,
	allocator := context.temp_allocator,
	probe := false,
) -> (
	control.Client,
	cli_protocol.Status,
) {
	client, connect_error := control.connect(pipe, CONNECT_TIMEOUT_MS, allocator, wait_absent = !probe)
	if connect_error != .None {
		if probe {return {}, .Unreachable}
		fmt.eprintln(
			"aio: AIODev is not reachable. Start it and turn on \"Command line control\" in Settings " +
			"(control.enabled).",
		)
		return {}, .Unreachable
	}
	verified := false
	defer if !verified {control.close(&client)}
	executable, executable_error := os.get_executable_path(context.temp_allocator)
	if executable_error != nil {
		fmt.eprintln("aio: could not locate the AIODev executable to verify the control pipe.")
		return {}, .Impostor
	}
	server := client.process_id
	verify_error := verify_beside(&client, filepath.dir(executable))
	handover := ""
	if verify_error == .Impostor {handover = delegate(&client, executable)}
	if verify_error != .None {
		if verify_error == .Impostor {
			fmt.eprintfln(
				"aio: the control pipe is served by an unverified process (PID %d); refusing to send. " +
				"If AIODev runs from another folder, use the aio beside it ($env:AIODEV_CLI in its panes).",
				server,
			)
			if handover != "" {fmt.eprintln(handover)}
			return {}, .Impostor
		}
		fmt.eprintfln(
			"aio: could not verify the control pipe server (%v); refusing to send.",
			verify_error,
		)
		return {}, .Impostor
	}
	verified = true
	return client, .Ok
}

// Subscribes on one connection and prints each event line until Ctrl+C or until AIODev closes the
// connection. Reads poll briefly so Ctrl+C ends the stream promptly; a partial line waits for the next.
@(private, require_results)
stream_events :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	if !bool(w.SetConsoleCtrlHandler(on_interrupt, true)) {
		fmt.eprintln("aio: could not watch for Ctrl+C")
		return .Failed
	}
	client, status := connect_verified(pipe, context.allocator)
	if status != .Ok {return status}
	defer control.close(&client)
	subscription := request(o, caller, "", context.temp_allocator)
	response, err := control.subscribe(&client, subscription, CALL_TIMEOUT_MS)
	if err != .None {
		if sync.atomic_load(&interrupted) {return .Interrupted}
		fmt.eprintfln("aio: lost the connection to AIODev (%v)", err)
		return .Unreachable
	}
	defer control.response_destroy(&response)
	if !response.ok {
		if o.json {fmt.println(response.text)} else {fmt.eprintfln("aio: %s", response.text)}
		return cli_protocol.response_status(response)
	}
	for {
		free_all(context.temp_allocator)
		if sync.atomic_load(&interrupted) {return .Interrupted}
		line, read_error := control.next_line(&client, STREAM_POLL_MS, context.temp_allocator)
		if sync.atomic_load(&interrupted) {return .Interrupted}
		if read_error == .Timeout {continue}
		if read_error != .None {
			fmt.eprintln("aio: AIODev closed the event stream")
			return .Unreachable
		}
		if o.json {
			fmt.println(line)
			continue
		}
		text, valid := event_plain(line, context.temp_allocator)
		if !valid {
			fmt.eprintfln("aio: AIODev sent an unexpected event line: %s", line)
			return .Failed
		}
		fmt.println(text)
	}
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
