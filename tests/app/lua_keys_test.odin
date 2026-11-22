package app_test

import "base:runtime"
import app "../../src"
import "aio:commands"
import "cosmos:input"
import "aio:layout"
import "aio:platform"
import "aio:scripting"
import "aio:settings"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
lua_keys_event :: proc(state: ^app.App, w: ^app.Window, key: input.Key, modifiers: input.Modifiers = {},
                       pressed := true) {
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers, pressed = pressed})
}

// Lua functions run through lua_host_key, which the Config host owns and offers no test hook for, so this
// covers applying declarations, their diagnostics, and command and mode dispatch; function targets are
// checked as stored Script_Target bindings only. The shell executable is never created, so no process
// starts.
@(test)
lua_keys_apply_rebuilds_the_keymap_and_reports_each_bad_declaration_at_its_line :: proc(t: ^testing.T) {
	// Each pane's failed start logs an error, which the runner would count as a failure; every other
	// log line still reaches the runner.
	runner := context.logger
	context.logger = {
		procedure = proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options,
			location := #caller_location) {
			if location.procedure == "spawn_failure" {return}
			next := (^runtime.Logger)(data)
			next.procedure(next.data, level, text, options, location)
		},
		data = &runner,
		lowest_level = runner.lowest_level,
		options = runner.options,
	}
	directory, directory_error := os.make_directory_temp("", "aio-lua-keys-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := fmt.tprintf("%s/settings.ini", directory)
	settings_text := fmt.tprintf(
		"shell.command = \"%s/lua-keys-no-such-shell.exe\"\ninterface.font_size = 12\ncursor.blink = false\n",
		directory,
	)
	if !testing.expect_value(t, os.write_entire_file(path, settings_text), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.LuaKeys.%d", os.get_pid())
	defer app.app_destroy(&state)
	primary := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, primary, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	app.tick(&state)
	state.animations = false
	w := state.windows[0]
	sessions := len(state.sessions)

	// A shortcut set in Settings differs from the command's defaults.
	zoom := commands.find(&state.registry, "pane.zoom")
	if !testing.expect(t, zoom != nil) {return}
	chosen := [?]commands.Shortcut{{.F12, {.Control, .Alt}}}
	testing.expect_value(t, commands.set_shortcuts(&state.registry, zoom.id, chosen[:]), commands.Error.None)

	// A binding from an earlier load must not survive the rebuild.
	stale, _ := commands.parse_sequence("Ctrl+B>X")
	split := commands.find(&state.registry, "pane.split")
	if !testing.expect(t, split != nil) {return}
	stale_binding := commands.Binding{stale, commands.Command_Target{id = split.id}, "init.lua:99"}
	testing.expect_value(t, commands.keymap_bind(&state.keymap, stale_binding), commands.Error.None)

	modes := [?]scripting.Mode_Decl{{name = "resize", exclusive = true, file = "init.lua", line = 1}}
	keys := [?]scripting.Key_Decl {
		{op = .Bind, key = "Ctrl+B>C", command = "pane.split", fields = `{"direction":"down"}`,
			file = "init.lua", line = 2},
		{op = .Bind, key = "resize/Left", command = "pane.zoom", file = "init.lua", line = 3},
		{op = .Bind, key = "Ctrl+Q", command = "no.such_command", file = "init.lua", line = 4},
		{op = .Bind, key = "Ctrl+B>", command = "pane.zoom", file = "init.lua", line = 5},
		{op = .Bind, key = "Ctrl+Alt+F12", command = "pane.split", file = "init.lua", line = 6},
		{op = .Bind, key = "Ctrl+J", ref = 5, file = "init.lua", line = 7},
		{op = .Bind, key = "Ctrl+B>D", command = "pane.split", fields = `{"nope":1}`, file = "keys.lua",
			line = 8},
		{op = .Bind, key = "Ctrl+B>E", command = "pane.split", fields = `{"direction":"right"}`,
			file = "init.lua", line = 9},
		{op = .Unbind, key = "Ctrl+B>E", command = "pane.split", file = "init.lua", line = 10},
		{op = .Bind, key = "resize/Right", ref = 6, file = "init.lua", line = 11},
		{op = .Unbind, key = "resize/Right", ref = 6, file = "init.lua", line = 12},
	}
	decls := scripting.Declarations{keys = keys[:], modes = modes[:]}
	diagnostics := make([dynamic]settings.Diagnostic)
	defer settings.diagnostics_destroy(&diagnostics)
	app.lua_keys_apply(&state, decls, &diagnostics)

	if testing.expectf(t, len(diagnostics) == 4, "diagnostics: %v", diagnostics[:]) {
		unknown := diagnostics[0]
		testing.expect_value(t, unknown.line, 4)
		testing.expect_value(t, unknown.key, "init.lua")
		testing.expect(t, strings.contains(unknown.message, "no.such_command"))
		testing.expect(t, strings.contains(unknown.message, "Ctrl+Q"))
		sequence := diagnostics[1]
		testing.expect_value(t, sequence.line, 5)
		testing.expect(t, strings.contains(sequence.message, "Ctrl+B>"))
		fields := diagnostics[2]
		testing.expect_value(t, fields.line, 8)
		testing.expect_value(t, fields.key, "keys.lua")
		testing.expect(t, strings.contains(fields.message, "Ctrl+B>D"))
		testing.expect_value(t, fields.kind, settings.Diagnostic_Kind.Invalid_Value)
		warning := diagnostics[3]
		testing.expect_value(t, warning.kind, settings.Diagnostic_Kind.Shortcut_Warning)
		testing.expect_value(t, warning.line, 6)
		testing.expect_value(t, warning.key, "init.lua")
		testing.expect(t, strings.contains(warning.message, "init.lua:6"))
		testing.expect(t, strings.contains(warning.message, "settings"))
		testing.expect(t, !strings.contains(warning.identity, "init.lua:6"), "moving the line keeps the warning")
	}

	testing.expect_value(t, len(state.keymap.modes), 1)
	if len(state.keymap.modes) == 1 {
		testing.expect_value(t, state.keymap.modes[0], commands.Mode{"resize", true})
	}
	script_found := false
	for binding in state.keymap.bindings {
		testing.expect(t, !commands.sequence_equal(binding.sequence, stale), "the rebuild drops old bindings")
		target, is_script := binding.target.(commands.Script_Target)
		if !is_script {continue}
		testing.expect(t, !script_found, "the unbound function key is gone")
		script_found = true
		testing.expect_value(t, target.ref, 5)
		testing.expect_value(t, binding.source, "init.lua:7")
	}
	testing.expect(t, script_found)
	unbound, _ := commands.parse_sequence("Ctrl+B>E")
	for binding in state.keymap.bindings {
		testing.expect(t, !commands.sequence_equal(binding.sequence, unbound), "unbinding by name ignores fields")
	}

	lua_keys_event(&state, w, .B, {.Control})
	lua_keys_event(&state, w, .B, {.Control}, pressed = false)
	lua_keys_event(&state, w, .C)
	lua_keys_event(&state, w, .C, pressed = false)
	if !testing.expect_value(t, len(state.sessions), sessions + 1) {return}
	tree := app.window_tree(w)
	root, is_split := tree.nodes[tree.root].(layout.Split)
	if testing.expect(t, is_split) {testing.expect_value(t, root.axis, layout.Axis.Vertical)}

	words := [?]string{"mode.enter", "--name", "resize"}
	invocation, parse_error := commands.parse_invocation(&state.registry, words[:], context.temp_allocator)
	if !testing.expect_value(t, parse_error.advice, "") {return}
	entered := app.command_execute(&state, app.Window_Context{window = w, origin = .Key}, invocation)
	testing.expect_value(t, entered.status, app.Outcome{}.status)
	lua_keys_event(&state, w, .Arrow_Left)
	lua_keys_event(&state, w, .Arrow_Left, pressed = false)
	testing.expect(t, tree.zoomed, "a key in a declared mode runs its command")
	// The mode is exclusive: an unbound key stays with the keymap instead of reaching the pane.
	lua_keys_event(&state, w, .X)
	testing.expect(t, app.key_suppressed(w, .X))
	lua_keys_event(&state, w, .X, pressed = false)
	lua_keys_event(&state, w, .Escape)
	lua_keys_event(&state, w, .Escape, pressed = false)
	testing.expect_value(t, len(w.bindings.modes), 0)
}
