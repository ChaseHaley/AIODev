package commands_test

import "aio:commands"
import "core:testing"
import "cosmos:input"

@(private = "file")
map_binding :: proc(t: ^testing.T, keymap: ^commands.Keymap, text: string, id: commands.Command_Id,
                    fields := "") {
	sequence, ok := commands.parse_sequence(text)
	if !testing.expect(t, ok) {return}
	binding := commands.Binding{sequence, commands.Command_Target{id, fields}, "init.lua:12"}
	testing.expect_value(t, commands.keymap_bind(keymap, binding), commands.Error.None)
}

@(private = "file")
map_feed :: proc(keymap: ^commands.Keymap, state: ^commands.Key_State, registry: ^commands.Registry,
                 text: string) -> commands.Feed_Result {
	chord, ok := commands.parse_shortcut(text)
	assert(ok)
	return commands.feed(keymap, state, registry, chord.key, chord.modifiers, 0)
}

@(private = "file")
map_expect_run :: proc(t: ^testing.T, result: commands.Feed_Result, id: commands.Command_Id) {
	run, ok := result.(commands.Run)
	if testing.expect(t, ok) {testing.expect_value(t, run.binding.target.(commands.Command_Target).id, id)}
}

@(test)
keymap_sequences_parse_complete_chords_and_mode_names :: proc(t: ^testing.T) {
	valid := [?]string {
		"Ctrl+B>C", "resize/Left", "resize/Ctrl+B>C", "resize_2-fast/Physical+Ctrl+Z>Left>Right>Up", "/",
		"Ctrl+/", "Ctrl+B>/",
	}
	for text in valid {
		sequence, ok := commands.parse_sequence(text)
		testing.expectf(t, ok, "valid sequence %q", text)
		testing.expect(t, sequence.count >= 1 && sequence.count <= 4)
	}
	invalid := [?]string {
		"", "Ctrl+B>", ">C", "A>B>C>D>E", "Resize/Left", "bad name/Left", "bad.mode/Left", "resize/",
		"resize//Left", "Ctrl+Ctrl+C", "not-a-key",
	}
	for text in invalid {
		_, ok := commands.parse_sequence(text)
		testing.expectf(t, !ok, "invalid sequence %q", text)
	}
	sequence, ok := commands.parse_sequence("resize/Ctrl+B>C")
	testing.expect(t, ok)
	testing.expect_value(t, sequence.mode, "resize")
	testing.expect_value(t, sequence.count, 2)
	testing.expect_value(t, sequence.chords[0], input.Shortcut{.B, {.Control}})
	testing.expect_value(t, sequence.chords[1], input.Shortcut{.C, {}})
}

@(test)
keymap_sequences_consume_prefixes_and_failed_continuations :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	map_binding(t, &keymap, "Ctrl+B>C", 1, `{"direction":"down"}`)
	map_binding(t, &keymap, "Ctrl+B>D", 2)
	first := map_feed(&keymap, &state, &registry, "Ctrl+B")
	_, pending := first.(commands.Pending)
	testing.expect(t, pending && state.count == 1)
	result := map_feed(&keymap, &state, &registry, "C")
	map_expect_run(t, result, 1)
	if run, ok := result.(commands.Run); ok {
		testing.expect_value(t, run.binding.target.(commands.Command_Target).fields, `{"direction":"down"}`)
		testing.expect_value(t, run.binding.source, "init.lua:12")
	}
	testing.expect_value(t, state.count, 0)
	_ = map_feed(&keymap, &state, &registry, "Ctrl+B")
	failed := map_feed(&keymap, &state, &registry, "X")
	_, blocked := failed.(commands.Blocked)
	testing.expect(t, blocked && state.count == 0)
	unbound := map_feed(&keymap, &state, &registry, "X")
	_, pass := unbound.(commands.Pass)
	testing.expect(t, pass)
	_ = map_feed(&keymap, &state, &registry, "Ctrl+B")
	commands.key_pending_clear(&state)
	unbound = map_feed(&keymap, &state, &registry, "C")
	_, pass = unbound.(commands.Pass)
	testing.expect(t, pass)
	prefix, _ := commands.parse_sequence("Ctrl+B")
	duplicate := commands.Binding{prefix, commands.Command_Target{id = 3}, ""}
	testing.expect_value(t, commands.keymap_bind(&keymap, duplicate), commands.Error.Duplicate_Shortcut)
}

