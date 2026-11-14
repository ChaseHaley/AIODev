package app_test

import "base:runtime"
import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:events"
import "aio:platform"
import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"

// The committed built-in definitions, which build.ps1 types regenerates.
@(private = "file")
LUA_TYPES_COMMITTED :: #load("../../types/aio.lua", string)

@(test)
lua_types_built_in_text_matches_types_aio_lua_and_covers_the_catalogue :: proc(t: ^testing.T) {
	state: app.App
	state.registry = commands.create()
	defer commands.destroy(&state.registry)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	text := app.lua_types_text(&state, false, context.temp_allocator)
	testing.expect(
		t,
		text == LUA_TYPES_COMMITTED,
		"types/aio.lua differs from the generated definitions; run build.ps1 types and commit it",
	)
	testing.expect(t, strings.has_prefix(text, "---@meta\n"))
	testing.expect(t, !strings.contains(text, "--{{"), "every overload marker is replaced")

	// Every command has an aio.run overload, and a function unless META_CORE made its namespace a
	// function (aio.view), which runtime.lua's namespace lookup cannot index.
	for command in state.registry.items {
		overload := fmt.tprintf("---@overload fun(name: %q, fields", command.name)
		testing.expectf(t, strings.contains(text, overload), "%s has an aio.run overload", command.name)
		prefix, _, _ := strings.partition(command.name, ".")
		shadowed := strings.contains(text, fmt.tprintf("\nfunction aio.%s(", prefix))
		declared := strings.contains(text, fmt.tprintf("\nfunction aio.%s(", command.name))
		testing.expectf(t, shadowed || declared, "aio.%s is declared", command.name)
	}

	for name in events.NAMES {
		on := fmt.tprintf("---@overload fun(name: %q, fn: (fun(ctx: aio.Ctx, ev: aio.event.", name)
		testing.expectf(t, strings.contains(text, on), "aio.on has an overload for %s", name)
		wait := fmt.tprintf("---@overload fun(name: %q, filter?: table|(fun(ev: aio.event.", name)
		testing.expectf(t, strings.contains(text, wait), "aio.wait has an overload for %s", name)
	}

	// aio.run removes ok, status and error; every other reply field is in aio.Reply.
	_, _, after := strings.partition(text, "---@class aio.Reply\n")
	reply, _, _ := strings.partition(after, "\n\n")
	for field in reflect.struct_fields_zipped(cli_protocol.Reply_Json) {
		removed := field.name == "ok" || field.name == "status" || field.name == "error"
		line := fmt.tprintf("---@field %s?", field.name)
		testing.expectf(t, strings.contains(reply, line) != removed, "aio.Reply and the field %s", field.name)
	}

	// A required argument makes the fields table required; the pane field follows the target.
	split := "---@class aio.fields.pane.split\n---@field pane? string|integer "
	testing.expect(t, strings.contains(text, split), "pane.split takes a pane")
	keys := `---@overload fun(name: "pane.send_keys", fields: aio.fields.pane.send_keys)`
	testing.expect(t, strings.contains(text, keys), "pane.send_keys needs its keys")
	testing.expect(t, strings.contains(text, `---@field keys string|string[] `), "keys is required")
}

// Problems an init.lua load reports, and the missing shell, are logged as errors, which the runner
// would count as failures.
@(private = "file")
lua_types_log: runtime.Logger

@(private = "file")
lua_types_logger :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	expected := strings.has_suffix(location.file_path, "lua_host.odin") ||
		location.procedure == "spawn_failure" || location.procedure == "show_settings_diagnostics"
	if expected && level >= .Error {return}
	lua_types_log.procedure(lua_types_log.data, level, text, options, location)
}

@(private = "file")
LUA_TYPES_INIT :: `aio.action{name = 'greet', title = 'Greet', description = 'Says hello.',
	args = {who = 'string', times = 'integer?'}, run = function(ctx, args) return args.who end}
aio.action{name = 'ping', title = 'Ping', run = function() return true end}
aio.action{name = 'shaped', title = 'Shaped', args = {type = 'object'}, run = function() end}
`

@(test)
lua_types_app_command_adds_the_actions_init_lua_declared :: proc(t: ^testing.T) {
	lua_types_log = context.logger
	context.logger = {
		procedure    = lua_types_logger,
		lowest_level = lua_types_log.lowest_level,
		options      = lua_types_log.options,
	}
	directory, directory_error := os.make_directory_temp("", "aio-lua-types-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_text := fmt.tprintf(
		"shell.command = \"%s/lua-no-such-shell.exe\"\ncursor.blink = false\n",
		directory,
	)
	settings_path := fmt.tprintf("%s/settings.ini", directory)
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings_text), nil) {return}
	init_path := fmt.tprintf("%s/init.lua", directory)
	if !testing.expect_value(t, os.write_entire_file(init_path, LUA_TYPES_INIT), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.LuaTypes.%d", os.get_pid())
	defer app.app_destroy(&state)
	primary := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, primary, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	app.tick(&state)
	registered := commands.find(&state.registry, "greet") != nil
	if !testing.expect(t, registered, "init.lua's action is registered") {return}

	request := app.Control_Request{origin = .Cli}
	reply := app.command_run_fields(&state, request, "app.lua_types", "{}", "")
	testing.expect(t, reply.ok, reply.text)
	testing.expect(t, strings.contains(reply.text, "aio.args.greet"), "app.lua_types names the action's args")

	text := app.lua_types_text(&state, true, context.temp_allocator)
	header := fmt.tprintf(
		"---@meta\n-- The aio API for lua-language-server: AIODev build %s,",
		cli_protocol.BUILD_ID,
	)
	testing.expect(t, strings.has_prefix(text, header), "the header names the build")
	args :=
		"---Greet\n---\n---Says hello.\n---@class aio.args.greet\n---@field times? integer\n" +
		"---@field who string\n"
	testing.expect(t, strings.contains(text, args), "greet's args class has its type words")
	run_at := strings.index(text, "\nfunction aio.run(")
	invoke_at := strings.index(text, "\nfunction aio.invoke(")
	run := `---@overload fun(name: "greet", fields: aio.args.greet): aio.Reply?, string?, integer?`
	invoke := `---@overload fun(name: "greet", args: aio.args.greet): any, string?, integer?`
	run_overload := strings.index(text, run)
	invoke_overload := strings.index(text, invoke)
	testing.expect(t, run_overload >= 0 && run_overload < run_at, "aio.run has greet's overload")
	in_invoke := invoke_overload > run_at && invoke_overload < invoke_at
	testing.expect(t, in_invoke, "aio.invoke has greet's overload")
	ping := `---@overload fun(name: "ping", args?: table): any, string?, integer?`
	testing.expect(t, strings.contains(text, ping), "an action without args takes any table")
	shaped := `---@overload fun(name: "shaped", fields?: table): aio.Reply?, string?, integer?`
	testing.expect(t, strings.contains(text, shaped), "a JSON Schema's action takes a table")
	testing.expect(t, !strings.contains(text, "aio.args.shaped"), "a JSON Schema has no args class")
	built_in := app.lua_types_text(&state, false, context.temp_allocator)
	testing.expect(t, !strings.contains(built_in, "greet"), "the built-in text leaves the actions out")
}
