package commands_test

import "base:runtime"
import "core:testing"
import "aio:commands"
import "cosmos:input"

@(test)
registration_and_lookup :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	name := [8]u8{'a', 'p', 'p', '.', 'q', 'u', 'i', 't'}
	command := commands.Command{
		id = 1,
		name = string(name[:]),
		title = "Quit",
		shortcuts = {{0 = {.Q, {.Control, .Shift}}}, 1},
	}
	testing.expect_value(t, commands.register(&registry, command), commands.Error.None)
	name[0] = 'x'
	found := commands.find(&registry, 1)
	if !testing.expect(t, found != nil) { return }
	testing.expect_value(t, found.name, "app.quit")
	testing.expect_value(t, found.title, "Quit")
	testing.expect(t, commands.find(&registry, "app.quit") == found)
	testing.expect(t, commands.find(&registry, "missing") == nil)
	testing.expect(t, commands.find(&registry, 99) == nil)
	Case :: struct { command: commands.Command, error: commands.Error }
	cases := [?]Case{
		{{id = 1, name = "other", title = "Other"}, .Duplicate_Id},
		{{id = 2, name = "app.quit", title = "Other"}, .Duplicate_Name},
		{
			{
				id = 2,
				name = "other",
				title = "Other",
				shortcuts = {{0 = {.Q, {.Control, .Shift, .Right_Shift, .Caps_Lock}}}, 1},
			},
			.Duplicate_Shortcut,
		},
		{{id = 2, name = "bad", title = "\xff"}, .Invalid_UTF8},
		{{id = 2, name = "\xff", title = "Bad"}, .Invalid_UTF8},
	}
	for item in cases {
		testing.expect_value(t, commands.register(&registry, item.command), item.error)
	}
	testing.expect_value(t, len(registry.items), 1)
	shortcut := commands.Shortcut{
		.Q,
		{.Control, .Shift, .Right_Control, .Right_Shift, .Num_Lock, .Caps_Lock},
	}
	testing.expect(t, commands.find_by_shortcut(&registry, shortcut) == found)
	testing.expect(t, commands.find_by_shortcut(&registry, {.Q, {.Control}}) == nil)
	other := commands.Command{id = 2, name = "app.other", title = "Quit"}
	testing.expect_value(t, commands.register(&registry, other), commands.Error.None)
}

@(test)
runtime_registration_ids_names_and_removal :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.register(&registry, {id = 0, name = "app.quit", title = "Quit",
		shortcuts = {{0 = {.Q, {.Control}}}, 1}}), commands.Error.None)
	testing.expect_value(t, commands.register(&registry, {id = 4, name = "reserved", title = "Reserved"}),
		commands.Error.None)
	FIRST :: commands.Command_Id(5)
	first, first_error := commands.register_runtime(&registry, {name = "first", title = "First",
		shortcuts = {{0 = {.F1, {}}}, 1}}, FIRST)
	testing.expect_value(t, first_error, commands.Error.None)
	testing.expect_value(t, first, commands.Command_Id(5))
	second, second_error := commands.register_runtime(&registry,
		{id = first, name = "second", title = "Second"}, FIRST)
	testing.expect_value(t, second_error, commands.Error.None)
	testing.expect_value(t, second, commands.Command_Id(6))
	first_command := commands.find(&registry, first)
	if !testing.expect(t, first_command != nil) {return}
	testing.expect(t, first_command.runtime)
	testing.expect_value(t, first_command.name, "first")
	testing.expect_value(t, commands.find(&registry, "second").id, second)
	for name in ([?]string{"", "app.custom", ".custom", "custom."}) {
		_, err := commands.register_runtime(&registry, {name = name, title = "Invalid"}, FIRST)
		testing.expect_value(t, err, commands.Error.Invalid_Name)
	}
	for name in ([?]string{"reserved", "first"}) {
		_, err := commands.register_runtime(&registry, {name = name, title = "Duplicate"}, FIRST)
		testing.expect_value(t, err, commands.Error.Duplicate_Name)
	}
	_, invalid_utf8 := commands.register_runtime(&registry, {name = "\xff", title = "Invalid"}, FIRST)
	testing.expect_value(t, invalid_utf8, commands.Error.Invalid_UTF8)
	testing.expect_value(t, len(registry.items), 4)
	testing.expect_value(t, commands.find(&registry, "first").id, first)
	commands.unregister_runtime(&registry)
	testing.expect_value(t, len(registry.items), 2)
	testing.expect(t, commands.find(&registry, first) == nil)
	testing.expect(t, commands.find(&registry, second) == nil)
	testing.expect(t, commands.find(&registry, "first") == nil)
	testing.expect(t, commands.find(&registry, "second") == nil)
	testing.expect(t, commands.find_by_shortcut(&registry, {.F1, {}}) == nil)
	testing.expect(t, commands.find_by_shortcut(&registry, {.Q, {.Control}}) != nil)
	testing.expect(t, commands.find(&registry, "app.quit") != nil)
	testing.expect(t, commands.find(&registry, "reserved") != nil)
	commands.unregister_runtime(&registry)
	testing.expect_value(t, len(registry.items), 2)
	reloaded, reload_error := commands.register_runtime(&registry,
		{name = "first", title = "Reloaded"}, FIRST)
	testing.expect_value(t, reload_error, commands.Error.None)
	testing.expect_value(t, reloaded, commands.Command_Id(5))
}