@(test)
keymap_modes_stack_fall_through_and_consume_once_and_escape :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	for mode in ([?]commands.Mode{{"resize", false}, {"strict", true}, {"escape", false}}) {
		testing.expect_value(t, commands.mode_declare(&keymap, mode), commands.Error.None)
	}
	map_binding(t, &keymap, "Left", 1)
	map_binding(t, &keymap, "Right", 2)
	map_binding(t, &keymap, "resize/Left", 3)
	map_binding(t, &keymap, "resize/Ctrl+B>C", 4)
	map_binding(t, &keymap, "escape/Esc", 5)
	testing.expect(t, !commands.mode_enter(&keymap, &state, "unknown"))
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize"))
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Left"), 3)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Right"), 2)
	testing.expect(t, commands.mode_enter(&keymap, &state, "strict"))
	strict := map_feed(&keymap, &state, &registry, "Left")
	_, blocked := strict.(commands.Blocked)
	testing.expect(t, blocked)
	_ = map_feed(&keymap, &state, &registry, "Esc")
	testing.expect_value(t, len(state.modes), 1)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Left"), 3)
	testing.expect(t, commands.mode_enter(&keymap, &state, "escape"))
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Esc"), 5)
	testing.expect_value(t, len(state.modes), 2)
	commands.mode_exit(&state)
	_ = map_feed(&keymap, &state, &registry, "Esc")
	testing.expect_value(t, len(state.modes), 0)
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize", once = true))
	_ = map_feed(&keymap, &state, &registry, "Ctrl+B")
	testing.expect_value(t, len(state.modes), 1)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "C"), 4)
	testing.expect_value(t, len(state.modes), 0)
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize"))
	testing.expect(t, commands.mode_enter(&keymap, &state, "strict"))
	commands.mode_exit_all(&state)
	testing.expect_value(t, len(state.modes), 0)
}

@(test)
keymap_unbinding_masks_lower_layers_and_checks_the_target :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.mode_declare(&keymap, {"resize", false}), commands.Error.None)
	map_binding(t, &keymap, "Left", 1)
	map_binding(t, &keymap, "resize/Left", 2)
	sequence, _ := commands.parse_sequence("resize/Left")
	unrelated: commands.Binding_Target = commands.Command_Target{id = 3}
	testing.expect_value(t, commands.keymap_unbind(&keymap, sequence, unrelated), commands.Error.None)
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize"))
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Left"), 2)
	testing.expect_value(t, commands.keymap_unbind(&keymap, sequence), commands.Error.None)
	result := map_feed(&keymap, &state, &registry, "Left")
	_, blocked := result.(commands.Blocked)
	testing.expect(t, blocked)
	map_binding(t, &keymap, "resize/Left", 4)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Left"), 4)
	other, _ := commands.parse_sequence("resize/Right")
	testing.expect_value(t, commands.keymap_unbind(&keymap, other), commands.Error.None)
	result = map_feed(&keymap, &state, &registry, "Right")
	_, blocked = result.(commands.Blocked)
	testing.expect(t, blocked)
	commands.keymap_clear(&keymap)
	testing.expect_value(t, len(keymap.bindings), 0)
	testing.expect_value(t, len(keymap.blocked), 0)
	testing.expect_value(t, len(keymap.modes), 0)
	// Stack names remain owned by the window even when the host reloads its keymap.
	testing.expect_value(t, state.modes[0].name, "resize")
}

