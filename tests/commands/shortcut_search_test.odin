package commands_test

import "aio:commands"
import "aio:input"
import "core:testing"

@(private = "file")
query_hit :: proc(text, label: string) -> commands.Shortcut_Hit {
	q := commands.shortcut_query(text)
	shortcut, ok := commands.parse_shortcut(label)
	assert(ok)
	return commands.shortcut_query_match(&q, shortcut)
}

@(test)
shortcut_query_reads_the_typed_grammar :: proc(t: ^testing.T) {
	cases := [?]struct {
		text:      string,
		modifiers: input.Modifiers,
		key:       input.Key,
		keyed:     bool,
	} {
		{"ctrl+shift+c", {.Control, .Shift}, .C, true},
		{"Ctrl+Shift+C", {.Control, .Shift}, .C, true},
		{"cs c", {.Control, .Shift}, .C, true},
		{"alt8", {.Alt}, .Digit_8, true},
		{"ctrlshiftc", {.Control, .Shift}, .C, true},
		{"leader h", {.Leader}, .H, true},
		{"control pgup", {.Control}, .Page_Up, true},
		{"ctrl+num+", {.Control}, .Numpad_Add, true},
		{"ctrl num 0", {.Control}, .Numpad_0, true},
		{"ctrl+,", {.Control}, .Comma, true},
		{"shift arrowleft", {.Shift}, .Arrow_Left, true},
		{"f11", {}, .F11, true},
		{"ctrl shift", {.Control, .Shift}, {}, false},
		{"leader", {.Leader}, {}, false},
		{"ctrl+", {.Control}, {}, false},
	}
	for c in cases {
		q := commands.shortcut_query(c.text)
		testing.expectf(t, q.chord, "%q reads as a chord", c.text)
		testing.expectf(t, q.modifiers == c.modifiers, "%q modifiers %v", c.text, q.modifiers)
		testing.expect_value(t, q.keyed, c.keyed)
		if c.keyed {testing.expect_value(t, q.key, c.key)}
	}
	for text in ([?]string{"", "c", "8", "al8", "find", "close tab", "all tabs", "sltb8", "ctrl zz"}) {
		q := commands.shortcut_query(text)
		testing.expectf(t, !q.chord, "%q is text, not a chord", text)
	}
}

@(test)
shortcut_query_matches_exact_partial_modifiers_and_label_letters :: proc(t: ^testing.T) {
	expect :: proc(t: ^testing.T, text, label: string, match: commands.Shortcut_Match, loc := #caller_location) {
		testing.expect_value(t, query_hit(text, label).match, match, loc)
	}
	expect(t, "ctrl+shift+c", "Ctrl+Shift+C", .Exact)
	expect(t, "cs c", "Ctrl+Shift+C", .Exact)
	expect(t, "ctrl c", "Ctrl+Shift+C", .Partial)
	expect(t, "ctrl c", "Ctrl+Insert", .None)
	expect(t, "alt8", "Alt+8", .Exact)
	expect(t, "alt8", "Ctrl+8", .None)
	expect(t, "leader h", "Leader+H", .Exact)
	expect(t, "leader h", "Ctrl+H", .None)
	expect(t, "ctrl shift", "Ctrl+Shift+C", .Modifiers)
	expect(t, "ctrl shift", "Ctrl+C", .None)
	// Grammar matches compare key names, so a binding by key position matches as well.
	expect(t, "ctrl shift y", "Physical+Ctrl+Shift+Y", .Exact)
	expect(t, "al8", "Alt+8", .Label)
	expect(t, "ctl8", "Ctrl+8", .Label)
	// Letters must start a part and reach the key through two parts, so words do not hit labels.
	expect(t, "find", "Ctrl+Shift+F", .None)
	expect(t, "copy", "Ctrl+Shift+C", .None)
	expect(t, "lt8", "Alt+8", .None)
	expect(t, "c", "Ctrl+C", .None)
	expect(t, "s8", "Ctrl+Shift+8", .Label)

	hit := query_hit("cs c", "Ctrl+Shift+C")
	testing.expect(t, hit.modifiers == {.Control, .Shift} && hit.key)
	hit = query_hit("ctrl shift", "Ctrl+Shift+Alt+K")
	testing.expect(t, hit.modifiers == {.Control, .Shift} && !hit.key)
	hit = query_hit("al8", "Alt+8")
	testing.expect(t, hit.modifiers == {.Alt} && hit.key)
}