@(test)
runtime_metadata_is_owned_and_categories_honor_overrides :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	text := [6]u8{'C', 'u', 's', 't', 'o', 'm'}
	value := string(text[:])
	notes := [?]commands.Argument_Note{{argument = .Text, help = {value, value, value}}}
	bindings := [?]commands.Shortcut{{.F2, {}}}
	id, err := commands.register_runtime(&registry, {name = value, title = value,
		category = value, keywords = value, source = value, summary = value,
		notes = notes[:], shortcuts = {bindings[:], len(bindings)}}, 0)
	testing.expect_value(t, err, commands.Error.None)
	text[0] = 'X'
	notes[0] = {}
	bindings[0] = {.F3, {}}
	command := commands.find(&registry, id)
	if !testing.expect(t, command != nil) {return}
	for field in ([?]string{command.name, command.title, command.category, command.keywords,
		command.source, command.summary}) {
		testing.expect_value(t, field, "Custom")
	}
	testing.expect_value(t, len(command.notes), 1)
	testing.expect_value(t, command.notes[0].argument, commands.Argument.Text)
	testing.expect_value(t, command.notes[0].help.description, "Custom")
	testing.expect_value(t, command.notes[0].help.default, "Custom")
	testing.expect_value(t, command.notes[0].help.example, "Custom")
	testing.expect_value(t, command.shortcuts.items[0].key, input.Key.F2)
	testing.expect_value(t, command.defaults.items[0].key, input.Key.F2)
	testing.expect_value(t, commands.category(command), commands.Category{"Custom", "Custom"})
	builtin := commands.Command{name = "pane.split_right"}
	testing.expect_value(t, commands.category(&builtin), commands.Category{"Panes", "Pane shortcuts"})
	builtin.category = "Custom panes"
	testing.expect_value(t, commands.category(&builtin), commands.Category{"Custom panes", "Custom panes"})
	unknown := commands.Command{name = "custom"}
	testing.expect_value(t, commands.category(&unknown), commands.Category{"Commands", "Other shortcuts"})
}

@(test)
runtime_registration_allocation_failures_leave_no_command :: proc(t: ^testing.T) {
	completed := false
	for successful_allocations in 0 ..< 32 {
		failure := Failure{context.allocator, successful_allocations}
		registry := commands.create(runtime.Allocator{failing_allocator, &failure})
		notes := [?]commands.Argument_Note{{argument = .Text, help = {"Description", "Default", "Example"}}}
		id, err := commands.register_runtime(&registry, {name = "custom", title = "Custom",
			category = "Scripts", keywords = "search", source = "init.lua", summary = "Summary",
			notes = notes[:], shortcuts = {{0 = {.F1, {}}}, 1}}, 3)
		if err == .None {
			testing.expect_value(t, id, commands.Command_Id(3))
			commands.unregister_runtime(&registry)
			testing.expect_value(t, len(registry.items), 0)
			commands.destroy(&registry)
			completed = true
			break
		}
		testing.expect_value(t, err, commands.Error.Out_Of_Memory)
		testing.expect_value(t, len(registry.items), 0)
		commands.destroy(&registry)
	}
	testing.expect(t, completed)
}

