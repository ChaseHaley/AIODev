package app_test

import "base:runtime"
import app "../../src"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Lua problems are logged as errors, which the runner would count as failures. They are kept here
// for the test to read instead; every other log line still reaches the runner.
@(private = "file")
lua_host_log: struct {
	runner: runtime.Logger,
	errors: [dynamic]string,
}

@(private = "file")
lua_host_logger :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	expected := strings.has_suffix(location.file_path, "lua_host.odin") ||
		location.procedure == "spawn_failure" || location.procedure == "show_settings_diagnostics"
	if expected {
		if level >= .Error {append(&lua_host_log.errors, strings.clone(text, runtime.heap_allocator()))}
		return
	}
	lua_host_log.runner.procedure(lua_host_log.runner.data, level, text, options, location)
}

@(private = "file")
lua_host_logged :: proc(fragment: string) -> bool {
	for line in lua_host_log.errors {
		if strings.contains(line, fragment) {return true}
	}
	return false
}

@(private = "file")
lua_host_run :: proc(state: ^app.App, name: string, fields := "{}") -> string {
	request := app.Control_Request{origin = .Cli}
	return app.command_run_fields(state, request, name, fields, "").text
}

@(private = "file")
LUA_HOST_INIT :: `local refusal
local renamed = {}
local fired = false
aio.on('tab.renamed', function() error('handler boom') end)
aio.on('tab.renamed', function(ctx, ev) renamed[#renamed + 1] = ev.name end)
local _, message = aio.settings.set('font.size', 20)
refusal = message
aio.action{name = 'greet', title = 'Greet', args = {who = 'string', times = 'integer?'},
	run = function(ctx, args) return {hello = args.who, times = args.times, origin = ctx.origin} end}
aio.action{name = 'rename_tab', title = 'Rename tab', args = {name = 'string'},
	run = function(ctx, args)
		local reply, err = aio.tab.rename({text = args.name})
		return reply ~= nil or err
	end}
aio.action{name = 'renamed', title = 'Renamed', run = function() return renamed end}
aio.action{name = 'arm', title = 'Arm', args = {seconds = 'number'},
	run = function(ctx, args) aio.after(args.seconds, function() fired = true end) end}
aio.action{name = 'fired', title = 'Fired', run = function() return fired end}
aio.action{name = 'spin', title = 'Spin', run = function() while true do end end}
aio.action{name = 'refusal', title = 'Refusal', run = function() return refusal end}
aio.action{name = 'set_font', title = 'Set font',
	run = function() local reply, err = aio.settings.set('font.size', 17); return reply ~= nil or err end}
`

