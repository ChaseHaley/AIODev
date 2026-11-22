package main

import "aio:commands"
import "aio:events"
import "cosmos:input"
import platform_api "aio:platform"
import "aio:scripting"
import "aio:settings"
import "aio:spawn"
import "aio:ui"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// The Config host (WORK-038): init.lua beside the settings file declares actions, keys and modes, and
// handles events and timers inside the app. Without the file there is no Lua state at all.

@(private)
LUA_INIT_FILE :: "init.lua"
// How long one Lua entry point may run before the watchdog stops it, so a runaway loop in init.lua
// cannot freeze the app.
@(private)
LUA_BUDGET_MS :: 50
@(private)
LUA_LOADING_REFUSAL :: "commands cannot run while init.lua loads"
@(private)
LUA_CHECKING_REFUSAL :: "commands do not run while settings.check_lua checks a file"

// One scripting state and what the host knows about it. It is allocated so the backend's data
// pointer stays valid while the host swaps states.
@(private)
Lua_Instance :: struct {
	app:      ^App,
	state:    ^scripting.State,
	decls:    scripting.Declarations,
	// The runtime command each action registered as, parallel to decls.actions; 0 for an action a
	// later one of the same name replaced, or one that could not register.
	ids:      [dynamic]commands.Command_Id,
	// The directory init.lua is in, which names the files problems point at.
	root:     string,
	// What the state last asked to hear, kept while it is not yet in force.
	interest: events.Kinds,
	// Only the state in force sets the app's event interest, so a new load cannot be undone by the
	// old state's destruction, nor a failed load clear what the running state wants.
	live:     bool,
	loading:  bool,
	// A throwaway state settings.check_lua loads; its backend refuses every command.
	checking: bool,
}

Lua_Host :: struct {
	current:   ^Lua_Instance,
	// A load that succeeded and waits for lua_host_keys to put it in force.
	pending:   ^Lua_Instance,
	// init.lua went away, so lua_host_keys clears the keymap and ends the running state.
	dropping:  bool,
	// Problems the last load found, as settings diagnostics. Every revision repeats them until the
	// next load, so a Settings save does not hide them.
	problems:  [dynamic]settings.Diagnostic,
	// A Lua entry point is running. Scripting serializes nothing itself, so a nested entry is refused.
	running:   bool,
	// A Lua entry point ran and may have armed a timer, so the next tick steps to learn the deadline.
	due:       bool,
	// Set from process threads when output arrives or a process exits.
	woken:     bool,
	next_step: time.Tick,
	has_next:  bool,
}

// What a Lua function receives as ctx.
@(private)
Lua_Call_Context :: struct {
	pane, tab, workspace: u32,
	window:               input.Window_Id,
	origin:               string,
	key:                  string `json:"key,omitempty"`,
}

@(private, require_results)
lua_host_path :: proc(app: ^App) -> string {
	if app.settings_path == "" {return ""}
	parts := [?]string{filepath.dir(app.settings_path), LUA_INIT_FILE}
	path, err := filepath.join(parts[:], context.temp_allocator)
	if err != nil {return ""}
	return path
}

// settings.lua_path: the absolute path of the init.lua this app loads, whether or not it exists.
@(private, require_results)
lua_path :: proc(app: ^App) -> Outcome {
	path := lua_host_path(app)
	if path == "" {return outcome_failure(.Failed, "AIODev has no settings folder")}
	if absolute, err := filepath.abs(path, context.temp_allocator); err == nil {path = absolute}
	return {payload = Outcome_Text(path)}
}

@(private, require_results)
lua_instance_create :: proc(app: ^App, path: string, checking: bool) -> (^Lua_Instance, string) {
	instance := new(Lua_Instance)
	instance.app, instance.checking = app, checking
	instance.ids = make([dynamic]commands.Command_Id)
	instance.root = strings.clone(filepath.dir(path))
	backend := scripting.Backend {
		data    = instance,
		command = lua_backend_command,
	}
	if !checking {
		backend.interest = lua_backend_interest
		backend.log = lua_backend_log
	}
	config := scripting.Config {
		kind      = .Config,
		root      = instance.root,
		budget_ms = LUA_BUDGET_MS,
	}
	state, message := scripting.create(config, backend)
	if state == nil {
		lua_instance_destroy(instance)
		return nil, message
	}
	instance.state = state
	if !checking {
		wake := spawn.Wake{app, lua_host_wake}
		scripting.set_wake(state, wake)
	}
	return instance, ""
}

