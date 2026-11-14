package cli

import "aio:cli_protocol"
import "aio:control"
import "aio:events"
import "aio:instance"
import "aio:scripting"
import "aio:spawn"
import libc "core:c/libc"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import w "core:sys/windows"
import "core:thread"
import "core:time"

// The script host behind `aio exec`: a Script-kind state whose commands go over the CLI pipe, one
// at a time on their own connections, and whose events arrive on one subscribed connection that a
// thread reads. The loop sleeps on one event object that timers' deadlines bound and that process
// output, event lines and Ctrl+C signal, so an idle script costs nothing.

// Signalled by Ctrl+C, process output, event lines and a lost event stream; the loop waits on it.
@(private)
exec_wake: w.HANDLE

@(private)
Script_Host :: struct {
	pipe, caller, directory: string,
	// The first unreachable or unverified AIODev; once set, commands fail without trying and the
	// run ends with this status.
	failure:                 cli_protocol.Status,
	build_checked:           bool,
	// What the script listens for now, and what the stream is subscribed to. The subscription only
	// grows, so a script that waits for an event again and again keeps one connection and misses
	// nothing between its waits; lines for kinds no longer wanted are dropped.
	wanted, subscribed:      events.Kinds,
	stream:                  ^Event_Stream,
	// Lines taken from the stream, swapped with its list so delivery holds no lock and survives a
	// handler that resubscribes, which replaces the stream.
	received:                [dynamic]string,
}

@(private)
Event_Stream :: struct {
	client: control.Client,
	reader: ^thread.Thread,
	wake:   w.HANDLE,
	stop:   bool,
	lost:   bool,
	mutex:  sync.Mutex,
	lines:  [dynamic]string,
}

// Runs `aio exec`: an action by name over the pipe, or a script until it has nothing left to do.
@(private, require_results)
exec_run :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	if o.exec.target == .Action {return exec_action(o, pipe, caller)}
	args_text, problem := exec_args(o.exec, context.temp_allocator)
	if problem != "" {
		fmt.eprintfln("aio: %s; use aio help exec", problem)
		return .Usage
	}
	// The loop frees the temporary allocator; the state reads args only while it is created, but
	// owning it keeps that independent of where create happens.
	args := strings.clone(args_text)
	defer delete(args)
	directory, _ := os.get_working_directory(context.allocator)
	defer delete(directory)
	root, name, source := directory, o.exec.source, o.exec.source
	absolute: string
	defer delete(absolute)
	stdin_data: []u8
	defer delete(stdin_data)
	switch o.exec.target {
	case .File:
		path_error: os.Error
		absolute, path_error = filepath.abs(o.exec.source, context.allocator)
		if path_error == nil {root = filepath.dir(absolute)}
	case .Code:
		name = "-e"
	case .Stdin:
		read_error: os.Error
		stdin_data, read_error = os.read_entire_file(os.stdin, context.allocator)
		if read_error != nil {
			fmt.eprintfln("aio: could not read the script from standard input: %s", os.error_string(read_error))
			return .Failed
		}
		name, source = "stdin", string(stdin_data)
	case .Action:
		// exec_action ran it above.
		return .Failed
	}
	exec_wake = w.CreateEventW(nil, false, false, nil)
	if exec_wake == nil {
		fmt.eprintln("aio: could not create the script's wake event")
		return .Failed
	}
	// Lua's print writes through the C runtime, whose buffer aio's exit would drop and whose output
	// would otherwise land after aio's own; unbuffered, both keep their order.
	libc.setvbuf(libc.stdout, nil, libc._IONBF, 0)
	defer {
		w.CloseHandle(exec_wake)
		exec_wake = nil
	}
	if !bool(w.SetConsoleCtrlHandler(exec_interrupt, true)) {
		fmt.eprintln("aio: could not watch for Ctrl+C")
		return .Failed
	}
	pane, _ := strconv.parse_uint(caller, 10)
	host := Script_Host {
		pipe      = pipe,
		caller    = caller,
		directory = directory,
		received  = make([dynamic]string, context.allocator),
	}
	defer delete(host.received)
	backend := scripting.Backend {
		data     = &host,
		command  = host_command,
		interest = host_interest,
		log      = host_log,
	}
	config := scripting.Config {
		kind = .Script,
		root = root,
		args = args,
		pane = u32(pane),
	}
	// The stream closes after the state, whose destroy withdraws its interest last.
	defer stream_close(&host)
	s, create_problem := scripting.create(config, backend)
	if s == nil {
		fmt.eprintfln("Error: %s", create_problem)
		return .Failed
	}
	defer scripting.destroy(s)
	wake := spawn.Wake {
		data = exec_wake,
		wake = exec_signal,
	}
	scripting.set_wake(s, wake)
	clock_start := time.tick_now()
	result: scripting.Run_Result
	if o.exec.target == .File {
		result = scripting.run_file(s, source)
	} else {
		result = scripting.run_source(s, name, source)
	}
	failed := exec_report(s, o.exec.fail_fast)
	if host.failure != .Ok {return host.failure}
	if !result.ok {
		fmt.eprintfln("Error: %s", result.message)
		return .Failed
	}
	if failed {return .Failed}
	if text := exec_result_text(result.value, o.json, context.temp_allocator); text != "" {fmt.println(text)}
	return exec_loop(s, &host, o, result.finished, clock_start)
}