// The executable lives inside a newly-created directory but is never created, so no process starts.
@(test)
lua_host_actions_events_timers_budget_and_reload_without_processes :: proc(t: ^testing.T) {
	lua_host_log.runner = context.logger
	defer {
		for line in lua_host_log.errors {delete(line, runtime.heap_allocator())}
		delete(lua_host_log.errors)
		lua_host_log.errors = nil
	}
	lua_host_log.errors = make([dynamic]string, runtime.heap_allocator())
	context.logger = {
		procedure = lua_host_logger,
		lowest_level = lua_host_log.runner.lowest_level,
		options = lua_host_log.runner.options,
	}
	directory, directory_error := os.make_directory_temp("", "aio-lua-host-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_text := fmt.tprintf(
		"shell.command = \"%s/lua-no-such-shell.exe\"\nfont.size = 12\ncursor.blink = false\n",
		directory,
	)
	settings_path := fmt.tprintf("%s/settings.ini", directory)
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings_text), nil) {return}
	// app.tick frees temporary memory, so paths used across ticks are allocated.
	init_path := fmt.aprintf("%s/init.lua", directory)
	defer delete(init_path)
	if !testing.expect_value(t, os.write_entire_file(init_path, LUA_HOST_INIT), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.LuaHost.%d", os.get_pid())
	defer app.app_destroy(&state)
	primary := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, primary, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	app.tick(&state)

	greet := commands.find(&state.registry, "greet")
	if !testing.expect(t, greet != nil, "init.lua's action is a command") {return}
	testing.expect(t, greet.runtime)
	testing.expect_value(t, greet.category, "Actions")
	testing.expect(t, strings.has_prefix(greet.source, "init.lua:"), greet.source)
	reply := lua_host_run(&state, "greet", `{"who":"world","times":2}`)
	testing.expect(t, strings.contains(reply, `"result":{`), reply)
	testing.expect(t, strings.contains(reply, `"hello":"world"`), reply)
	testing.expect(t, strings.contains(reply, `"origin":"cli"`), reply)
	testing.expect(t, strings.contains(reply, `"times":2`), reply)
	catalogue := lua_host_run(&state, "app.commands")
	testing.expect(t, strings.contains(catalogue, `"name":"greet"`), "app.commands lists the action")

	// Type words are checked before Lua runs.
	wrong := lua_host_run(&state, "greet", `{"who":5}`)
	testing.expect(t, strings.contains(wrong, `"ok":false`), wrong)
	testing.expect(t, strings.contains(wrong, "who must be string"), wrong)
	unknown := lua_host_run(&state, "greet", `{"who":"x","bogus":1}`)
	testing.expect(t, strings.contains(unknown, "no argument named bogus"), unknown)
	missing := lua_host_run(&state, "greet", `{}`)
	testing.expect(t, strings.contains(missing, "greet needs who"), missing)
	fraction := lua_host_run(&state, "greet", `{"who":"x","times":1.5}`)
	testing.expect(t, strings.contains(fraction, "times must be integer"), fraction)

	// Commands at load are refused; from an action they run.
	refusal := lua_host_run(&state, "refusal")
	testing.expect(t, strings.contains(refusal, "commands cannot run while init.lua loads"), refusal)
	testing.expect_value(t, state.settings.font.size, 12.0)
	set_font := lua_host_run(&state, "set_font")
	testing.expect(t, strings.contains(set_font, `"result":true`), set_font)
	testing.expect_value(t, state.settings.font.size, 17.0)

	// A command run from an action takes effect, and its event reaches every handler even though
	// the first one fails.
	renamed := lua_host_run(&state, "rename_tab", `{"name":"From Lua"}`)
	testing.expect(t, strings.contains(renamed, `"result":true`), renamed)
	w := state.windows[0]
	tab := w.workspace.tabs[w.workspace.selected]
	testing.expect_value(t, tab.name, "From Lua")
	app.tick(&state)
	handled := lua_host_run(&state, "renamed")
	testing.expect(t, strings.contains(handled, `"result":["From Lua"]`), handled)
	testing.expect(t, lua_host_logged("handler boom"), "a handler error is logged")

	// A timer fires when the app clock passes its deadline. A stepped clock lets the timer be long
	// enough that slow frames cannot reach it first.
	when platform.AIO_HEADLESS {
		testing.expect(t, strings.contains(lua_host_run(&state, "arm", `{"seconds":30}`), `"ok":true`))
	} else {
		testing.expect(t, strings.contains(lua_host_run(&state, "arm", `{"seconds":0.05}`), `"ok":true`))
	}
	app.tick(&state)
	when platform.AIO_HEADLESS {
		testing.expect(t, strings.contains(lua_host_run(&state, "fired"), `"result":false`))
		// Running an action asks for a step; once it ran, the deadline is the timer's.
		app.tick(&state)
		deadline, pending := app.lua_host_deadline(&state)
		testing.expect(t, pending, "an armed timer sets a deadline")
		state.clock.stepped = true
		state.clock.now = time.tick_add(deadline, 10 * time.Millisecond)
	} else {
		time.sleep(100 * time.Millisecond)
	}
	app.tick(&state)
	fired := lua_host_run(&state, "fired")
	testing.expect(t, strings.contains(fired, `"result":true`), fired)

	// The budget stops a runaway action and the app keeps working.
	spin := lua_host_run(&state, "spin")
	testing.expect(t, strings.contains(spin, `"ok":false`), spin)
	testing.expect(t, strings.contains(lua_host_run(&state, "greet", `{"who":"again"}`), `"hello":"again"`))

	// A syntax error on reload keeps the running actions and reports the line.
	broken := "aio.action{name = 'later', title = 'Later', run = function() end}\nlocal x = = 1\n"
	if !testing.expect_value(t, os.write_entire_file(init_path, broken), nil) {return}
	app.reload_settings(&state)
	testing.expect(t, commands.find(&state.registry, "greet") != nil, "the old actions stay")
	testing.expect(t, commands.find(&state.registry, "later") == nil, "a failed load registers nothing")
	reported := false
	for d in state.settings_diagnostics {
		if strings.contains(d.message, "init.lua:2:") {reported = true}
	}
	testing.expect(t, reported, "the load error is a settings diagnostic naming init.lua:2")
	testing.expect(t, strings.contains(lua_host_run(&state, "greet", `{"who":"kept"}`), `"hello":"kept"`))

	// settings.check_lua counts declarations and lists problems.
	checked := lua_host_run(&state, "settings.check_lua")
	testing.expect(t, strings.contains(checked, `"ok":false`), checked)
	testing.expect(t, strings.contains(checked, "actions 0"), checked)
	testing.expect(t, strings.contains(checked, "init.lua:2:"), checked)
	other := fmt.aprintf("%s/other.lua", directory)
	defer delete(other)
	other_text := "aio.action{name = 'one', title = 'One', run = function() end}\n" +
		"aio.mode('resize', {exclusive = true})\naio.bind('Ctrl+Nope', 'one')\naio.bind('Ctrl+B>C', 'one')\n"
	if !testing.expect_value(t, os.write_entire_file(other, other_text), nil) {return}
	// Forward slashes keep the path valid JSON without escaping.
	parts := [?]string{`{"file":"`, other, `"}`}
	other_json := strings.concatenate(parts[:], context.temp_allocator)
	other_fields, _ := strings.replace_all(other_json, "\\", "/", context.temp_allocator)
	checked = lua_host_run(&state, "settings.check_lua", other_fields)
	testing.expect(t, strings.contains(checked, `"ok":false`), checked)
	testing.expect(t, strings.contains(checked, `actions 1\nkeys 2\nmodes 1`), checked)
	invalid_key := `other.lua:3: key \"Ctrl+Nope\" is not a valid key sequence`
	testing.expect(t, strings.contains(checked, invalid_key), checked)
	testing.expect(t, commands.find(&state.registry, "one") == nil, "a check registers nothing")
	clean := "aio.action{name = 'one', title = 'One', run = function() end}\n"
	if !testing.expect_value(t, os.write_entire_file(other, clean), nil) {return}
	checked = lua_host_run(&state, "settings.check_lua", other_fields)
	testing.expect(t, strings.contains(checked, `"ok":true`), checked)

	// Once init.lua is fixed, a reload replaces the actions.
	if !testing.expect_value(t, os.write_entire_file(init_path, clean), nil) {return}
	app.reload_settings(&state)
	testing.expect(t, commands.find(&state.registry, "one") != nil)
	testing.expect(t, commands.find(&state.registry, "greet") == nil)
	// Without init.lua there is no state at all.
	testing.expect_value(t, os.remove(init_path), nil)
	app.reload_settings(&state)
	testing.expect(t, commands.find(&state.registry, "one") == nil)
	_, timer_pending := app.lua_host_deadline(&state)
	testing.expect(t, !timer_pending)
}

