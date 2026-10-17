package commands_test

import "base:runtime"
import "core:testing"
import "aio:commands"
import "aio:fuzzy"
import "aio:input"

@(test)
registration_and_lookup :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	name := [8]u8{'a', 'p', 'p', '.', 'q', 'u', 'i', 't'}
	command := commands.Command{
		id = 1,
		name = string(name[:]),
		title = "Quit",
		shortcut = commands.Shortcut{.Q, {.Control, .Shift}},
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
				shortcut = commands.Shortcut{.Q, {.Control, .Shift, .Right_Shift, .Caps_Lock}},
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
search_and_errors :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	for command in ([?]commands.Command{
		{id = 1, name = "restart", title = "Restart Shell"},
		{id = 2, name = "reload", title = "Reload Settings"},
		{id = 3, name = "restart_other", title = "Restart Shell"},
		{id = 4, name = "unicode", title = "KςÉ"},
	}) {
		testing.expect_value(t, commands.register(&registry, command), commands.Error.None)
	}
	scratch, allocation_error := new(fuzzy.Scratch)
	if allocation_error != nil { testing.fail_now(t, "scratch allocation failed") }
	defer free(scratch)
	out: [4]commands.Search_Result
	positions: [12]int
	count, search_error := commands.search(
		&registry, "rs", out[:], positions[:], scratch, context.allocator,
	)
	testing.expect_value(t, search_error, commands.Error.None)
	testing.expect_value(t, count, 3)
	testing.expect_value(t, out[0].command.id, commands.Command_Id(1))
	testing.expect_value(t, out[1].command.id, commands.Command_Id(3))
	testing.expect_value(t, out[0].positions[0], 0)
	testing.expect_value(t, out[0].positions[1], 8)
	count, search_error = commands.search(&registry, "", out[:], nil, scratch, context.allocator)
	testing.expect_value(t, search_error, commands.Error.None)
	testing.expect_value(t, count, 4)
	for result, index in out {
		testing.expect_value(t, result.command.id, commands.Command_Id(index+1))
		testing.expect_value(t, len(result.positions), 0)
	}
	count, search_error = commands.search(
		&registry, "kσé", out[:], positions[:], scratch, context.allocator,
	)
	testing.expect_value(t, search_error, commands.Error.None)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, out[0].positions[1], 3)
	_, small_out := commands.search(&registry, "", out[:1], nil, scratch, context.allocator)
	testing.expect_value(t, small_out, commands.Error.Output_Too_Small)
	_, small_positions := commands.search(
		&registry, "abc", out[:], positions[:1], scratch, context.allocator,
	)
	testing.expect_value(t, small_positions, commands.Error.Output_Too_Small)
	_, invalid := commands.search(&registry, "\xff", out[:], positions[:], scratch, context.allocator)
	testing.expect_value(t, invalid, commands.Error.Invalid_UTF8)
	for successful_allocations in 0..<3 {
		failure := Failure{context.allocator, successful_allocations}
		allocator := runtime.Allocator{failing_allocator, &failure}
		_, no_memory := commands.search(&registry, "", out[:], nil, scratch, allocator)
		testing.expect_value(t, no_memory, commands.Error.Out_Of_Memory)
	}
}

@(test)
enabled_state :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	command := commands.Command{id = 1, name = "quit", title = "Quit"}
	testing.expect_value(t, commands.register(&registry, command), commands.Error.None)
	scratch, allocation_error := new(fuzzy.Scratch)
	if allocation_error != nil { testing.fail_now(t, "scratch allocation failed") }
	defer free(scratch)
	out: [1]commands.Search_Result
	positions: [1]int
	testing.expect(t, !commands.set_enabled(&registry, 99, false))
	testing.expect(t, !commands.set_enabled(&registry, 99, true))
	for query in ([?]string{"", "q"}) {
		for enabled in ([?]bool{true, false, true}) {
			testing.expect(t, commands.set_enabled(&registry, 1, enabled))
			count, err := commands.search(
				&registry, query, out[:], positions[:], scratch, context.allocator,
			)
			testing.expect_value(t, err, commands.Error.None)
			testing.expect_value(t, count, int(enabled))
			if count == 1 {
				testing.expect_value(t, out[0].command.id, commands.Command_Id(1))
			}
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