@(test)
labels :: proc(t: ^testing.T) {
	Case :: struct { shortcut: commands.Shortcut, label: string }
	cases := [?]Case{
		{{.P, {.Control, .Shift}}, "Ctrl+Shift+P"},
		{{.Equal, {.Control}}, "Ctrl+="},
		{{.Insert, {.Shift}}, "Shift+Insert"},
		{{.Page_Up, {.Control, .Shift}}, "Ctrl+Shift+PageUp"},
		{{.Digit_0, {.Control}}, "Ctrl+0"},
		{{.Arrow_Down, {.Alt}}, "Alt+Down"},
		{{.F12, {.Super}}, "Win+F12"},
		{{.Backslash, {}}, "\\"},
		{{.Backquote, {}}, "`"},
		{{.Escape, {.Caps_Lock, .Num_Lock, .Right_Alt}}, "Esc"},
		{{.Numpad_Add, {}}, "Num+"},
		{{.Numpad_Enter, {}}, "Num Enter"},
		{{.Numpad_Memory_Add, {}}, "Num Memory+"},
		{{.Intl_Ro, {}}, "Ro"},
		{{.Meta_Left, {}}, "Left Win"},
		{{.Context_Menu, {}}, "Menu"},
		{{.Print_Screen, {}}, "PrtSc"},
	}
	buffer: [128]u8
	for item in cases {
		label, err := commands.shortcut_label(item.shortcut, buffer[:])
		testing.expect_value(t, err, commands.Error.None)
		testing.expect_value(t, label, item.label)
	}
	for key in input.Key {
		shortcut := commands.Shortcut{key, {.Control, .Shift, .Alt, .Super}}
		label, err := commands.shortcut_label(shortcut, buffer[:])
		testing.expect_value(t, err, commands.Error.None)
		testing.expect(t, len(label) > 0)
		for r in label { testing.expect(t, r != '_') }
		for capacity in 0..=len(label) {
			guarded: [128]u8
			for &byte in guarded { byte = 0xcd }
			actual, error := commands.shortcut_label(shortcut, guarded[1:1+capacity])
			if capacity == len(label) {
				testing.expect_value(t, error, commands.Error.None)
				testing.expect_value(t, actual, label)
			} else {
				testing.expect_value(t, error, commands.Error.Output_Too_Small)
				testing.expect_value(t, actual, "")
			}
			testing.expect_value(t, guarded[0], u8(0xcd))
			for byte in guarded[1+capacity:] { testing.expect_value(t, byte, u8(0xcd)) }
		}
	}
}

@(test)
ownership_and_failure :: proc(t: ^testing.T) {
	partial: commands.Registry
	commands.destroy(&partial)
	commands.destroy(&partial)
	for successful_allocations in 0..<3 {
		failure := Failure{context.allocator, successful_allocations}
		registry := commands.create(runtime.Allocator{failing_allocator, &failure})
		testing.expect_value(t, failure.remaining, successful_allocations)
		command := commands.Command{id = 1, name = "quit", title = "Quit"}
		testing.expect_value(t, commands.register(&registry, command), commands.Error.Out_Of_Memory)
		testing.expect_value(t, len(registry.items), 0)
		commands.destroy(&registry)
	}
}

Failure :: struct { backing: runtime.Allocator, remaining: int }

