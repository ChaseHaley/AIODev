// A LuaJIT state hosting the `aio` API for init.lua (Config) or a standalone script (Script).
// The scheduler and API surface live in runtime.lua; this package owns the state, the natives
// runtime.lua calls, the budget watchdog and the host-facing entry points. The caller
// serializes every call; only the watchdog runs on another thread.
package scripting

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import "aio:events"
import "aio:lua"
import "aio:spawn"
import "cosmos:host"

Host_Kind :: enum u8 {Config, Script}

// The host's side of the API. command returns the reply JSON exactly as `aio --json` prints it;
// the text only needs to live until command returns. Callbacks run with the context create was
// called with, on the thread that called the scripting entry point.
Backend :: struct {
	data: rawptr,
	command: proc(data: rawptr, pane: u32, name, fields, origin: string) -> string,
	interest: proc(data: rawptr, kinds: events.Kinds),
	log: proc(data: rawptr, level, message: string),
}

// Strings are read during create only. budget_ms <= 0 disables the watchdog; args is the JSON
// value a Script host exposes as aio.args.
Config :: struct {
	kind: Host_Kind,
	root: string,
	budget_ms: f64,
	args: string,
	pane: u32,
}

State :: struct {
	config: Config,
	backend: Backend,
	allocator: mem.Allocator,
	// Natives restore the creator's context so backend callbacks see its allocators and logger.
	ctx: runtime.Context,
	L: ^lua.State,
	runtime_ref: c.int,
	wake: host.Waker,
	processes: map[int]^spawn.Process,
	process_serial: int,
	budget: Budget,
	result_message, result_file, result_value: string,
	errors: [dynamic]Run_Error,
	pending_errors: [dynamic]Run_Error,
	// The host's copy of runtime.lua's declarations, rebuilt when its serial moves.
	declared: Declarations,
	declared_serial: int,
}

// value is the chunk's first result as JSON, or "" when it returned nothing or is still suspended.
// finished is false when a Script host's top level suspended; top_result reports how it ends.
Run_Result :: struct {
	ok, finished: bool,
	message, file: string,
	line: int,
	value: string,
}

// finished is false while the call is suspended in aio.sleep, aio.wait, a process wait or a prompt.
// returned_false is set only when the function finished synchronously with first result false.
Call_Result :: struct {
	ok, finished, returned_false: bool,
	value, message, file: string,
	line: int,
}

Run_Error :: struct {message, file: string, line: int}

@(private)
STATE_KEY :: "aio.scripting.state"

@(private)
push_text :: proc "contextless" (L: ^lua.State, text: string) {
	lua.pushlstring(L, cast(cstring)raw_data(text), c.size_t(len(text)))
}

// The text borrows Lua's string and stays valid while the value is on the stack.
@(private, require_results)
text_at :: proc "contextless" (L: ^lua.State, index: c.int) -> string {
	size: c.size_t
	text := lua.tolstring(L, index, &size)
	if text == nil {return ""}
	return string((cast([^]u8)text)[:int(size)])
}

@(private, require_results)
state_at :: proc "contextless" (L: ^lua.State) -> ^State {
	lua.getfield(L, lua.REGISTRYINDEX, STATE_KEY)
	s := cast(^State)lua.touserdata(L, -1)
	lua.pop(L, 1)
	return s
}

@(private)
install_native :: proc(L: ^lua.State, name: cstring, fn: lua.CFunction) {
	lua.pushcfunction(L, fn)
	lua.setfield(L, -2, name)
}

// Leaves the module's single result, or the error message, on the stack.
@(private, require_results)
load_module :: proc(L: ^lua.State, source: string, name: cstring, args: c.int) -> bool {
	if lua.L_loadbuffer(L, raw_data(source), c.size_t(len(source)), name) != .OK {return false}
	if args > 0 {lua.insert(L, -args - 1)}
	return lua.pcall(L, args, 1, 0) == 0
}

@(private, require_results)
create_failed :: proc(s: ^State) -> (^State, string) {
	message := strings.clone(text_at(s.L, -1), context.temp_allocator)
	destroy(s)
	return nil, message
}

