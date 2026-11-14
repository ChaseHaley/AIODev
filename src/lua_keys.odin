package main

import "aio:commands"
import "aio:scripting"
import "aio:settings"
import "core:fmt"
import "core:strconv"
import "core:strings"

// Rebuilds the keymap from what init.lua declared, so a reload never keeps a key the new file dropped.
// The host registers the runtime commands first, so action names resolve like built-in commands. Each
// rejected declaration is one diagnostic at its own line; the declarations that remain still apply.
lua_keys_apply :: proc(app: ^App, decls: scripting.Declarations, diagnostics: ^[dynamic]settings.Diagnostic) {
	commands.keymap_clear(&app.keymap)
	for mode in decls.modes {
		declared := commands.Mode{mode.name, mode.exclusive}
		if err := commands.mode_declare(&app.keymap, declared); err != .None {
			reason := err == .Invalid_Shortcut ? "use lowercase letters, digits, _ and -" : lua_keys_error_text(err)
			lua_keys_problem(diagnostics, mode.file, mode.line, fmt.tprintf(
				"cannot declare mode \"%s\": %s", mode.name, reason))
		}
	}
	for decl in decls.keys {
		sequence, parsed := commands.parse_sequence(decl.key)
		if !parsed {
			lua_keys_problem(diagnostics, decl.file, decl.line, fmt.tprintf("cannot parse key \"%s\"", decl.key))
			continue
		}
		target: commands.Binding_Target
		if decl.command != "" {
			command := commands.find(&app.registry, decl.command)
			if command == nil {
				lua_keys_problem(diagnostics, decl.file, decl.line, fmt.tprintf(
					"unknown command \"%s\" for key \"%s\"", decl.command, decl.key))
				continue
			}
			if decl.fields != "" {
				_, field_error := commands.parse_fields(&app.registry, command.name, decl.fields,
					context.temp_allocator)
				if field_error.advice != "" {
					lua_keys_problem(diagnostics, decl.file, decl.line, fmt.tprintf(
						"key \"%s\" runs %s: %s: %s", decl.key, command.name, field_error.argument,
						field_error.advice))
					continue
				}
			}
			target = commands.Command_Target{command.id, decl.fields}
		} else if decl.ref != 0 {
			target = commands.Script_Target{decl.ref}
		}
		err: commands.Error
		switch decl.op {
		case .Bind:
			if target == nil {
				lua_keys_problem(diagnostics, decl.file, decl.line, fmt.tprintf("key \"%s\" has no target", decl.key))
				continue
			}
			binding := commands.Binding{sequence, target, fmt.tprintf("%s:%d", lua_keys_file(decl.file), decl.line)}
			err = commands.keymap_bind(&app.keymap, binding)
		case .Unbind:
			err = commands.keymap_unbind(&app.keymap, sequence, lua_keys_unbind_target(&app.keymap, sequence, target))
		}
		if err != .None {
			lua_keys_problem(diagnostics, decl.file, decl.line, fmt.tprintf(
				"cannot %s key \"%s\": %s", decl.op == .Bind ? "bind" : "unbind", decl.key, lua_keys_error_text(err)))
		}
	}
	conflicts := commands.keymap_conflicts(&app.keymap, &app.registry, context.temp_allocator)
	for conflict in conflicts {
		label: [commands.SEQUENCE_TEXT_CAP]u8
		key := commands.sequence_text(conflict.sequence, label[:])
		keymap_wins := conflict.loser_source == "defaults"
		ours := keymap_wins ? conflict.winner_source : conflict.loser_source
		file, line := lua_keys_source(ours)
		winner := lua_keys_target_text(app, conflict.winner)
		loser := lua_keys_target_text(app, conflict.loser)
		message := fmt.tprintf("key \"%s\": %s (%s) wins over %s (%s)", key, winner, conflict.winner_source,
			loser, conflict.loser_source)
		// The identity leaves out the line, so moving the binding in init.lua keeps it the same warning.
		identity := fmt.tprintf("key \"%s\": %s (%s) wins over %s (%s)", key, winner,
			keymap_wins ? file : conflict.winner_source, loser, keymap_wins ? conflict.loser_source : file)
		_ = settings.diagnostic_append(diagnostics, line, file, message, .Shortcut_Warning, identity)
	}
}

// Unbinding by name removes the key whatever fields its binding was given, since aio.unbind takes no
// fields; the keymap engine itself matches a command target only with the same fields.
@(private = "file", require_results)
lua_keys_unbind_target :: proc(
	keymap: ^commands.Keymap,
	sequence: commands.Key_Sequence,
	target: commands.Binding_Target,
) -> commands.Binding_Target {
	named, is_command := target.(commands.Command_Target)
	if !is_command || named.fields != "" {return target}
	for stored in keymap.bindings {
		if !commands.sequence_equal(stored.sequence, sequence) {continue}
		if existing, ok := stored.target.(commands.Command_Target); ok && existing.id == named.id {
			return stored.target
		}
		break
	}
	return target
}

// Declarations recorded without a caller frame still belong to init.lua.
@(private = "file", require_results)
lua_keys_file :: proc(file: string) -> string {
	return file != "" ? file : "init.lua"
}

// Undoes the "file:line" source lua_keys_apply gave the binding, so its warning lands on that line.
@(private = "file", require_results)
lua_keys_source :: proc(source: string) -> (string, int) {
	colon := strings.last_index_byte(source, ':')
	if colon < 0 {return source, 0}
	line, ok := strconv.parse_int(source[colon + 1:], 10)
	if !ok {return source, 0}
	return source[:colon], line
}

@(private = "file", require_results)
lua_keys_target_text :: proc(app: ^App, target: commands.Binding_Target) -> string {
	switch value in target {
	case nil:
		return "nothing"
	case commands.Command_Target:
		command := commands.find(&app.registry, value.id)
		return command != nil ? command.name : "an unknown command"
	case commands.Script_Target:
		return "a Lua function"
	}
	return ""
}

@(private = "file", require_results)
lua_keys_error_text :: proc(err: commands.Error) -> string {
	switch err {
	case .None:
		return "no error"
	case .Duplicate_Shortcut:
		return "another key's sequence starts with it, or it starts with another's"
	case .Invalid_Shortcut:
		return "not a valid key sequence"
	case .Unknown_Command:
		return "unknown command"
	case .Out_Of_Memory:
		return "out of memory"
	case .Duplicate_Id, .Duplicate_Name, .Invalid_UTF8, .Output_Too_Small, .Invalid_Name:
		return fmt.tprintf("%v", err)
	}
	return ""
}

@(private = "file")
lua_keys_problem :: proc(
	diagnostics: ^[dynamic]settings.Diagnostic,
	file: string,
	line: int,
	message: string,
) {
	// Running out of memory for a diagnostic loses only that report; the keymap is already applied.
	_ = settings.diagnostic_append(diagnostics, line, lua_keys_file(file), message)
}