@(test)
many_shortcut_alternatives_survive_rebinding_and_failed_growth :: proc(t: ^testing.T) {
	state := Failure{context.allocator, 64}
	registry := commands.create(runtime.Allocator{failing_allocator, &state})
	defer commands.destroy(&registry)
	defaults := [?]commands.Shortcut{{.Q, {.Control}}}
	testing.expect_value(t, commands.register(&registry, {id = 1, name = "quit", title = "Quit",
		shortcuts = {defaults[:], len(defaults)}}), commands.Error.None)
	bindings: [12]commands.Shortcut
	n, err := commands.parse_shortcuts("F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12", bindings[:])
	testing.expect_value(t, err, commands.Error.None)
	testing.expect_value(t, n, 12)
	testing.expect_value(t, commands.set_shortcuts(&registry, 1, bindings[:]), commands.Error.None)
	for binding in bindings { testing.expect(t, commands.find_by_shortcut(&registry, binding) != nil) }
	command := commands.find(&registry, 1)
	state.remaining = 0
	larger: [13]commands.Shortcut
	copy(larger[:], bindings[:])
	larger[12] = {.F13, {}}
	testing.expect_value(t, commands.set_shortcuts(&registry, 1, larger[:]), commands.Error.Out_Of_Memory)
	testing.expect_value(t, command.shortcuts.count, 12)
	testing.expect_value(t, commands.rebind(&registry, nil, nil), commands.Error.None)
	testing.expect_value(t, command.shortcuts.count, 1)
	testing.expect_value(t, command.shortcuts.items[0], defaults[0])
}