@(test)
keymap_precedence_reports_defaults_and_settings_losers :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	defaults := [?]input.Shortcut{{.B, {.Control}}, {.D, {.Control}}}
	testing.expect_value(t, commands.register(&registry, {
		id = 1, name = "pane.split", title = "Split", shortcuts = {defaults[:], len(defaults)},
	}), commands.Error.None)
	map_binding(t, &keymap, "Ctrl+B", 2)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Ctrl+B"), 2)
	conflicts := commands.keymap_conflicts(&keymap, &registry, context.temp_allocator)
	if testing.expect_value(t, len(conflicts), 1) {
		testing.expect_value(t, conflicts[0].loser_source, "defaults")
		testing.expect_value(t, conflicts[0].winner_source, "init.lua:12")
	}
	changed := [?]input.Shortcut{{.B, {.Control}}}
	testing.expect_value(t, commands.set_shortcuts(&registry, 1, changed[:]), commands.Error.None)
	result := map_feed(&keymap, &state, &registry, "Ctrl+B")
	_, pass := result.(commands.Pass)
	testing.expect(t, pass)
	conflicts = commands.keymap_conflicts(&keymap, &registry, context.temp_allocator)
	if testing.expect_value(t, len(conflicts), 1) {
		testing.expect_value(t, conflicts[0].winner_source, "settings")
		testing.expect_value(t, conflicts[0].loser_source, "init.lua:12")
	}
	// Mode bindings are not displaced by global settings shortcuts.
	testing.expect_value(t, commands.mode_declare(&keymap, {"resize", false}), commands.Error.None)
	map_binding(t, &keymap, "resize/Ctrl+B", 3)
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize"))
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Ctrl+B"), 3)
}

@(test)
keymap_matching_uses_logical_letters_and_physical_priority :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	map_binding(t, &keymap, "Ctrl+Z", 1)
	map_binding(t, &keymap, "Physical+Ctrl+Y", 2)
	map_expect_run(t, commands.feed(&keymap, &state, &registry, .Y, {.Control}, 'z'), 2)
	physical, _ := commands.parse_sequence("Physical+Ctrl+Y")
	testing.expect_value(t, commands.keymap_unbind(&keymap, physical), commands.Error.None)
	map_expect_run(t, commands.feed(&keymap, &state, &registry, .Y, {.Control}, 'z'), 1)
	map_binding(t, &keymap, "Physical+Ctrl+Y>Left", 3)
	result := commands.feed(&keymap, &state, &registry, .Y, {.Control}, 'z')
	_, pending := result.(commands.Pending)
	testing.expect(t, pending)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Left"), 3)
	// Modifier transitions never advance or cancel a sequence.
	_ = commands.feed(&keymap, &state, &registry, .Y, {.Control}, 'z')
	_ = commands.feed(&keymap, &state, &registry, .Shift_Left, {.Shift}, 0)
	testing.expect_value(t, state.count, 1)
}

@(test)
keymap_script_targets_bind_unbind_by_ref_and_format_their_sequence :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.mode_declare(&keymap, {"resize", false}), commands.Error.None)
	sequence, ok := commands.parse_sequence("resize/Ctrl+B>C")
	if !testing.expect(t, ok) {return}
	script := commands.Binding{sequence, commands.Script_Target{ref = 7}, "init.lua:4"}
	testing.expect_value(t, commands.keymap_bind(&keymap, script), commands.Error.None)
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize"))
	_ = map_feed(&keymap, &state, &registry, "Ctrl+B")
	result := map_feed(&keymap, &state, &registry, "C")
	if run, is_run := result.(commands.Run); testing.expect(t, is_run) {
		target, is_script := run.binding.target.(commands.Script_Target)
		testing.expect(t, is_script)
		testing.expect_value(t, target.ref, 7)
		testing.expect_value(t, run.binding.source, "init.lua:4")
	}
	buffer: [commands.SEQUENCE_TEXT_CAP]u8
	testing.expect_value(t, commands.sequence_text(sequence, buffer[:]), "resize/Ctrl+B>C")

	// A different function, or a command, is not the binding; the same ref is.
	other: commands.Binding_Target = commands.Script_Target{ref = 8}
	testing.expect_value(t, commands.keymap_unbind(&keymap, sequence, other), commands.Error.None)
	testing.expect_value(t, len(keymap.bindings), 1)
	command: commands.Binding_Target = commands.Command_Target{id = 7}
	testing.expect_value(t, commands.keymap_unbind(&keymap, sequence, command), commands.Error.None)
	testing.expect_value(t, len(keymap.bindings), 1)
	same: commands.Binding_Target = commands.Script_Target{ref = 7}
	testing.expect_value(t, commands.keymap_unbind(&keymap, sequence, same), commands.Error.None)
	testing.expect_value(t, len(keymap.bindings), 0)

	// Rebinding a sequence from a function to a command replaces the target in place.
	plain, _ := commands.parse_sequence("Ctrl+K")
	first := commands.Binding{plain, commands.Script_Target{ref = 9}, "init.lua:5"}
	testing.expect_value(t, commands.keymap_bind(&keymap, first), commands.Error.None)
	map_binding(t, &keymap, "Ctrl+K", 2, `{"direction":"down"}`)
	testing.expect_value(t, len(keymap.bindings), 1)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "Ctrl+K"), 2)
	script_again := commands.Binding{plain, commands.Script_Target{ref = 9}, "init.lua:6"}
	testing.expect_value(t, commands.keymap_bind(&keymap, script_again), commands.Error.None)
	result = map_feed(&keymap, &state, &registry, "Ctrl+K")
	if run, is_run := result.(commands.Run); testing.expect(t, is_run) {
		testing.expect_value(t, run.binding.target.(commands.Script_Target).ref, 9)
	}
}