@(private)
lua_instance_destroy :: proc(instance: ^Lua_Instance) {
	if instance == nil {return}
	instance.live = false
	scripting.destroy(instance.state)
	delete(instance.ids)
	delete(instance.root)
	free(instance)
}

// Runs the file's top level, during which commands are refused. The chunk is named by the file's base
// name: Lua shortens long chunk names in its messages, which would lose the file a problem names.
@(private, require_results)
lua_instance_load :: proc(instance: ^Lua_Instance, path: string) -> scripting.Run_Result {
	name := filepath.base(path)
	source, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil {
		message := fmt.tprintf("cannot open %s: %s", path, os.error_string(read_error))
		return {message = message, file = name}
	}
	instance.loading = true
	result := scripting.run_source(instance.state, name, string(source))
	instance.loading = false
	instance.decls = scripting.declarations(instance.state)
	return result
}

// Process threads call this; it only flags the host and wakes the loop.
@(private)
lua_host_wake :: proc "contextless" (data: rawptr) {
	app := (^App)(data)
	sync.atomic_store(&app.lua.woken, true)
	context = runtime.default_context()
	_ = platform_api.wake(&app.platform)
}

@(private, require_results)
lua_refusal :: proc(message: string) -> string {
	return control_cli_reply(outcome_failure(.Failed, message), true).text
}

@(private)
lua_backend_command :: proc(data: rawptr, pane: u32, name, fields, _: string) -> string {
	instance := (^Lua_Instance)(data)
	if instance.checking {return lua_refusal(LUA_CHECKING_REFUSAL)}
	if instance.loading {
		log.warnf("init.lua: %s refused: %s", name, LUA_LOADING_REFUSAL)
		return lua_refusal(LUA_LOADING_REFUSAL)
	}
	request := Control_Request{caller = pane, origin = .Config}
	return command_run_fields(instance.app, request, name, fields, "").text
}

@(private)
lua_backend_interest :: proc(data: rawptr, kinds: events.Kinds) {
	instance := (^Lua_Instance)(data)
	instance.interest = kinds
	if instance.live {events.set_interest(&instance.app.events, .Lua, kinds)}
}

@(private)
lua_backend_log :: proc(data: rawptr, level, message: string) {
	instance := (^Lua_Instance)(data)
	switch level {
	case "debug", "trace":
		log.debugf("init.lua: %s", message)
	case "warn", "warning":
		log.warnf("init.lua: %s", message)
		lua_notice(instance.app, .Warning, fmt.tprintf("init.lua: %s", message))
	case "error":
		log.errorf("init.lua: %s", message)
		lua_notice(instance.app, .Error, fmt.tprintf("init.lua: %s", message))
	case:
		log.infof("init.lua: %s", message)
	}
}

@(private)
lua_notice :: proc(app: ^App, kind: ui.Notice_Kind, text: string) {
	key := u32(Notice_Key.Lua)
	ui.notices_put(
		&app.notices, key, kind, text, ERROR_NOTICE_DURATION, app.animations, clock_now(&app.clock), stack = true,
	)
	mark_all_dirty(app)
}

// A file as problems name it: relative to init.lua's directory when it is inside it. Lua shortens
// long chunk names to "...<tail>", which can no longer be related, so those keep their base name.
@(private, require_results)
lua_file_name :: proc(root, file: string) -> string {
	if relative, err := filepath.rel(root, file, context.temp_allocator); err == .None {
		if !strings.has_prefix(relative, "..") {return relative}
	}
	if strings.has_prefix(file, "...") {return filepath.base(file)}
	return file
}

