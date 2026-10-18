package commands_test

import "core:testing"
import "aio:commands"
import "aio:input"

@(test)
logical_and_physical_bindings_follow_distinct_key_identity :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	for item in ([?]commands.Command{
		{id = 1, name = "logical_z", title = "Logical Z", shortcuts = {items = {{.Z, {.Control}}, {}, {}, {}}, count = 1}},
		{id = 2, name = "physical_z", title = "Physical Z",
			shortcuts = {items = {{.Z, {.Control, .Physical}}, {}, {}, {}}, count = 1}},
		{id = 3, name = "shift_z", title = "Shift Z",
			shortcuts = {items = {{.Z, {.Control, .Shift}}, {}, {}, {}}, count = 1}},
		{id = 4, name = "logical_c", title = "Logical C",
			shortcuts = {items = {{.C, {.Control}}, {}, {}, {}}, count = 1}},
		{id = 5, name = "logical_1", title = "Logical 1",
			shortcuts = {items = {{.Digit_1, {.Control}}, {}, {}, {}}, count = 1}},
	}) {
		testing.expect_value(t, commands.register(&registry, item), commands.Error.None)
	}
	testing.expect_value(t, commands.find_by_key(&registry, .Y, {.Control}, 'z').id, commands.Command_Id(1))
	testing.expect_value(t, commands.find_by_key(&registry, .Z, {.Control}, 'y').id, commands.Command_Id(2))
	testing.expect_value(t, commands.find_by_key(&registry, .Z, {.Control}, 'z').id, commands.Command_Id(2))
	testing.expect_value(t, commands.find_by_key(&registry, .Y, {.Control, .Shift}, 'z').id, commands.Command_Id(3))
	testing.expect_value(t, commands.find_by_key(&registry, .Y, {.Control, .Caps_Lock}, 'Z').id, commands.Command_Id(1))
	testing.expect_value(t, commands.find_by_key(&registry, .Y, {.Alt}, 'z'), nil)
	testing.expect_value(t, commands.find_by_key(&registry, .Z, {.Control}, 'я').id, commands.Command_Id(2))
	testing.expect_value(t, commands.find_by_key(&registry, .C, {.Control}, 'с').id, commands.Command_Id(4))
	testing.expect_value(t, commands.find_by_key(&registry, .Digit_1, {.Control}, '&').id, commands.Command_Id(5))
}

@(test)
logical_punctuation_does_not_use_shifted_text_or_remap_keypad :: proc(t: ^testing.T) {
	testing.expect_value(t, commands.logical_key(.Y, 'z'), input.Key.Z)
	testing.expect_value(t, commands.logical_key(.Digit_2, '2'), input.Key.Digit_2)
	testing.expect_value(t, commands.logical_key(.Bracket_Left, '['), input.Key.Bracket_Left)
	testing.expect_value(t, commands.logical_key(.Quote, 'ü'), input.Key.Quote)
	testing.expect_value(t, commands.logical_key(.C, 'с'), input.Key.C)
	testing.expect_value(t, commands.logical_key(.Digit_1, '&'), input.Key.Digit_1)
	testing.expect_value(t, commands.logical_key(.Digit_2, 'é'), input.Key.Digit_2)
	testing.expect(t, commands.shortcut_matches({.C, {.Control}}, .C, {.Control}, 'с'))
	testing.expect(t, commands.shortcut_matches({.Digit_1, {.Control}}, .Digit_1, {.Control}, '&'))
	testing.expect_value(t, commands.logical_key(.Numpad_1, '1'), input.Key.Numpad_1)
	testing.expect_value(t, commands.logical_key(.Enter, '\r'), input.Key.Enter)
	testing.expect_value(t, commands.logical_key(.F1, 0), input.Key.F1)
	testing.expect(t, commands.shortcut_matches({.Digit_2, {.Shift}}, .Digit_2, {.Shift}, '2'))
	testing.expect(t, !commands.shortcut_matches({.Digit_2, {}}, .Digit_2, {.Shift}, '2'))
	testing.expect(t, commands.shortcut_matches({.Z, {.Physical, .Leader}}, .Z, {.Leader}, 'y'))
}

