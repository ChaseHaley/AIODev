package scripting

import "core:c"
import "core:fmt"
import "aio:lua"
import "aio:spawn"

@(private)
push_failure :: proc "contextless" (L: ^lua.State, message: string) -> c.int {
	lua.pushnil(L)
	push_text(L, message)
	return 2
}

// True when opts (argument 2) holds key with exactly the boolean value.
@(private, require_results)
option_is :: proc "contextless" (L: ^lua.State, key: cstring, value: bool) -> bool {
	lua.getfield(L, 2, key)
	result := lua.type(L, -1) == .BOOLEAN && bool(lua.toboolean(L, -1)) == value
	lua.pop(L, 1)
	return result
}

// start(argv, opts) -> id, pid | nil, message. runtime.lua checked argv and the option types it
// owns; env entries are checked here because they become spawn's NAME=value edits.
@(private)
native_start :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	context = s.ctx
	argv := make([]string, int(lua.objlen(L, 1)), context.temp_allocator)
	for &arg, i in argv {
		lua.rawgeti(L, 1, c.int(i + 1))
		arg = text_at(L, -1)
		// The argv table still references the string, so the borrowed text outlives the pop.
		lua.pop(L, 1)
	}
	opts: spawn.Options
	lua.getfield(L, 2, "cwd")
	if lua.type(L, -1) == .STRING {
		opts.cwd = text_at(L, -1)
	} else if !lua.isnoneornil(L, -1) {
		return push_failure(L, "cwd must be a string")
	}
	lua.pop(L, 1)
	opts.clear_env = option_is(L, "clear_env", true)
	opts.keep_crlf = option_is(L, "text", false)
	opts.discard_stdout = option_is(L, "stdout", false)
	opts.discard_stderr = option_is(L, "stderr", false)
	lua.getfield(L, 2, "stdin")
	if lua.type(L, -1) == .STRING {
		opts.stdin = text_at(L, -1)
	} else if lua.type(L, -1) == .BOOLEAN {
		opts.keep_stdin = bool(lua.toboolean(L, -1))
	} else if !lua.isnoneornil(L, -1) {
		return push_failure(L, "stdin must be a string or true")
	}
	lua.pop(L, 1)
	env := make([dynamic]string, context.temp_allocator)
	lua.getfield(L, 2, "env")
	if lua.type(L, -1) == .TABLE {
		lua.pushnil(L)
		for lua.next(L, -2) != 0 {
			if lua.type(L, -2) != .STRING {return push_failure(L, "environment names must be strings")}
			value := ""
			#partial switch lua.type(L, -1) {
			case .STRING: value = text_at(L, -1)
			case .BOOLEAN:
				// false removes the variable; spawn reads NAME= as a removal.
				if bool(lua.toboolean(L, -1)) {return push_failure(L, "environment values must be strings or false")}
			case: return push_failure(L, "environment values must be strings or false")
			}
			append(&env, fmt.tprintf("%s=%s", text_at(L, -2), value))
			lua.pop(L, 1)
		}
	} else if !lua.isnoneornil(L, -1) {
		return push_failure(L, "env must be a table")
	}
	lua.pop(L, 1)
	opts.env = env[:]
	process, err := spawn.start(argv, opts, s.wake, s.allocator)
	switch err {
	case .None:
	case .Not_Found: return push_failure(L, fmt.tprintf("%s: program not found", argv[0]))
	case .Not_Executable:
		message := "%s: only .exe and .com programs run directly; run scripts through cmd.exe /d /c"
		return push_failure(L, fmt.tprintf(message, argv[0]))
	case .Start_Failed: return push_failure(L, fmt.tprintf("%s: could not start the process", argv[0]))
	case .Closed: return push_failure(L, fmt.tprintf("%s: the process closed while starting", argv[0]))
	case .Out_Of_Memory: return push_failure(L, "out of memory starting a process")
	}
	s.process_serial += 1
	s.processes[s.process_serial] = process
	lua.pushinteger(L, lua.Integer(s.process_serial))
	lua.pushinteger(L, lua.Integer(spawn.pid(process)))
	return 2
}

// process(operation, id[, data]). poll returns {stdout, stderr, exited, code} with the chunks
// since the last poll; destroy forgets the id.
@(private)
native_process :: proc "c" (L: ^lua.State) -> c.int {
	s := state_at(L)
	context = s.ctx
	id := int(lua.tointeger(L, 2))
	process, ok := s.processes[id]
	if !ok {return push_failure(L, "process is closed")}
	switch text_at(L, 1) {
	case "poll":
		output := spawn.poll(process)
		lua.createtable(L, 0, 4)
		push_text(L, string(output.stdout))
		lua.setfield(L, -2, "stdout")
		push_text(L, string(output.stderr))
		lua.setfield(L, -2, "stderr")
		lua.pushboolean(L, b32(output.exited))
		lua.setfield(L, -2, "exited")
		lua.pushinteger(L, lua.Integer(output.code))
		lua.setfield(L, -2, "code")
		return 1
	case "write":
		if spawn.write(process, transmute([]u8)text_at(L, 3)) != .None {
			return push_failure(L, "process input is closed")
		}
	case "close_stdin": spawn.close_stdin(process)
	case "kill": spawn.kill(process)
	case "closing":
		lua.pushboolean(L, b32(!spawn.running(process)))
		return 1
	case "destroy":
		spawn.destroy(process)
		delete_key(&s.processes, id)
	case:
		return push_failure(L, "unknown process operation")
	}
	lua.pushboolean(L, true)
	return 1
}