// `file:line: message`, the shape settings problems and `aio config check` share. Lua errors carry
// their own location prefix, which the file name given separately replaces.
@(private, require_results)
lua_problem_text :: proc(root, file: string, line: int, message: string) -> string {
	if file == "" {return message}
	text := message
	if line > 0 {
		location := fmt.tprintf(":%d: ", line)
		if at := strings.index(text, location); at >= 0 {text = text[at + len(location):]}
		return fmt.tprintf("%s:%d: %s", lua_file_name(root, file), line, text)
	}
	text = strings.trim_prefix(text, fmt.tprintf("%s: ", file))
	return fmt.tprintf("%s: %s", lua_file_name(root, file), text)
}

// Logs the errors handlers, timers and process callbacks raised since the last report, and names the
// first in one notice.
@(private)
lua_host_report :: proc(app: ^App, instance: ^Lua_Instance) {
	errors := scripting.take_errors(instance.state)
	if len(errors) == 0 {return}
	first := ""
	for err, i in errors {
		text := lua_problem_text(instance.root, err.file, err.line, err.message)
		log.errorf("init.lua: %s", text)
		if i == 0 {first = text}
	}
	if len(errors) > 1 {first = fmt.tprintf("%s (and %d more; see the log)", first, len(errors) - 1)}
	lua_notice(app, .Error, first)
}

@(private)
lua_problem_add :: proc(app: ^App, root, file: string, line: int, message: string) {
	text := lua_problem_text(root, file, line, message)
	log.errorf("init.lua: %s", text)
	name := file == "" ? LUA_INIT_FILE : lua_file_name(root, file)
	// The identity leaves the line out, so moving a problem's line does not make it new.
	identity := fmt.tprintf("%s: %s", name, strings.trim_prefix(text, fmt.tprintf("%s:%d: ", name, line)))
	if err := settings.diagnostic_append(&app.lua.problems, line, name, text, .Invalid_Value, identity);
	   err != nil {
		notify(app, .Error, text)
	}
}

// The first half of a load, before the settings shortcuts apply: runs init.lua in a new state and,
// when its top level succeeds, registers its actions so settings.ini can bind them. lua_host_keys
// finishes the load once the shortcuts are known.
@(private)
lua_host_load :: proc(app: ^App) {
	host := &app.lua
	if host.running {
		// The running state cannot be replaced under the Lua code that asked for the reload.
		log.warn("init.lua was not reloaded because Lua code asked for the reload; reload settings again")
		lua_notice(app, .Warning, "init.lua reloads only when no Lua code is running; reload settings again.")
		return
	}
	settings.diagnostics_destroy(&host.problems)
	host.problems = make([dynamic]settings.Diagnostic)
	lua_instance_destroy(host.pending)
	host.pending = nil
	path := lua_host_path(app)
	if path == "" || !os.is_file(path) {
		if host.current != nil {
			commands.unregister_runtime(&app.registry)
			host.dropping = true
		}
		return
	}
	root := filepath.dir(path)
	instance, create_error := lua_instance_create(app, path, false)
	if instance == nil {
		lua_problem_add(app, root, path, 0, create_error)
		lua_notice(app, .Error, fmt.tprintf("init.lua: %s", create_error))
		return
	}
	result := lua_instance_load(instance, path)
	if !result.ok {lua_problem_add(app, instance.root, result.file, result.line, result.message)}
	for err in scripting.take_errors(instance.state) {
		lua_problem_add(app, instance.root, err.file, err.line, err.message)
	}
	if !result.ok {
		// The running state, its actions and its keys stay in force.
		lua_notice(app, .Error, lua_problem_text(instance.root, result.file, result.line, result.message))
		lua_instance_destroy(instance)
		return
	}
	commands.unregister_runtime(&app.registry)
	lua_actions_register(app, instance)
	host.pending = instance
	host.dropping = false
}

