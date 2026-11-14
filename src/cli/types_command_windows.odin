package cli

import "aio:cli_protocol"
import "aio:control"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

// The reply `aio --json types` prints.
@(private)
Types_Reply :: struct {
	ok:               bool,
	status:           u8,
	error:            string `json:"error,omitempty"`,
	path:             string `json:"path,omitempty"`,
	luarc:            string `json:"luarc,omitempty"`,
	actions_included: bool,
}

// Runs `aio types`: asks AIODev for the definitions, the user's actions included, or copies the
// packaged built-ins beside aio.exe when AIODev is unreachable, and writes them beside init.lua: the
// init.lua of --data-dir's instance, else the one the running AIODev loads, else the instance's.
@(private, require_results)
types_run :: proc(o: Options, pipe, caller: string) -> cli_protocol.Status {
	client, connected := connect_verified(pipe)
	defer if connected == .Ok {control.close(&client)}
	app_path := ""
	if connected == .Ok && o.lua_types.data_dir == "" {app_path = lua_path_ask(&client)}
	folder, problem := init_folder(o.instance, o.lua_types.data_dir, app_path, context.temp_allocator)
	if problem != "" {return types_fail(o, .Failed, problem)}
	if absolute, err := filepath.abs(folder, context.temp_allocator); err == nil {folder = absolute}
	command := [1]string{LUA_TYPES_COMMAND}
	request := cli_protocol.Request {
		caller  = caller,
		format  = .Text,
		command = command[:],
	}
	encoded := cli_protocol.request_encode(request, context.temp_allocator)
	response: control.Response
	status := connected
	if connected == .Ok {
		reply, reply_status := send_on(&client, encoded, true)
		response = reply
		status = reply_status
	}
	text := response.text
	included := true
	#partial switch status {
	case .Ok:
	case .Unreachable:
		builtins: string
		found := false
		if executable, err := os.get_executable_path(context.temp_allocator); err == nil {
			builtins, found = types_builtins(filepath.dir(executable), context.temp_allocator)
		}
		if !found {
			return types_fail(
				o,
				.Failed,
				"AIODev is not reachable and there are no built-in definitions " +
				"(types\\aio.lua beside aio.exe)",
			)
		}
		text = builtins
		included = false
	case:
		return types_fail(o, status, response.text)
	}
	written, write_problem := types_write(folder, text, o.lua_types.force, context.temp_allocator)
	if write_problem != "" {return types_fail(o, .Failed, write_problem)}
	if !included {
		fmt.eprintln(
			"aio: wrote the built-in definitions only; your init.lua actions are missing until AIODev " +
			"runs with \"Command line control\" on and aio types runs again.",
		)
	}
	if written.state == .Kept {
		hint := fmt.tprintf("kept %s; add %s to it, or use --force to replace it", written.luarc, LUARC_SETTINGS)
		if o.json {fmt.eprintfln("aio: %s", hint)} else {fmt.println(hint)}
	}
	if o.json {
		reply := Types_Reply {
			ok               = true,
			path             = written.path,
			luarc            = LUARC_STATE_WORDS[written.state],
			actions_included = included,
		}
		return types_print(reply)
	}
	fmt.printfln("wrote %s (%s)", written.path, included ? "with your actions" : "built-ins only")
	if written.state != .Kept {fmt.printfln("%s %s", LUARC_STATE_WORDS[written.state], written.luarc)}
	return .Ok
}

// Reports a failure, as a reply object under --json, and returns its status.
@(private, require_results)
types_fail :: proc(o: Options, status: cli_protocol.Status, problem: string) -> cli_protocol.Status {
	if !o.json {
		if problem != "" {fmt.eprintfln("aio: %s", problem)}
		return status
	}
	reply := Types_Reply {
		status = u8(status),
		error  = problem,
	}
	if types_print(reply) != .Ok {return .Failed}
	return status
}

@(private, require_results)
types_print :: proc(reply: Types_Reply) -> cli_protocol.Status {
	options: json.Marshal_Options
	text, err := json.marshal(reply, options, context.temp_allocator)
	if err != nil {
		fmt.eprintln("aio: not enough memory for the reply")
		return .Failed
	}
	fmt.println(string(text))
	return .Ok
}