@(test)
shortcut_hit_positions_light_the_matched_label_parts :: proc(t: ^testing.T) {
	out: [32]int
	positions := commands.shortcut_hit_positions("Ctrl+Shift+C", {.Partial, {.Control}, true}, out[:])
	testing.expect_value(t, len(positions), 5)
	for want, i in ([?]int{0, 1, 2, 3, 11}) {testing.expect_value(t, positions[i], want)}
	positions = commands.shortcut_hit_positions("Ctrl+Num+", {.Exact, {.Control}, true}, out[:])
	testing.expect_value(t, len(positions), 8)
	testing.expect_value(t, positions[len(positions) - 1], 8)
	positions = commands.shortcut_hit_positions("Leader+H", {.Modifiers, {.Leader}, false}, out[:])
	testing.expect_value(t, len(positions), 6)
	positions = commands.shortcut_hit_positions("Ctrl+K", {}, out[:])
	testing.expect_value(t, len(positions), 0)
}

@(private = "file")
press :: proc(key: input.Key, modifiers: input.Modifiers = {}, unshifted: rune = 0) -> input.Key_Event {
	return {key = key, modifiers = modifiers, pressed = true, unshifted = unshifted}
}

@(test)
key_press_records_held_modifiers_leader_sequences_and_chords :: proc(t: ^testing.T) {
	leader := commands.Shortcut{.Space, {.Control}}
	p: commands.Key_Press
	testing.expect(t, !commands.key_press_record(&p, press(.Control_Left, {.Control}), leader))
	testing.expect(t, !commands.key_press_record(&p, press(.Shift_Left, {.Control}), leader))
	testing.expect_value(t, p.state, commands.Key_Press_State.Held)
	testing.expect(t, p.modifiers == {.Control, .Shift})
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	testing.expect_value(t, commands.key_press_text(p, buffer[:]), "Ctrl+Shift")
	ctrl_shift_c, _ := commands.parse_shortcut("Ctrl+Shift+C")
	ctrl_c, _ := commands.parse_shortcut("Ctrl+C")
	testing.expect_value(t, commands.key_press_match(p, ctrl_shift_c).match, commands.Shortcut_Match.Modifiers)
	testing.expect_value(t, commands.key_press_match(p, ctrl_c).match, commands.Shortcut_Match.None)

	testing.expect(t, commands.key_press_record(&p, press(.C, {.Control, .Shift}, 'c'), leader))
	testing.expect_value(t, commands.key_press_match(p, ctrl_shift_c).match, commands.Shortcut_Match.Exact)
	testing.expect_value(t, commands.key_press_text(p, buffer[:]), "Ctrl+Shift+C")

	leader_h, _ := commands.parse_shortcut("Leader+H")
	leader_z, _ := commands.parse_shortcut("Leader+Z")
	testing.expect(t, !commands.key_press_record(&p, press(.Space, {.Control}, ' '), leader))
	testing.expect_value(t, p.state, commands.Key_Press_State.Leader)
	testing.expect_value(t, commands.key_press_text(p, buffer[:]), "Leader")
	testing.expect_value(t, commands.key_press_match(p, leader_h).match, commands.Shortcut_Match.Modifiers)
	testing.expect_value(t, commands.key_press_match(p, ctrl_c).match, commands.Shortcut_Match.None)
	// A modifier pressed after the leader keeps the sequence waiting for its key.
	testing.expect(t, !commands.key_press_record(&p, press(.Shift_Left, {.Shift}), leader))
	testing.expect(t, commands.key_press_record(&p, press(.H, {}, 'h'), leader))
	testing.expect_value(t, commands.key_press_match(p, leader_h).match, commands.Shortcut_Match.Exact)
	testing.expect_value(t, commands.key_press_match(p, leader_z).match, commands.Shortcut_Match.None)
	testing.expect_value(t, commands.key_press_text(p, buffer[:]), "Leader+H")
}