@(private)
lua_actions_register :: proc(app: ^App, instance: ^Lua_Instance) {
	actions := instance.decls.actions
	resize(&instance.ids, len(actions))
	outer: for action, i in actions {
		instance.ids[i] = 0
		// A later declaration of the same name wins.
		for later in actions[i + 1:] {
			if later.name == action.name {continue outer}
		}
		category := action.category != "" ? action.category : "Actions"
		source := fmt.tprintf("%s:%d", lua_file_name(instance.root, action.file), action.line)
		command := commands.Command {
			name     = action.name,
			title    = action.title,
			category = category,
			keywords = action.keywords,
			source   = source,
			summary  = action.description,
		}
		id, err := commands.register_runtime(&app.registry, command, RUNTIME_COMMAND_FIRST)
		if err != .None {
			message := fmt.tprintf("action %s could not be registered: %v", action.name, err)
			lua_problem_add(app, instance.root, action.file, action.line, message)
			continue
		}
		instance.ids[i] = id
	}
}

// The second half of every settings revision, after the settings shortcuts apply: puts a new load in
// force, or applies the running state's keys again so conflicts follow the current shortcuts, and
// repeats the last load's problems.
@(private)
lua_host_keys :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic) {
	host := &app.lua
	if host.pending != nil {
		lua_keys_apply(app, host.pending.decls, diagnostics)
		lua_instance_destroy(host.current)
		host.current, host.pending = host.pending, nil
		host.current.live = true
		events.set_interest(&app.events, .Lua, host.current.interest)
		host.due = true
	} else if host.dropping {
		host.dropping = false
		none: scripting.Declarations
		lua_keys_apply(app, none, diagnostics)
		lua_instance_destroy(host.current)
		host.current = nil
		host.has_next, host.due = false, false
		nothing: events.Kinds
		events.set_interest(&app.events, .Lua, nothing)
	} else if host.current != nil {
		lua_keys_apply(app, host.current.decls, diagnostics)
	}
	for d in host.problems {
		if err := settings.diagnostic_append(diagnostics, d.line, d.key, d.message, d.kind, d.identity);
		   err != nil {
			log.errorf("recording an init.lua problem failed: %v", err)
		}
	}
}

lua_host_destroy :: proc(app: ^App) {
	host := &app.lua
	lua_instance_destroy(host.pending)
	lua_instance_destroy(host.current)
	host.pending, host.current = nil, nil
	settings.diagnostics_destroy(&host.problems)
}

// Enters Lua once at a time; false when another entry point is already running.
@(private, require_results)
lua_host_call :: proc(
	app: ^App,
	ref: i32,
	ctx, args: string,
) -> (
	result: scripting.Call_Result,
	entered: bool,
) {
	host := &app.lua
	instance := host.current
	if instance == nil || host.running {return {}, false}
	host.running = true
	result = scripting.call(instance.state, ref, ctx, args)
	host.running = false
	host.due = true
	if !result.ok {
		text := lua_problem_text(instance.root, result.file, result.line, result.message)
		log.errorf("init.lua: %s", text)
		lua_notice(app, .Error, text)
	}
	lua_host_report(app, instance)
	return result, true
}

@(private, require_results)
lua_context_json :: proc(app: ^App, ctx: Command_Context, key := "") -> string {
	words := COMMAND_ORIGIN_WORDS
	value: Lua_Call_Context
	value.key = key
	switch c in ctx {
	case Window_Context:
		value.origin = words[c.origin]
		w := c.window
		if w != nil {
			value.window = w.id
			if w.workspace != nil {
				value.workspace = w.workspace.id
				index := c.tab.? or_else w.workspace.selected
				if index >= 0 && index < len(w.workspace.tabs) {value.tab = w.workspace.tabs[index].id}
			}
			if entry := focused_session(app, w); entry != nil {value.pane = entry.id}
		}
	case Control_Request:
		value.origin = words[c.origin]
		value.pane = c.caller
		target, failure := pane_target_resolve(app, "", c.caller)
		if failure.status == .Ok && target.workspace != nil {
			workspace := target.workspace
			value.workspace = workspace.id
			if target.pane.session != nil {value.pane = target.pane.session.id}
			if target.pane.tab >= 0 && target.pane.tab < len(workspace.tabs) {
				value.tab = workspace.tabs[target.pane.tab].id
			}
			if w := window_for_workspace(app, workspace); w != nil {value.window = w.id}
		}
	}
	options: json.Marshal_Options
	data, err := json.marshal(value, options, context.temp_allocator)
	if err != nil {return "{}"}
	return string(data)
}