// Result strings stay valid until the next run_file, run_source or call, or destroy.
@(require_results)
create :: proc(config: Config, backend: Backend, allocator := context.allocator) -> (^State, string) {
	s := new(State, allocator)
	s.config, s.backend, s.allocator = config, backend, allocator
	s.ctx = context
	s.ctx.allocator = allocator
	s.processes = make(map[int]^spawn.Process, allocator)
	s.errors = make([dynamic]Run_Error, allocator)
	s.pending_errors = make([dynamic]Run_Error, allocator)
	s.L = lua.L_newstate()
	if s.L == nil {
		destroy(s)
		return nil, "could not create a Lua state"
	}
	L := s.L
	lua.L_openlibs(L)
	lua.pushlightuserdata(L, s)
	lua.setfield(L, lua.REGISTRYINDEX, STATE_KEY)
	// LuaJIT opens bit and jit as globals but only preloads ffi; scripts get all three as globals.
	libraries := [?]cstring{"bit", "jit", "ffi"}
	for library in libraries {
		lua.getglobal(L, "require")
		lua.pushstring(L, library)
		if lua.pcall(L, 1, 1, 0) != 0 {return create_failed(s)}
		lua.setglobal(L, library)
	}
	lua.newtable(L)
	install_native(L, "command", native_command)
	install_native(L, "interest", native_interest)
	install_native(L, "log", native_log)
	install_native(L, "arm", native_arm)
	install_native(L, "disarm", native_disarm)
	install_native(L, "start", native_start)
	install_native(L, "process", native_process)
	install_native(L, "clock", native_clock)
	install_native(L, "pause", native_pause)
	install_native(L, "ref", native_ref)
	if !load_module(L, #load("json.lua", string), "@aio/json.lua", 0) {return create_failed(s)}
	lua.newtable(L)
	lua.pushboolean(L, config.kind == .Script)
	lua.setfield(L, -2, "script")
	push_text(L, config.root)
	lua.setfield(L, -2, "root")
	push_text(L, config.args)
	lua.setfield(L, -2, "args")
	lua.pushinteger(L, lua.Integer(config.pane))
	lua.setfield(L, -2, "pane")
	lua.newtable(L)
	for name in events.NAMES {
		push_text(L, name)
		lua.pushboolean(L, true)
		lua.settable(L, -3)
	}
	if !load_module(L, #load("runtime.lua", string), "@aio/runtime.lua", 4) {return create_failed(s)}
	s.runtime_ref = lua.L_ref(L, lua.REGISTRYINDEX)
	if !budget_start(s) {
		destroy(s)
		return nil, "could not start the Lua budget watchdog"
	}
	return s, ""
}

@(private)
clear_errors :: proc(s: ^State, list: ^[dynamic]Run_Error) {
	for err in list^ {
		delete(err.message, s.allocator)
		delete(err.file, s.allocator)
	}
	clear(list)
}

destroy :: proc(s: ^State) {
	if s == nil {return}
	budget_stop(s)
	for _, process in s.processes {spawn.destroy(process)}
	delete(s.processes)
	if s.L != nil {lua.close(s.L)}
	if s.backend.interest != nil {s.backend.interest(s.backend.data, {})}
	clear_errors(s, &s.errors)
	delete(s.errors)
	clear_errors(s, &s.pending_errors)
	delete(s.pending_errors)
	declarations_free(s)
	delete(s.result_message, s.allocator)
	delete(s.result_file, s.allocator)
	delete(s.result_value, s.allocator)
	free(s, s.allocator)
}

// Lua formats errors as `<chunk>:<line>: <message>`. The first such prefix is the raising
// position; a drive colon never matches because a backslash, not a digit, follows it.
@(private, require_results)
error_location :: proc(message: string) -> (file: string, line: int) {
	for i in 0 ..< len(message) {
		if message[i] != ':' {continue}
		end := i + 1
		for end < len(message) && message[end] >= '0' && message[end] <= '9' {end += 1}
		if end == i + 1 || end == len(message) || message[end] != ':' {continue}
		parsed, ok := strconv.parse_int(message[i + 1:end], 10)
		if !ok {continue}
		return message[:i], parsed
	}
	return "", 0
}

@(private, require_results)
remember_result :: proc(s: ^State, value, message: string) -> Call_Result {
	delete(s.result_value, s.allocator)
	delete(s.result_message, s.allocator)
	delete(s.result_file, s.allocator)
	s.result_value = strings.clone(value, s.allocator)
	s.result_message = strings.clone(message, s.allocator)
	file, line := error_location(message)
	s.result_file = strings.clone(file, s.allocator)
	return {value = s.result_value, message = s.result_message, file = s.result_file, line = line}
}

@(private)
get_runtime :: proc(s: ^State, name: cstring) {
	lua.rawgeti(s.L, lua.REGISTRYINDEX, s.runtime_ref)
	lua.getfield(s.L, -1, name)
	lua.remove(s.L, -2)
}

// runtime.run and runtime.call return ok, finished, returned_false, value JSON and message.
@(private, require_results)
finish_call :: proc(s: ^State, nargs: c.int) -> Call_Result {
	L := s.L
	if lua.pcall(L, nargs, 5, 0) != 0 {
		result := remember_result(s, "", text_at(L, -1))
		lua.pop(L, 1)
		result.finished = true
		return result
	}
	return read_call_result(s)
}

// Pops the five results runtime.run, runtime.call and runtime.top leave on the stack.
@(private, require_results)
read_call_result :: proc(s: ^State) -> Call_Result {
	L := s.L
	result := remember_result(s, text_at(L, -2), text_at(L, -1))
	result.ok = bool(lua.toboolean(L, -5))
	result.finished = bool(lua.toboolean(L, -4))
	result.returned_false = bool(lua.toboolean(L, -3))
	lua.pop(L, 5)
	return result
}

@(private, require_results)
run_result :: proc(result: Call_Result) -> Run_Result {
	return {
		ok = result.ok, finished = result.finished, message = result.message, file = result.file,
		line = result.line, value = result.value,
	}
}

@(private, require_results)
load_failed :: proc(s: ^State) -> Run_Result {
	result := remember_result(s, "", text_at(s.L, -1))
	lua.pop(s.L, 1)
	return {finished = true, message = result.message, file = result.file, line = result.line}
}

// name is the chunk's path; errors read `name:line: message`.
@(require_results)
run_source :: proc(s: ^State, name, source: string) -> Run_Result {
	chunk_name := strings.clone_to_cstring(fmt.tprintf("@%s", name), context.temp_allocator)
	if lua.L_loadbuffer(s.L, raw_data(source), c.size_t(len(source)), chunk_name) != .OK {return load_failed(s)}
	return run_loaded(s)
}

// Reads through Odin rather than luaL_loadfile, whose fopen cannot open UTF-8 paths on Windows.
@(require_results)
run_file :: proc(s: ^State, path: string) -> Run_Result {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		result := remember_result(s, "", fmt.tprintf("cannot open %s: %s", path, os.error_string(err)))
		return {finished = true, message = result.message, file = path}
	}
	return run_source(s, path, string(data))
}

@(private, require_results)
run_loaded :: proc(s: ^State) -> Run_Result {
	get_runtime(s, "run")
	lua.insert(s.L, -2)
	lua.pushnil(s.L)
	lua.pushnil(s.L)
	lua.pushboolean(s.L, s.config.kind == .Config)
	lua.pushboolean(s.L, false)
	return run_result(finish_call(s, 5))
}

// A Script host's top level that suspended (finished false from run_file or run_source) ends
// later, during step or deliver. done is true exactly once, when it has finished: result holds its
// value JSON or its `file:line: message` error, never reported through take_errors. Its strings
// live like run_source's.
@(require_results)
top_result :: proc(s: ^State) -> (result: Run_Result, done: bool) {
	L := s.L
	get_runtime(s, "top")
	if lua.pcall(L, 0, 6, 0) != 0 {
		record_runtime_error(s)
		return
	}
	done = bool(lua.toboolean(L, -6))
	lua.remove(L, -6)
	if !done {
		lua.pop(L, 5)
		return
	}
	return run_result(read_call_result(s)), true
}

// ref is a registry reference (lua.L_ref on REGISTRYINDEX) to a function called as fn(ctx, args).
// ctx is a JSON object whose pane defaults to Config.pane; args is JSON or "" for none.
@(require_results)
call :: proc(s: ^State, ref: i32, ctx: string, args: string) -> Call_Result {
	get_runtime(s, "call")
	lua.rawgeti(s.L, lua.REGISTRYINDEX, ref)
	push_text(s.L, ctx)
	push_text(s.L, args)
	return finish_call(s, 3)
}

ref_release :: proc(s: ^State, ref: i32) {lua.L_unref(s.L, lua.REGISTRYINDEX, ref)}

@(require_results)
lua_state :: proc(s: ^State) -> ^lua.State {return s.L}

// Processes started afterwards signal wake when output arrives or they exit.
set_wake :: proc(s: ^State, wake: host.Waker) {s.wake = wake}

@(private, require_results)
owned_error :: proc(s: ^State, message: string) -> Run_Error {
	file, line := error_location(message)
	return {strings.clone(message, s.allocator), strings.clone(file, s.allocator), line}
}

@(private)
record_runtime_error :: proc(s: ^State) {
	append(&s.pending_errors, owned_error(s, text_at(s.L, -1)))
	lua.pop(s.L, 1)
}

// Resumes waits that match and starts every handler as its own coroutine. Handler errors go to
// take_errors.
deliver :: proc(s: ^State, list: []events.Event) {
	names := events.NAMES
	for event in list {
		get_runtime(s, "deliver")
		push_text(s.L, names[event.kind])
		push_text(s.L, event.fields)
		if lua.pcall(s.L, 2, 0, 0) != 0 {record_runtime_error(s)}
	}
}

// now is the host clock in seconds. The first step anchors deadlines set before it, so the
// clock may start anywhere. has_next reports when the next timer, timeout or process poll is due.
@(require_results)
step :: proc(s: ^State, now: f64) -> (next: f64, has_next: bool) {
	get_runtime(s, "step")
	lua.pushnumber(s.L, lua.Number(now))
	if lua.pcall(s.L, 1, 1, 0) != 0 {
		record_runtime_error(s)
		return 0, false
	}
	has_next = lua.type(s.L, -1) == .NUMBER
	if has_next {next = f64(lua.tonumber(s.L, -1))}
	lua.pop(s.L, 1)
	return
}

// True until aio.stop while a coroutine is suspended, a timer is live, a process runs or an event
// handler is registered.
@(require_results)
busy :: proc(s: ^State) -> bool {
	get_runtime(s, "busy")
	if lua.pcall(s.L, 0, 1, 0) != 0 {
		record_runtime_error(s)
		return false
	}
	result := bool(lua.toboolean(s.L, -1))
	lua.pop(s.L, 1)
	return result
}

// Script host: ok once aio.stop ran or the timer limit was exceeded.
@(require_results)
stopped :: proc(s: ^State) -> (code: int, ok: bool) {
	get_runtime(s, "stopped")
	if lua.pcall(s.L, 0, 1, 0) != 0 {
		record_runtime_error(s)
		return 1, true
	}
	ok = lua.type(s.L, -1) == .NUMBER
	if ok {code = int(lua.tointeger(s.L, -1))}
	lua.pop(s.L, 1)
	return
}

// Errors from handlers, timers and process callbacks since the last call. The storage belongs
// to State and stays valid until the next take_errors.
@(require_results)
take_errors :: proc(s: ^State) -> []Run_Error {
	clear_errors(s, &s.errors)
	// Natively recorded errors happened before anything still queued in Lua was reported.
	append(&s.errors, ..s.pending_errors[:])
	clear(&s.pending_errors)
	L := s.L
	get_runtime(s, "errors")
	if lua.pcall(L, 0, 1, 0) != 0 {
		record_runtime_error(s)
		append(&s.errors, ..s.pending_errors[:])
		clear(&s.pending_errors)
		return s.errors[:]
	}
	count := int(lua.objlen(L, -1))
	for i in 1 ..= count {
		lua.rawgeti(L, -1, c.int(i))
		append(&s.errors, owned_error(s, text_at(L, -1)))
		lua.pop(L, 1)
	}
	lua.pop(L, 1)
	return s.errors[:]
}