// Runs the script's timers, waits, processes and handlers until its top level has finished and it
// has nothing left to do, it stops, --for runs out, Ctrl+C, a lost AIODev, a top level that fails
// after suspending or, with --fail-fast, a handler error.
@(private, require_results)
exec_loop :: proc(
	s: ^scripting.State,
	host: ^Script_Host,
	o: Options,
	top_finished: bool,
	clock_start: time.Tick,
) -> cli_protocol.Status {
	seconds :: proc(start: time.Tick) -> f64 {return f64(time.tick_since(start)) / f64(time.Second)}
	e := o.exec
	deadline := f64(e.for_ms) / 1000
	top_done := top_finished
	for {
		free_all(context.temp_allocator)
		if sync.atomic_load(&interrupted) {return .Interrupted}
		if code, stopped := scripting.stopped(s); stopped {return stop_status(code)}
		exec_deliver(s, host)
		next, has_next := scripting.step(s, seconds(clock_start))
		if exec_report(s, e.fail_fast) {return .Failed}
		if host.failure != .Ok {return host.failure}
		if host.stream != nil && sync.atomic_load(&host.stream.lost) {
			fmt.eprintln("aio: AIODev closed the event stream")
			return .Unreachable
		}
		if code, stopped := scripting.stopped(s); stopped {return stop_status(code)}
		// A top level that suspended ends during a step or a delivery; its result prints then.
		if !top_done {
			if top, done := scripting.top_result(s); done {
				top_done = true
				if !top.ok {
					fmt.eprintfln("Error: %s", top.message)
					return .Failed
				}
				text := exec_result_text(top.value, o.json, context.temp_allocator)
				if text != "" {fmt.println(text)}
			}
		}
		// A suspended top level keeps the state busy, so not busy means it has finished and reported
		// above. --for keeps a script that listens for events running until it runs out.
		if !scripting.busy(s) && (e.for_ms == 0 || host.wanted == {}) {return .Ok}
		now := seconds(clock_start)
		if e.for_ms > 0 && now >= deadline {return .Ok}
		timeout := u32(w.INFINITE)
		if has_next {timeout = wait_ms(next - now)}
		if e.for_ms > 0 {timeout = min(timeout, wait_ms(deadline - now))}
		w.WaitForSingleObject(exec_wake, timeout)
	}
}

// Milliseconds to wait for a span in seconds, rounded up so a deadline has passed on waking.
@(private, require_results)
wait_ms :: proc(span: f64) -> u32 {
	if span <= 0 {return 0}
	return u32(min(math.ceil(span * 1000), f64(max(u32) - 1)))
}

// Prints the errors handlers, timers and process callbacks raised; true when --fail-fast ends the
// script on them.
@(private, require_results)
exec_report :: proc(s: ^scripting.State, fail_fast: bool) -> bool {
	errors := scripting.take_errors(s)
	for err in errors {fmt.eprintfln("Error: %s", err.message)}
	return fail_fast && len(errors) > 0
}