// Runs an init.lua action as its runtime command.
@(private)
lua_host_run :: proc(app: ^App, ctx: Command_Context, invocation: commands.Invocation) -> Outcome {
	instance := app.lua.current
	command := commands.find(&app.registry, invocation.id)
	name := command != nil ? command.name : "that command"
	index := -1
	if instance != nil {
		for id, i in instance.ids {
			if id == invocation.id {index = i}
		}
	}
	if index < 0 {return outcome_failure(.Failed, fmt.tprintf("no script defines %s", name))}
	action := instance.decls.actions[index]
	if failure := lua_args_check(action, invocation.fields); failure != "" {
		return outcome_failure(.Usage, failure)
	}
	result, entered := lua_host_call(app, action.ref, lua_context_json(app, ctx), invocation.fields)
	if !entered {
		return outcome_failure(
			.Failed,
			fmt.tprintf("%s cannot run while other init.lua code runs; call its function directly", name),
		)
	}
	if !result.ok {
		return outcome_failure(.Failed, lua_problem_text(instance.root, result.file, result.line, result.message))
	}
	if result.finished && result.value != "" {
		return {payload = Outcome_Json(strings.clone(result.value, context.temp_allocator))}
	}
	return {}
}

// A key bound to a Lua function. False passes the key on as if unbound, as `return false` asks; an
// error is reported and the key counts as handled.
lua_host_key :: proc(app: ^App, w: ^Window, ref: i32, key_text: string) -> bool {
	if app.lua.current == nil {return false}
	window_context := Window_Context{window = w, origin = .Key}
	ctx := lua_context_json(app, window_context, key_text)
	result, entered := lua_host_call(app, ref, ctx, "")
	if !entered || !result.ok {return true}
	return !result.returned_false
}

@(private, require_results)
lua_arg_matches :: proc(word: string, value: json.Value) -> bool {
	switch v in value {
	case json.Null:
		return word == "any"
	case json.Integer:
		return word == "integer" || word == "number" || word == "any"
	case json.Float:
		integral := v == f64(i64(v))
		return word == "number" || word == "any" || word == "integer" && integral
	case json.Boolean:
		return word == "boolean" || word == "any"
	case json.String:
		return word == "string" || word == "any"
	case json.Array:
		return word == "array" || word == "any"
	case json.Object:
		return word == "object" || word == "any"
	}
	return false
}

// Checks fields against an action's type words: an unknown key, a wrong type or a missing required
// argument names itself. A JSON Schema, for all arguments or for one, passes unchecked.
@(private, require_results)
lua_args_check :: proc(action: scripting.Action_Decl, fields: string) -> string {
	if action.args == "" {return ""}
	context.allocator = context.temp_allocator
	spec, spec_error := json.parse_string(action.args, .JSON, true, context.temp_allocator)
	declared, declared_object := spec.(json.Object)
	if spec_error != nil || !declared_object {return ""}
	if "type" in declared {return ""}
	given: json.Object
	if fields != "" {
		value, value_error := json.parse_string(fields, .JSON, true, context.temp_allocator)
		object, is_object := value.(json.Object)
		if value_error != nil || !is_object {return fmt.tprintf("%s: use one JSON object", action.name)}
		given = object
	}
	names := make([dynamic]string, 0, len(declared))
	for name in declared {append(&names, name)}
	slice.sort(names[:])
	takes := "no arguments"
	if len(names) > 0 {takes = strings.join(names[:], ", ")}
	for key, value in given {
		want, found := declared[key]
		if !found {
			return fmt.tprintf("%q: no argument named %s; %s takes %s", key, key, action.name, takes)
		}
		word, is_word := want.(json.String)
		if !is_word {continue}
		optional := strings.has_suffix(word, "?")
		word = strings.trim_suffix(word, "?")
		if _, is_null := value.(json.Null); is_null && optional {continue}
		if !lua_arg_matches(word, value) {return fmt.tprintf("%q: %s must be %s", key, key, word)}
	}
	for name in names {
		word, is_word := declared[name].(json.String)
		if !is_word || strings.has_suffix(word, "?") {continue}
		if name not_in given {return fmt.tprintf("%q: %s needs %s", name, action.name, name)}
	}
	return ""
}