@(private = "file")
LUA_HOST_KEYS_INIT :: `local log = {}
aio.bind('Ctrl+Alt+R', function(ctx) aio.tab.rename({text = 'Keyed ' .. ctx.key}) end)
aio.bind('Ctrl+Alt+P', function() log[#log + 1] = 'pass'; return false end)
aio.bind('Ctrl+Alt+E', function() error('key boom') end)
aio.bind('Ctrl+Alt+S', 'pane.split', {direction = 'down'})
aio.mode('resize', {exclusive = true})
aio.bind('Ctrl+Alt+M', 'mode.enter', {name = 'resize'})
aio.bind('resize/Left', 'pane.zoom')
aio.bind('Ctrl+Alt+Z', 'pane.split', {direction = 'right'})
aio.action{name = 'key_log', title = 'Key log', run = function() return log end}
`

@(private = "file")
lua_host_press :: proc(state: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}) {
	pressed := input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = true}
	app.handle_event(state, pressed)
}

@(private = "file")
lua_host_release :: proc(state: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {}) {
	released := input.Key_Event{window = w.id, key = key, modifiers = modifiers}
	app.handle_event(state, released)
}

// Keys init.lua binds: functions, `return false`, errors, named commands with fields, modes and a
// conflict with a shortcut set in settings.ini. The shell is never created, so no process starts.
@(test)
lua_host_keys_run_functions_commands_and_modes_without_processes :: proc(t: ^testing.T) {
	lua_host_log.runner = context.logger
	defer {
		for line in lua_host_log.errors {delete(line, runtime.heap_allocator())}
		delete(lua_host_log.errors)
		lua_host_log.errors = nil
	}
	lua_host_log.errors = make([dynamic]string, runtime.heap_allocator())
	context.logger = {
		procedure = lua_host_logger,
		lowest_level = lua_host_log.runner.lowest_level,
		options = lua_host_log.runner.options,
	}
	directory, directory_error := os.make_directory_temp("", "aio-lua-host-keys-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	settings_text := fmt.tprintf(
		"shell.command = \"%s/lua-no-such-shell.exe\"\ncursor.blink = false\nkeys.pane.zoom = Ctrl+Alt+Z\n",
		directory,
	)
	settings_path := fmt.tprintf("%s/settings.ini", directory)
	if !testing.expect_value(t, os.write_entire_file(settings_path, settings_text), nil) {return}
	init_path := fmt.tprintf("%s/init.lua", directory)
	if !testing.expect_value(t, os.write_entire_file(init_path, LUA_HOST_KEYS_INIT), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.LuaHostKeys.%d", os.get_pid())
	defer app.app_destroy(&state)
	primary := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, primary, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	app.tick(&state)
	state.animations = false
	w := state.windows[0]

	// The init.lua binding loses to the shortcut settings.ini sets, and the warning names its line.
	conflict := false
	for d in state.settings_diagnostics {
		if d.kind != .Shortcut_Warning || !strings.contains(d.message, "init.lua:9") {continue}
		conflict = true
		testing.expect_value(t, d.key, "init.lua")
		testing.expect_value(t, d.line, 9)
	}
	testing.expectf(t, conflict, "diagnostics: %v", state.settings_diagnostics[:])

	// A function that returns nothing runs and keeps the key from the pane.
	lua_host_press(&state, w, .R, {.Control, .Alt})
	testing.expect(t, app.key_suppressed(w, .R), "a handled key does not reach the pane")
	lua_host_release(&state, w, .R, {.Control, .Alt})
	tab := w.workspace.tabs[w.workspace.selected]
	testing.expect_value(t, tab.name, "Keyed Ctrl+Alt+R")

	// `return false` passes the key on exactly as an unbound key passes.
	lua_host_press(&state, w, .U, {.Control, .Alt})
	unbound := app.key_suppressed(w, .U)
	lua_host_release(&state, w, .U, {.Control, .Alt})
	testing.expect(t, !unbound, "an unbound key reaches the pane")
	lua_host_press(&state, w, .P, {.Control, .Alt})
	testing.expect_value(t, app.key_suppressed(w, .P), unbound)
	lua_host_release(&state, w, .P, {.Control, .Alt})
	logged := lua_host_run(&state, "key_log")
	testing.expect(t, strings.contains(logged, `"result":["pass"]`), logged)

	// An error is reported and the key still counts as handled.
	lua_host_press(&state, w, .E, {.Control, .Alt})
	testing.expect(t, app.key_suppressed(w, .E), "a failing function still takes its key")
	lua_host_release(&state, w, .E, {.Control, .Alt})
	testing.expect(t, lua_host_logged("key boom"), "the error is logged")

	// A name target runs its command with the bound fields.
	sessions := len(state.sessions)
	lua_host_press(&state, w, .S, {.Control, .Alt})
	lua_host_release(&state, w, .S, {.Control, .Alt})
	if !testing.expect_value(t, len(state.sessions), sessions + 1) {return}
	tree := app.window_tree(w)
	root, is_split := tree.nodes[tree.root].(layout.Split)
	if testing.expect(t, is_split) {testing.expect_value(t, root.axis, layout.Axis.Vertical)}

	// A mode init.lua declares is entered through a binding to mode.enter.
	lua_host_press(&state, w, .M, {.Control, .Alt})
	lua_host_release(&state, w, .M, {.Control, .Alt})
	testing.expect_value(t, len(w.bindings.modes), 1)
	lua_host_press(&state, w, .Arrow_Left)
	lua_host_release(&state, w, .Arrow_Left)
	testing.expect(t, tree.zoomed, "the mode's key runs its command")
	lua_host_press(&state, w, .Escape)
	lua_host_release(&state, w, .Escape)
	testing.expect_value(t, len(w.bindings.modes), 0)
}
