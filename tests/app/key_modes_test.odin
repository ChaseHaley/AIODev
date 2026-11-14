package app_test

import "base:runtime"
import app "../../src"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
mode_test_bind :: proc(t: ^testing.T, state: ^app.App, text, name: string, fields := "") {
	sequence, ok := commands.parse_sequence(text)
	if !testing.expect(t, ok) {return}
	command := commands.find(&state.registry, name)
	if !testing.expect(t, command != nil) {return}
	testing.expect_value(t, commands.keymap_bind(&state.keymap, {
		sequence, commands.Command_Target{command.id, fields}, "init.lua:12",
	}), commands.Error.None)
}

@(private = "file")
mode_test_event :: proc(state: ^app.App, w: ^app.Window, key: input.Key,
                       modifiers: input.Modifiers = {}, pressed := true, repeat := false) {
	app.handle_event(state, input.Key_Event{window = w.id, key = key, modifiers = modifiers,
		pressed = pressed, repeat = repeat})
}

@(private = "file")
mode_test_command :: proc(state: ^app.App, w: ^app.Window, words: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, words, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Window_Context{window = w, origin = .Key}, invocation)
}

// The executable lives inside a newly-created directory but is never created. Native process
// creation therefore fails before starting any process; the real pane and layout paths still run.
@(test)
key_modes_window_sequences_fields_modes_and_timeout_without_processes :: proc(t: ^testing.T) {
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
	directory, directory_error := os.make_directory_temp("", "aio-key-modes-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path := fmt.tprintf("%s/settings.ini", directory)
	settings := fmt.tprintf(
		"shell.command = \"%s/keymap-no-such-shell.exe\"\ninterface.font_size = 12\n" +
		"cursor.blink = false\ninput.leader = Ctrl+B\n",
		directory,
	)
	if !testing.expect_value(t, os.write_entire_file(path, settings), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.KeyModes.%d", os.get_pid())
	defer app.app_destroy(&state)
	primary := platform.init(&state.platform, state.app_id)
	if !testing.expect_value(t, primary, platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	app.tick(&state)
	state.animations = false
	w := state.windows[0]
	map_count := len(state.sessions)
	mode_test_bind(t, &state, "Ctrl+B>C", "pane.split", `{"direction":"down"}`)
	mode_test_event(&state, w, .B, {.Control})
	testing.expect_value(t, w.bindings.count, 1)
	testing.expect(t, !app.leader_armed(w), "keymap prefixes run before the leader")
	mode_test_event(&state, w, .B, {.Control}, repeat = true)
	testing.expect_value(t, w.bindings.count, 1)
	mode_test_event(&state, w, .B, {.Control}, pressed = false)
	testing.expect_value(t, w.bindings.count, 1)
	mode_test_event(&state, w, .C)
	if !testing.expect_value(t, len(state.sessions), map_count + 1) {return}
	tree := app.window_tree(w)
	split, is_split := tree.nodes[tree.root].(layout.Split)
	if testing.expect(t, is_split) {testing.expect_value(t, split.axis, layout.Axis.Vertical)}
	testing.expect_value(t, w.bindings.count, 0)
	mode_test_event(&state, w, .C, repeat = true)
	mode_test_event(&state, w, .C, pressed = false)
	testing.expect_value(t, len(state.sessions), map_count + 1)
	for entry in state.sessions {testing.expect_value(t, term.process_id(entry.session), u32(0))}

	testing.expect_value(t, commands.mode_declare(&state.keymap, {"resize", true}), commands.Error.None)
	mode_test_bind(t, &state, "resize/Left", "pane.zoom")
	entered := mode_test_command(&state, w, "mode.enter", "--name", "resize")
	testing.expect_value(t, entered.status, app.Outcome{}.status)
	testing.expect_value(t, len(w.bindings.modes), 1)
	mode_test_event(&state, w, .Arrow_Left)
	testing.expect(t, tree.zoomed)
	mode_test_event(&state, w, .Arrow_Left, repeat = true)
	mode_test_event(&state, w, .Arrow_Left, pressed = false)
	testing.expect(t, tree.zoomed, "repeat and release do not rerun a binding")
	mode_test_event(&state, w, .Escape)
	testing.expect_value(t, len(w.bindings.modes), 0)
	mode_test_event(&state, w, .Escape, pressed = false)
	testing.expect(t, !app.key_suppressed(w, .Escape))
	entered = mode_test_command(&state, w, "mode.enter", "--name", "resize", "--once")
	testing.expect_value(t, entered.status, app.Outcome{}.status)
	mode_test_event(&state, w, .Arrow_Left)
	testing.expect_value(t, len(w.bindings.modes), 0)
	testing.expect(t, !tree.zoomed)
	mode_test_event(&state, w, .Arrow_Left, pressed = false)
	testing.expect(t, mode_test_command(&state, w, "mode.enter", "--name", "missing").status != .Ok)
	testing.expect_value(t, len(w.bindings.modes), 0)
	testing.expect(t, len(state.notices.items) > 0)

	// A hidden command that acts on a pane runs from a key on the focused pane, here the lower half of
	// the split above, with its fields; the control pipe was its only way in before.
	mode_test_bind(t, &state, "resize/Up", "pane.resize", `{"direction":"up","cells":2}`)
	before := tree.nodes[tree.root].(layout.Split).ratio
	entered = mode_test_command(&state, w, "mode.enter", "--name", "resize")
	testing.expect_value(t, entered.status, app.Outcome{}.status)
	mode_test_event(&state, w, .Arrow_Up)
	mode_test_event(&state, w, .Arrow_Up, pressed = false)
	after := tree.nodes[tree.root].(layout.Split).ratio
	testing.expectf(t, after < before, "resize/Up moves the border up: ratio %v -> %v", before, after)
	_ = mode_test_command(&state, w, "mode.exit_all")

	mode_test_event(&state, w, .B, {.Control})
	deadline, pending := app.key_sequence_deadline(w)
	testing.expect(t, pending)
	when platform.AIO_HEADLESS {
		state.clock.stepped = true
		state.clock.now = time.tick_add(deadline, time.Millisecond)
		app.tick(&state)
	} else {
		app.key_sequence_expire(w, time.tick_add(deadline, time.Millisecond))
	}
	testing.expect_value(t, w.bindings.count, 0)
	_, pending = app.key_sequence_deadline(w)
	testing.expect(t, !pending)
	mode_test_event(&state, w, .B, {.Control}, pressed = false)
	mode_test_event(&state, w, .C)
	testing.expectf(t, len(state.sessions) == map_count + 1,
		"an expired sequence cannot run its tail: %d sessions", len(state.sessions))
	mode_test_event(&state, w, .C, pressed = false)

	_ = mode_test_command(&state, w, "mode.enter", "--name", "resize")
	_ = mode_test_command(&state, w, "mode.enter", "--name", "resize")
	_ = mode_test_command(&state, w, "mode.exit")
	testing.expect_value(t, len(w.bindings.modes), 1)
	_ = mode_test_command(&state, w, "mode.exit_all")
	testing.expect_value(t, len(w.bindings.modes), 0)
}