@(test)
prefix_reserves_both_identity_modes_without_conflating_direct_bindings :: proc(t: ^testing.T) {
	testing.expect(t, commands.prefix_conflicts({.B, {.Control}}, {.B, {.Control, .Physical}}))
	testing.expect(t, commands.prefix_conflicts({.B, {.Control, .Physical}}, {.B, {.Control}}))
	testing.expect(t, !commands.prefix_conflicts({.B, {.Control}}, {.B, {.Control, .Shift, .Physical}}))
	testing.expect(t, !commands.prefix_conflicts({.B, {.Control}}, {.C, {.Control, .Physical}}))
}

@(test)
azerty_digit_row_preserves_all_number_shortcuts :: proc(t: ^testing.T) {
	unshifted := [?]rune{'à', '&', 'é', '"', '\'', '(', '-', 'è', '_', 'ç'}
	registry := commands.create()
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.register(&registry, {
		id = 1, name = "number", title = "Number",
	}), commands.Error.None)
	testing.expect_value(t, commands.register(&registry, {
		id = 2, name = "punctuation", title = "Punctuation",
		shortcuts = {items = {{.Quote, {.Alt}}, {.Minus, {.Alt}}, {.Minus, {.Control}}, {}}, count = 3},
	}), commands.Error.None)
	for char, i in unshifted {
		key := input.Key(int(input.Key.Digit_0)+i)
		testing.expect_value(t, commands.logical_key(key, char), key)
		binding := commands.Shortcut{key, {.Alt}}
		testing.expect_value(t, commands.set_shortcuts(&registry, 1, []commands.Shortcut{binding}), commands.Error.None)
		testing.expect_value(t, commands.find_by_key(&registry, key, {.Alt}, char).id, commands.Command_Id(1))
		testing.expect_value(t, commands.find_by_key(&registry, key, {.Control}, char), nil)
		testing.expect(t, !commands.shortcut_matches(binding, key, {.Alt, .Shift}, char))
	}
}

@(test)
physical_shortcuts_round_trip_and_unbind_preserves_alternates :: proc(t: ^testing.T) {
	shortcut, parsed := commands.parse_shortcut("Ctrl+Physical+Z")
	testing.expect(t, parsed)
	testing.expect_value(t, shortcut, commands.Shortcut{.Z, {.Control, .Physical}})
	buffer: [128]u8
	label, label_error := commands.shortcut_label(shortcut, buffer[:])
	testing.expect_value(t, label_error, commands.Error.None)
	testing.expect_value(t, label, "Physical+Ctrl+Z")
	again, round_trip := commands.parse_shortcut(label)
	testing.expect(t, round_trip)
	testing.expect_value(t, again, shortcut)
	_, duplicate := commands.parse_shortcut("Physical+Physical+Z")
	testing.expect(t, !duplicate)
	registry := commands.create()
	defer commands.destroy(&registry)
	testing.expect_value(t, commands.register(&registry, {
		id = 1, name = "alternate", title = "Alternate",
		shortcuts = {items = {shortcut, {.T, {.Control}}, {}, {}}, count = 2},
	}), commands.Error.None)
	testing.expect(t, commands.unbind(&registry, 1, shortcut))
	testing.expect_value(t, commands.find(&registry, commands.Command_Id(1)).shortcuts.count, 1)
	testing.expect_value(t, commands.find_by_shortcut(&registry, {.T, {.Control}}).id, commands.Command_Id(1))
	testing.expect_value(t, commands.find_by_shortcut(&registry, shortcut), nil)
	testing.expect(t, !commands.unbind(&registry, 1, shortcut))
	testing.expect(t, !commands.unbind(&registry, 2, shortcut))
}