// Hands the received event lines the script still wants to it.
@(private)
exec_deliver :: proc(s: ^scripting.State, host: ^Script_Host) {
	stream := host.stream
	if stream == nil {return}
	sync.mutex_lock(&stream.mutex)
	host.received, stream.lines = stream.lines, host.received
	sync.mutex_unlock(&stream.mutex)
	if len(host.received) == 0 {return}
	list := make([dynamic]events.Event, 0, len(host.received), context.temp_allocator)
	for line in host.received {
		kind, valid := event_line_kind(line)
		if !valid {
			fmt.eprintfln("aio: AIODev sent an unexpected event line: %s", line)
			continue
		}
		if kind in host.wanted {append(&list, events.Event{kind = kind, fields = line})}
	}
	scripting.deliver(s, list[:])
	for line in host.received {delete(line)}
	clear(&host.received)
}

// Runs one action or command by name with the arguments as its fields and prints its result.
@(private, require_results)
exec_action :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	args, problem := exec_args(o.exec, context.temp_allocator)
	if problem != "" {
		fmt.eprintfln("aio: %s; use aio help exec", problem)
		return .Usage
	}
	if args == "" {args = "{}"}
	directory, _ := os.get_working_directory(context.temp_allocator)
	command := [5]string {
		o.exec.source, cli_protocol.FIELDS_OPTION, args, cli_protocol.ORIGIN_OPTION, "script",
	}
	request := cli_protocol.Request {
		caller    = caller,
		format    = .Json,
		directory = directory,
		command   = command[:],
	}
	encoded := cli_protocol.request_encode(request, context.temp_allocator)
	response, status := send(pipe, encoded, true)
	if status == .Unreachable || status == .Impostor {return status}
	if !response.ok {
		reply: cli_protocol.Reply_Json
		parsed := json.unmarshal_string(response.text, &reply, allocator = context.temp_allocator) == nil
		fmt.eprintfln("aio: %s", parsed && reply.error != "" ? reply.error : response.text)
		return status
	}
	if result, has_result := json_member(response.text, "result"); has_result {
		fmt.println(exec_result_text(result, o.json, context.temp_allocator))
	}
	return status
}

// Backend.command: one command over the pipe as the pane the script acts for, in aio's directory.
@(private)
host_command :: proc(data: rawptr, pane: u32, name, fields, origin: string) -> string {
	host := (^Script_Host)(data)
	if host.failure != .Ok {return unreachable_reply(host.failure)}
	command := [5]string{name, cli_protocol.FIELDS_OPTION, fields, cli_protocol.ORIGIN_OPTION, origin}
	request := cli_protocol.Request {
		caller    = pane == 0 ? "" : fmt.tprintf("%d", pane),
		format    = .Json,
		directory = host.directory,
		command   = command[:],
	}
	encoded := cli_protocol.request_encode(request, context.temp_allocator)
	response, status := send(host.pipe, encoded, !host.build_checked)
	host.build_checked = true
	if status == .Unreachable || status == .Impostor {
		host.failure = status
		return unreachable_reply(status)
	}
	return response.text
}

@(private, require_results)
unreachable_reply :: proc(status: cli_protocol.Status) -> string {
	return fmt.tprintf(`{"ok":false,"status":%d,"error":"AIODev is not reachable"}`, u8(status))
}

// Backend.interest: subscribes again only when the script wants a kind the stream lacks.
@(private)
host_interest :: proc(data: rawptr, kinds: events.Kinds) {
	host := (^Script_Host)(data)
	host.wanted = kinds
	if kinds - host.subscribed == {} || host.failure != .Ok {return}
	stream_close(host)
	host.subscribed += kinds
	stream_open(host)
}

// Backend.log: aio.log lines go to stderr, so stdout keeps only the result.
@(private)
host_log :: proc(_: rawptr, level, message: string) {
	fmt.eprintfln("%s: %s", level, message)
}