// Events reach Lua only for the kinds it asked for; the pipe's kinds pass it by.
lua_host_deliver :: proc(app: ^App, list: []events.Event) {
	host := &app.lua
	instance := host.current
	if instance == nil || host.running || len(list) == 0 {return}
	wanted := app.events.interest[.Lua]
	if card(wanted) == 0 {return}
	delivered := false
	host.running = true
	for i in 0 ..< len(list) {
		if list[i].kind not_in wanted {continue}
		scripting.deliver(instance.state, list[i:i + 1])
		delivered = true
	}
	host.running = false
	if !delivered {return}
	host.due = true
	lua_host_report(app, instance)
}

@(private, require_results)
lua_clock_seconds :: proc(now: time.Tick) -> f64 {
	return time.duration_seconds(time.tick_diff(time.Tick{}, now))
}

// The App_Timer entry: steps the scheduler on the app clock when a timer is due, a Lua entry point
// may have armed one, or a process signalled.
lua_host_tick :: proc(app: ^App) {
	host := &app.lua
	instance := host.current
	if instance == nil || host.running {return}
	now := clock_now(&app.clock)
	woken := sync.atomic_exchange(&host.woken, false)
	if !host.due && !woken && !(host.has_next && time.tick_diff(host.next_step, now) >= 0) {return}
	host.due = false
	host.running = true
	next, has_next := scripting.step(instance.state, lua_clock_seconds(now))
	host.running = false
	host.has_next = has_next
	if has_next {host.next_step = time.tick_add(time.Tick{}, time.Duration(next * f64(time.Second)))}
	lua_host_report(app, instance)
}

@(require_results)
lua_host_deadline :: proc(app: ^App) -> (time.Tick, bool) {
	host := &app.lua
	if host.current == nil {return {}, false}
	if host.due || sync.atomic_load(&host.woken) {return clock_now(&app.clock), true}
	return host.next_step, host.has_next
}

// settings.check_lua: loads a file in a throwaway state whose backend refuses commands and reports
// what it declares and every problem.
@(private)
lua_check :: proc(app: ^App, file: string) -> Outcome {
	path := file
	if path == "" {path = lua_host_path(app)}
	if path == "" {return outcome_failure(.Failed, "no settings directory to find init.lua in")}
	if absolute, err := filepath.abs(path, context.temp_allocator); err == nil {path = absolute}
	instance, create_error := lua_instance_create(app, path, true)
	if instance == nil {return outcome_failure(.Failed, create_error)}
	defer lua_instance_destroy(instance)
	result := lua_instance_load(instance, path)
	b := strings.builder_make(context.temp_allocator)
	decls := instance.decls
	fmt.sbprintf(&b, "%s\nactions %d\nkeys %d\nmodes %d", path, len(decls.actions), len(decls.keys),
		len(decls.modes))
	problems := 0
	if !result.ok {
		fmt.sbprintf(&b, "\n%s", lua_problem_text(instance.root, result.file, result.line, result.message))
		problems += 1
	}
	for err in scripting.take_errors(instance.state) {
		fmt.sbprintf(&b, "\n%s", lua_problem_text(instance.root, err.file, err.line, err.message))
		problems += 1
	}
	for key in decls.keys {
		if _, valid := commands.parse_sequence(key.key); valid {continue}
		message := fmt.tprintf("key %q is not a valid key sequence", key.key)
		fmt.sbprintf(&b, "\n%s", lua_problem_text(instance.root, key.file, key.line, message))
		problems += 1
	}
	text := strings.to_string(b)
	if problems > 0 {return {status = .Failed, message = text, payload = Outcome_Text(text)}}
	return {payload = Outcome_Text(text)}
}