@(private = "file")
map_claims :: proc(keymap: ^commands.Keymap, state: ^commands.Key_State, registry: ^commands.Registry,
                   text: string) -> bool {
	chord, ok := commands.parse_shortcut(text)
	assert(ok)
	return commands.keymap_claims(keymap, state, registry, chord.key, chord.modifiers, 0)
}

// An embedded page asks before a key reaches the app; the answer must not move the key state.
@(test)
keymap_claims_probes_without_changing_the_key_state :: proc(t: ^testing.T) {
	keymap: commands.Keymap
	commands.keymap_init(&keymap)
	defer commands.keymap_destroy(&keymap)
	state: commands.Key_State
	defer commands.key_state_destroy(&state)
	registry := commands.create()
	defer commands.destroy(&registry)
	map_binding(t, &keymap, "Ctrl+B>C", 1)
	map_binding(t, &keymap, "Ctrl+K", 2)
	for mode in ([?]commands.Mode{{"resize", false}, {"strict", true}}) {
		testing.expect_value(t, commands.mode_declare(&keymap, mode), commands.Error.None)
	}
	map_binding(t, &keymap, "resize/Left", 3)

	// The normal layer claims the first chord of a sequence or a binding, and passes anything else.
	testing.expect(t, map_claims(&keymap, &state, &registry, "Ctrl+B"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "Ctrl+K"))
	testing.expect(t, !map_claims(&keymap, &state, &registry, "Ctrl+M"))
	testing.expect(t, !map_claims(&keymap, &state, &registry, "A"))
	// A modifier alone is never a claim.
	testing.expect(t, !commands.keymap_claims(&keymap, &state, &registry, .Control_Left, {.Control}, 0))
	testing.expect_value(t, state.count, 0)
	testing.expect_value(t, len(state.modes), 0)

	// A sequence in progress takes every key, bound or not.
	_ = map_feed(&keymap, &state, &registry, "Ctrl+B")
	testing.expect_value(t, state.count, 1)
	testing.expect(t, map_claims(&keymap, &state, &registry, "X"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "C"))
	testing.expect_value(t, state.count, 1)
	map_expect_run(t, map_feed(&keymap, &state, &registry, "C"), 1)
	testing.expect_value(t, state.count, 0)

	// A mode that is not exclusive claims its own bindings and falls through for the rest.
	testing.expect(t, commands.mode_enter(&keymap, &state, "resize"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "Left"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "Ctrl+K"))
	testing.expect(t, !map_claims(&keymap, &state, &registry, "A"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "Esc"), "Escape leaves a mode")
	testing.expect_value(t, len(state.modes), 1)
	testing.expect_value(t, state.count, 0)

	// An exclusive mode takes every key.
	testing.expect(t, commands.mode_enter(&keymap, &state, "strict"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "A"))
	testing.expect(t, map_claims(&keymap, &state, &registry, "Ctrl+M"))
	testing.expect_value(t, len(state.modes), 2)
	testing.expect_value(t, state.modes[1].name, "strict")
	testing.expect_value(t, state.count, 0)
}
