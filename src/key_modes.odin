package main

import "aio:commands"
import "cosmos:input"
import "core:fmt"
import "core:time"

key_sequence_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	return w.key_until, w.bindings.count > 0
}

key_sequence_expire :: proc(w: ^Window, now: time.Tick) {
	if until, pending := key_sequence_deadline(w); pending && time.tick_diff(now, until) <= 0 {
		commands.key_pending_clear(&w.bindings)
		w.dirty = true
	}
}

// Runs before the leader and the registry. Only fresh presses feed the keymap: a repeat of a key it
// took stays with it, so a held key never runs a binding twice, and a release of such a key was
// already dropped as suppressed. A chord the armed leader is waiting for belongs to the leader.
@(private)
keymap_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	if !e.pressed || input.is_modifier_key(e.key) {return false}
	if e.repeat {return w.keymap_held[e.key]}
	w.keymap_held[e.key] = false
	if leader_armed(w) {return false}
	now := clock_now(&app.clock)
	key_sequence_expire(w, now)
	before_count, before_modes := w.bindings.count, len(w.bindings.modes)
	result := commands.feed(&app.keymap, &w.bindings, &app.registry, e.key, e.modifiers, e.unshifted)
	if before_count != w.bindings.count || before_modes != len(w.bindings.modes) {w.dirty = true}
	switch value in result {
	case commands.Pass:
		return false
	case commands.Blocked:
		keymap_take(w, e)
		return true
	case commands.Pending:
		keymap_take(w, e)
		w.key_until = time.tick_add(now, LEADER_TIMEOUT)
		w.dirty = true
		return true
	case commands.Run:
		switch target in value.binding.target {
		case nil:
			// keymap_bind refuses a nil target, so none runs; the key passes on as if unbound.
			return false
		case commands.Command_Target:
			command := commands.find(&app.registry, target.id)
			if command == nil {return false}
			if action, builtin := action_builtin(target.id); builtin && !action_available(app, w, action) {
				return false
			}
			invocation := commands.invocation(target.id, focus = true)
			if target.fields != "" {
				parsed, err := commands.parse_fields(&app.registry, command.name, target.fields, context.temp_allocator)
				if err.advice != "" {
					notify(app, .Error, fmt.tprintf("%s: %s", err.argument, err.advice))
					keymap_take(w, e)
					return true
				}
				invocation = parsed
				if .Focus not_in invocation.given {invocation.focus = true}
			}
			keymap_take(w, e)
			_ = command_execute(app, Window_Context{window = w, origin = .Key}, invocation)
			return true
		case commands.Script_Target:
			// A function that returns false passes the key on untouched, so it is taken only once Lua
			// has claimed it; the text lives on this frame because the hot path must not allocate.
			buffer: [commands.SEQUENCE_TEXT_CAP]u8
			if !lua_host_key(app, w, target.ref, commands.sequence_text(value.binding.sequence, buffer[:])) {
				return false
			}
			keymap_take(w, e)
			return true
		}
	}
	return false
}

@(private = "file")
keymap_take :: proc(w: ^Window, e: input.Key_Event) {
	key_suppress(w, e)
	w.keymap_held[e.key] = true
}

@(private)
key_mode_command :: proc(app: ^App, w: ^Window, action: Action, invocation: commands.Invocation) -> Outcome {
	if w == nil {return outcome_failure(.Target, "no window for the key mode")}
	#partial switch action {
	case .Mode_Enter:
		if !commands.mode_enter(&app.keymap, &w.bindings, invocation.name, invocation.once) {
			message := fmt.tprintf("Unknown or unavailable key mode: %s", invocation.name)
			notify(app, .Info, message)
			return outcome_failure(.Usage, message)
		}
	case .Mode_Exit:
		commands.mode_exit(&w.bindings)
	case .Mode_Exit_All:
		commands.mode_exit_all(&w.bindings)
	}
	w.dirty = true
	return {}
}

// Uses the caller's fixed drawing buffer, so a pending chord never allocates on a frame.
@(private)
key_mode_text :: proc(w: ^Window, out: []u8) -> string {
	length := 0
	if len(w.bindings.modes) > 0 {
		length += copy(out[length:], w.bindings.modes[len(w.bindings.modes) - 1].name)
		if w.bindings.count > 0 {length += copy(out[length:], "/")}
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	for chord, i in w.bindings.pending[:w.bindings.count] {
		if i > 0 {length += copy(out[length:], ">")}
		logical := commands.logical_key(chord.physical, chord.unshifted)
		label := commands.shortcut_text({logical, chord.modifiers}, buffer[:])
		length += copy(out[length:], label)
	}
	if w.bindings.count > 0 {length += copy(out[length:], " …")}
	return string(out[:length])
}