@(test)
key_press_matches_layout_and_position_bindings_as_dispatch_does :: proc(t: ^testing.T) {
	// The key in the Q position types 'a' on AZERTY.
	p: commands.Key_Press
	commands.key_press_record(&p, press(.Q, {.Control}, 'a'), nil)
	layout, _ := commands.parse_shortcut("Ctrl+A")
	position, _ := commands.parse_shortcut("Physical+Ctrl+Q")
	other, _ := commands.parse_shortcut("Ctrl+Q")
	testing.expect_value(t, commands.key_press_match(p, layout).match, commands.Shortcut_Match.Exact)
	testing.expect_value(t, commands.key_press_match(p, position).match, commands.Shortcut_Match.Exact)
	testing.expect_value(t, commands.key_press_match(p, other).match, commands.Shortcut_Match.None)
	// Digits keep their position on every layout (WORK-011).
	commands.key_press_record(&p, press(.Digit_8, {.Alt}, '_'), nil)
	alt8, _ := commands.parse_shortcut("Alt+8")
	testing.expect_value(t, commands.key_press_match(p, alt8).match, commands.Shortcut_Match.Exact)
	// A repeat changes nothing; Caps Lock is not a held modifier.
	repeat := press(.K, {.Control}, 'k')
	repeat.repeat = true
	testing.expect(t, !commands.key_press_record(&p, repeat, nil))
	testing.expect_value(t, commands.key_press_match(p, alt8).match, commands.Shortcut_Match.Exact)
	commands.key_press_record(&p, press(.Caps_Lock), nil)
	testing.expect_value(t, p.state, commands.Key_Press_State.Chord)
}

@(test)
free_chords_are_bindable_and_unused :: proc(t: ^testing.T) {
	r := commands.create()
	defer commands.destroy(&r)
	position, _ := commands.parse_shortcut("Physical+Ctrl+Shift+Y")
	testing.expect_value(t, commands.register(&r, {
		id = 1, name = "status.panel", title = "Panel", shortcuts = {{0 = position}, 1},
	}), commands.Error.None)
	leader := commands.Shortcut{.Space, {.Control}}
	q := commands.shortcut_query("ctrl shift g")
	chord, ok := commands.shortcut_query_chord(&q)
	testing.expect(t, ok && commands.shortcut_free(&r, chord, leader))
	q = commands.shortcut_query("ctrl shift y")
	chord, ok = commands.shortcut_query_chord(&q)
	testing.expect(t, ok && !commands.shortcut_free(&r, chord, leader))
	q = commands.shortcut_query("ctrl space")
	chord, ok = commands.shortcut_query_chord(&q)
	testing.expect(t, ok && !commands.shortcut_free(&r, chord, leader))
	for text in ([?]string{"shift g", "ctrl shift", "f11", "find"}) {
		q = commands.shortcut_query(text)
		_, ok = commands.shortcut_query_chord(&q)
		testing.expectf(t, !ok, "%q names no bindable chord", text)
	}
	p: commands.Key_Press
	commands.key_press_record(&p, press(.G, {.Shift}, 'g'), nil)
	_, ok = commands.key_press_chord(p)
	testing.expect(t, !ok)
	commands.key_press_record(&p, press(.G, {.Control, .Shift}, 'g'), nil)
	chord, ok = commands.key_press_chord(p)
	testing.expect(t, ok && chord == commands.Shortcut{.G, {.Control, .Shift}})
}