failing_allocator :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location,
) -> ([]u8, runtime.Allocator_Error) {
	state := (^Failure)(data)
	allocating := mode == .Alloc || mode == .Resize ||
	              mode == .Alloc_Non_Zeroed || mode == .Resize_Non_Zeroed
	if allocating && size > 0 {
		if state.remaining == 0 { return nil, .Out_Of_Memory }
		state.remaining -= 1
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
shortcut_round_trips :: proc(t: ^testing.T) {
	buffer: [128]u8
	for key in input.Key {
		for bits in 0..<1024 {
			modifiers := transmute(input.Modifiers)u16(bits)
			label, err := commands.shortcut_label({key, modifiers}, buffer[:])
			testing.expect_value(t, err, commands.Error.None)
			parsed, ok := commands.parse_shortcut(label)
			testing.expect(t, ok)
			testing.expect_value(t, parsed, commands.Shortcut{
				key, modifiers & {.Control, .Shift, .Alt, .Super},
			})
		}
	}
	parsed, ok := commands.parse_shortcut("  cTrL + sHiFt + pAgEuP  ")
	testing.expect(t, ok)
	testing.expect_value(t, parsed, commands.Shortcut{.Page_Up, {.Control, .Shift}})
	for invalid in ([]string{"", "Ctrl+", "Ctrl+Ctrl+C", "Ctrl+Bogus", "Hyper+A", "A+B"}) {
		_, valid := commands.parse_shortcut(invalid)
		testing.expect(t, !valid)
	}
}

@(test)
multiple_shortcuts :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	bindings := [?]commands.Shortcut{{.C, {.Control, .Shift}}, {.Insert, {.Control}}}
	testing.expect_value(t, commands.register(&registry,
		{id = 1, name = "copy", title = "Copy", shortcuts = {{0 = bindings[0], 1 = bindings[1]}, 2}}), commands.Error.None)
	bindings[0].key = .A
	copy_command := commands.find(&registry, 1)
	if !testing.expect(t, copy_command != nil) { return }
	testing.expect_value(t, copy_command.shortcuts.items[0].key, input.Key.C)
	testing.expect(t, commands.find_by_shortcut(&registry, {.Insert, {.Control}}) == copy_command)
	testing.expect_value(t, commands.register(&registry,
		{id = 2, name = "paste", title = "Paste"}), commands.Error.None)
	testing.expect_value(t, commands.set_shortcuts(&registry, 2, commands.active_shortcuts(copy_command)),
		commands.Error.Duplicate_Shortcut)
	testing.expect_value(t, len(commands.active_shortcuts(commands.find(&registry, 2))), 0)
	paste_binding := [?]commands.Shortcut{{.V, {.Control}}}
	testing.expect_value(t, commands.set_shortcuts(&registry, 2, paste_binding[:]), commands.Error.None)
	conflicting := [?]commands.Shortcut{{.A, {.Alt}}, {.Insert, {.Control, .Right_Control}}}
	testing.expect_value(t, commands.set_shortcuts(&registry, 2, conflicting[:]),
		commands.Error.Duplicate_Shortcut)
	testing.expect_value(t, commands.find(&registry, 2).shortcuts.items[0], paste_binding[0])
	testing.expect(t, commands.find_by_shortcut(&registry, conflicting[0]) == nil)
	testing.expect_value(t, commands.register(&registry,
		{id = 3, name = "conflict", title = "Conflict", shortcuts = {{0 = conflicting[0], 1 = conflicting[1]}, 2}}),
		commands.Error.Duplicate_Shortcut)
	testing.expect_value(t, commands.set_shortcuts(&registry, 99, nil), commands.Error.Unknown_Command)
	testing.expect_value(t, commands.set_shortcuts(&registry, 1, commands.active_shortcuts(copy_command)),
		commands.Error.None)
	testing.expect_value(t, commands.set_shortcuts(&registry, 1, nil), commands.Error.None)
	testing.expect(t, commands.find_by_shortcut(&registry, {.Insert, {.Control}}) == nil)
	testing.expect_value(t, len(commands.active_shortcuts(copy_command)), 0)
	out: [4]commands.Shortcut
	count, err := commands.parse_shortcuts("Ctrl+,, Ctrl+Num ,, Ctrl+Num+, Shift+Insert", out[:])
	testing.expect_value(t, err, commands.Error.None)
	testing.expect_value(t, count, 4)
	testing.expect_value(t, out[0].key, input.Key.Comma)
	testing.expect_value(t, out[1].key, input.Key.Numpad_Comma)
	testing.expect_value(t, out[2].key, input.Key.Numpad_Add)
	count, err = commands.parse_shortcuts("  ", out[:])
	testing.expect_value(t, count, 0)
	testing.expect_value(t, err, commands.Error.None)
	for text in ([]string{"Ctrl+C,", "Ctrl+C, Bad", ",,"}) {
		_, error := commands.parse_shortcuts(text, out[:])
		testing.expect_value(t, error, commands.Error.Invalid_Shortcut)
	}
	_, small := commands.parse_shortcuts("Ctrl+C, Ctrl+Insert", out[:1])
	testing.expect_value(t, small, commands.Error.Output_Too_Small)
}

@(test)
shortcut_set_text_has_one_join_and_one_parse_policy :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	bindings := [?]commands.Shortcut{{.C, {.Control, .Shift}}, {.Insert, {.Control}}, {.V, {.Alt}}}
	set := commands.Shortcut_Set{bindings[:], 2}
	testing.expect_value(t, commands.shortcut_set_text(set, context.temp_allocator),
		"Ctrl+Shift+C, Ctrl+Insert")
	testing.expect_value(t, commands.shortcut_set_text({bindings[:], 0}, context.temp_allocator), "")
	testing.expect_value(t, commands.shortcut_set_text({}, context.temp_allocator), "")
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	testing.expect_value(t, commands.shortcut_text(bindings[0], buffer[:]), "Ctrl+Shift+C")
	alternatives := commands.shortcut_alternatives(
		" Ctrl+Shift+C ,ctrl+insert ",
		context.temp_allocator,
	)
	testing.expect_value(t, len(alternatives), 2)
	testing.expect_value(t, alternatives[0], "Ctrl+Shift+C")
	testing.expect_value(t, alternatives[1], "Ctrl+Insert")
	testing.expect_value(t, len(commands.shortcut_alternatives("", context.temp_allocator)), 0)
	testing.expect_value(t, len(commands.shortcut_alternatives("  ", context.temp_allocator)), 0)
	raw := commands.shortcut_alternatives(" Ctrl+Bogus , F5 ", context.temp_allocator)
	testing.expect_value(t, len(raw), 2)
	testing.expect_value(t, raw[0], "Ctrl+Bogus")
	testing.expect_value(t, raw[1], "F5")
	testing.expect_value(t, len(commands.shortcut_alternatives("Ctrl+Bogus,", context.temp_allocator)), 2)
	testing.expect_value(t, commands.shortcut_alternatives_text(raw, context.temp_allocator),
		"Ctrl+Bogus, F5")
	testing.expect_value(
		t,
		commands.shortcut_alternatives_text([]string{" Ctrl+C ", "", "F5"}, context.temp_allocator),
		"Ctrl+C, F5",
	)
	testing.expect_value(t, commands.shortcut_alternatives_text(nil, context.temp_allocator), "")
	text := commands.shortcut_set_text(set, context.temp_allocator)
	testing.expect_value(
		t,
		commands.shortcut_alternatives_text(
			commands.shortcut_alternatives(text, context.temp_allocator),
			context.temp_allocator,
		),
		text,
	)
}