// Subscribes one connection to the kinds in host.subscribed and starts its reader.
@(private)
stream_open :: proc(host: ^Script_Host) {
	client, status := connect_verified(host.pipe, context.allocator)
	if status != .Ok {
		host.failure = status
		return
	}
	names := events.NAMES
	command := make([dynamic]string, 0, 1 + len(events.Kind), context.temp_allocator)
	append(&command, cli_protocol.EVENTS_COMMAND)
	for kind in host.subscribed {append(&command, names[kind])}
	request := cli_protocol.Request {
		caller  = host.caller,
		format  = .Text,
		command = command[:],
	}
	encoded := cli_protocol.request_encode(request, context.temp_allocator)
	response, err := control.subscribe(&client, encoded, CALL_TIMEOUT_MS)
	if err != .None {
		fmt.eprintfln("aio: lost the connection to AIODev (%v)", err)
		control.close(&client)
		host.failure = .Unreachable
		return
	}
	defer control.response_destroy(&response)
	if !response.ok {
		fmt.eprintfln("aio: %s", response.text)
		control.close(&client)
		host.failure = cli_protocol.response_status(response)
		return
	}
	stream := new(Event_Stream)
	stream.client, stream.wake = client, exec_wake
	stream.lines = make([dynamic]string, context.allocator)
	stream.reader = thread.create_and_start_with_poly_data(stream, stream_read)
	host.stream = stream
}

// Stops the reader, closes the connection and drops lines the script did not take.
@(private)
stream_close :: proc(host: ^Script_Host) {
	stream := host.stream
	if stream == nil {return}
	host.stream = nil
	sync.atomic_store(&stream.stop, true)
	thread.destroy(stream.reader)
	control.close(&stream.client)
	for line in stream.lines {delete(line)}
	delete(stream.lines)
	free(stream)
}

// The reader thread. It polls briefly so stream_close can stop it; the loop it wakes does not poll.
@(private)
stream_read :: proc(stream: ^Event_Stream) {
	for !sync.atomic_load(&stream.stop) {
		line, err := control.next_line(&stream.client, STREAM_POLL_MS, context.allocator)
		if err == .Timeout {continue}
		if err != .None {
			sync.atomic_store(&stream.lost, true)
			w.SetEvent(stream.wake)
			return
		}
		sync.mutex_lock(&stream.mutex)
		append(&stream.lines, line)
		sync.mutex_unlock(&stream.mutex)
		w.SetEvent(stream.wake)
	}
}

@(private)
exec_signal :: proc "contextless" (data: rawptr) {
	w.SetEvent(w.HANDLE(data))
}

// The first Ctrl+C asks the loop to end with 130 between script steps; a second one ends aio at once,
// for a script busy in Lua that never returns to the loop.
@(private)
exec_interrupt :: proc "system" (kind: w.DWORD) -> w.BOOL {
	if kind != w.CTRL_C_EVENT && kind != w.CTRL_BREAK_EVENT {return false}
	if sync.atomic_exchange(&interrupted, true) {w.ExitProcess(u32(cli_protocol.Status.Interrupted))}
	w.SetEvent(exec_wake)
	return true
}

// Runs `aio config check` on the named file, or on init.lua beside the instance's settings.
@(private, require_results)
config_check_run :: proc(o: Options) -> cli_protocol.Status {
	path := o.check.path
	if path == "" {
		options := instance.Options {
			name     = o.instance,
			data_dir = o.check.data_dir,
		}
		paths, err := instance.paths(options, context.temp_allocator)
		if err != nil || paths.settings == "" {
			fmt.eprintln("aio: could not find AIODev's settings folder")
			return .Failed
		}
		parts := [2]string{filepath.dir(paths.settings), INIT_FILE}
		joined, join_error := filepath.join(parts[:], context.temp_allocator)
		if join_error != nil {
			fmt.eprintln("aio: not enough memory for the init.lua path")
			return .Failed
		}
		path = joined
	}
	if absolute, err := filepath.abs(path, context.temp_allocator); err == nil {path = absolute}
	report, status := config_check(path, context.temp_allocator)
	if !o.json {
		fmt.println(report)
		return status
	}
	reply := cli_protocol.Reply_Json {
		ok     = status == .Ok,
		status = u8(status),
		text   = report,
	}
	options: json.Marshal_Options
	text, err := json.marshal(reply, options, context.temp_allocator)
	if err != nil {
		fmt.eprintln("aio: not enough memory for the report")
		return .Failed
	}
	fmt.println(string(text))
	return status
}