@(test)
rebinding :: proc(t: ^testing.T) {
	state := Failure{context.allocator, 16}
	registry := commands.create(runtime.Allocator{failing_allocator, &state})
	defer commands.destroy(&registry)
	for command in ([?]commands.Command{
		{id = 1, name = "copy", title = "Copy", shortcuts = {{0 = {.C, {.Control}}}, 1}},
		{id = 2, name = "paste", title = "Paste", shortcuts = {{0 = {.V, {.Control}}}, 1}},
		{id = 3, name = "other", title = "Other", shortcuts = {{0 = {.X, {.Control}}}, 1}},
	}) {
		testing.expect_value(t, commands.register(&registry, command), commands.Error.None)
	}
	state.remaining = 0
	copy_command := commands.find(&registry, 1)
	copy_chord := [?]commands.Shortcut{{.C, {.Control}}}
	paste_chord := [?]commands.Shortcut{{.V, {.Control}}}
	other_chord := [?]commands.Shortcut{{.X, {.Control}}}
	swap := [?]commands.Override{{1, paste_chord[:]}, {2, copy_chord[:]}}
	errors: [2]commands.Error
	_ = commands.rebind(&registry, swap[:], errors[:])
	for error in errors { testing.expect_value(t, error, commands.Error.None) }
	testing.expect(t, commands.find_by_shortcut(&registry, paste_chord[0]) == copy_command)
	testing.expect_value(t, commands.find_by_shortcut(&registry, copy_chord[0]).id, commands.Command_Id(2))
	testing.expect(t, commands.find(&registry, 1) == copy_command)
	conflict := [?]commands.Override{{1, other_chord[:]}}
	_ = commands.rebind(&registry, conflict[:], errors[:])
	testing.expect_value(t, errors[0], commands.Error.Duplicate_Shortcut)
	testing.expect(t, commands.find_by_shortcut(&registry, copy_chord[0]) == copy_command)
	fallback_taken := [?]commands.Override{{2, copy_chord[:]}, {1, other_chord[:]}}
	_ = commands.rebind(&registry, fallback_taken[:], errors[:])
	testing.expect_value(t, errors[0], commands.Error.None)
	testing.expect_value(t, errors[1], commands.Error.Duplicate_Shortcut)
	testing.expect_value(t, len(commands.active_shortcuts(copy_command)), 0)
	_ = commands.rebind(&registry, nil, nil)
	testing.expect(t, commands.find_by_shortcut(&registry, copy_chord[0]) == copy_command)
	testing.expect_value(t, commands.find_by_shortcut(&registry, paste_chord[0]).id, commands.Command_Id(2))
	testing.expect_value(t, commands.find_by_shortcut(&registry, other_chord[0]).id, commands.Command_Id(3))
	unbound := [?]commands.Override{{1, nil}}
	_ = commands.rebind(&registry, unbound[:], errors[:])
	testing.expect_value(t, errors[0], commands.Error.None)
	testing.expect_value(t, len(commands.active_shortcuts(copy_command)), 0)
	unknown := [?]commands.Override{{99, copy_chord[:]}}
	_ = commands.rebind(&registry, unknown[:], errors[:])
	testing.expect_value(t, errors[0], commands.Error.Unknown_Command)
}
