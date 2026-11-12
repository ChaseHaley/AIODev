package ui_test

import "aio:commands"
import "aio:input"
import "aio:ui"
import "core:testing"

// Find, Show Command Palette and Copy with their default shortcuts, and New Tab, as a surface lists them.
@(private = "file")
chain_book :: proc() -> []ui.Shortcut_Command {
	@(static, rodata) find := [?]commands.Shortcut{{.F, {.Control, .Shift}}}
	@(static, rodata) palette := [?]commands.Shortcut{{.P, {.Control, .Shift}}}
	@(static, rodata) copy := [?]commands.Shortcut{{.C, {.Control, .Shift}}, {.Insert, {.Control}}}
	@(static, rodata) new_tab := [?]commands.Shortcut{{.T, {.Control, .Shift}}}
	book := make([]ui.Shortcut_Command, 4, context.temp_allocator)
	book[0] = {"keys.terminal.find", "Find", find[:]}
	book[1] = {"keys.app.command_palette", "Show Command Palette", palette[:]}
	book[2] = {"keys.edit.copy", "Copy", copy[:]}
	book[3] = {"keys.tab.new", "New Tab", new_tab[:]}
	return book
}

// Records `chord` into a field whose saved shortcuts are `saved`, as Find's row does, and checks it
// against `book` the way the surfaces do after each key.
@(private = "file")
chain_record :: proc(
	c: ^ui.Shortcut_Capture,
	draft: ^ui.Text_Field,
	saved: string,
	key: string,
	book: []ui.Shortcut_Command,
	chord: input.Key,
	modifiers: input.Modifiers,
) {
	ui.field_set(draft, saved)
	ui.shortcut_capture_start(c, 0)
	ui.shortcut_capture_key(c, draft, saved, .Alternatives, press(chord, modifiers), 0)
	ui.shortcut_capture_check(c, book, key)
}

// Find applies Ctrl+Shift+P: a chain on Find and Show Command Palette.
@(private = "file")
chain_find_takes_palette :: proc(t: ^testing.T, chain: ^ui.Shortcut_Chain) -> bool {
	c: ui.Shortcut_Capture
	draft: ui.Text_Field
	defer delete(draft.bytes)
	book := chain_book()
	chain_record(&c, &draft, "Ctrl+Shift+F", "keys.terminal.find", book, .P, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_capture_used_by(&c), "Used by Show Command Palette")
	err := ui.shortcut_chain_open(chain, book, "keys.terminal.find", ui.field_string(&draft), &c)
	if !testing.expect_value(t, err, nil) {return false}
	return testing.expect_value(t, len(chain.members), 2)
}

@(private = "file")
chain_key :: proc(chain: ^ui.Shortcut_Chain, key: input.Key, modifiers: input.Modifiers = {}) -> ui.Chain_Outcome {
	return ui.shortcut_chain_key(chain, press(key, modifiers))
}

@(private = "file")
chain_change :: proc(chain: ^ui.Shortcut_Chain, key: string) -> (value: string, changed: bool) {
	for change in ui.shortcut_chain_changes(chain) {if change.key == key {return change.value, true}}
	return "", false
}

@(test)
capture_names_every_other_command_holding_the_recorded_chord :: proc(t: ^testing.T) {
	c: ui.Shortcut_Capture
	draft: ui.Text_Field
	defer delete(draft.bytes)
	book := chain_book()
	chain_record(&c, &draft, "Ctrl+Shift+F", "keys.terminal.find", book, .K, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_capture_used_by(&c), "")
	chain_record(&c, &draft, "Ctrl+Shift+F", "keys.terminal.find", book, .F, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_capture_used_by(&c), "")
	shared := []ui.Shortcut_Command{book[0], book[1], {"keys.tab.close", "Close Tab", book[1].shortcuts}}
	chain_record(&c, &draft, "Ctrl+Shift+F", "keys.terminal.find", shared, .P, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_capture_used_by(&c), "Used by Show Command Palette, Close Tab")
	// Backspace removes the alternative, which leaves nothing recorded to clash.
	ui.shortcut_capture_key(&c, &draft, "Ctrl+Shift+F", .Alternatives, press(.Backspace), 0)
	testing.expect_value(t, ui.shortcut_capture_used_by(&c), "")
}

// The owner's example: Find takes Ctrl+Shift+P, Show Command Palette then takes Copy's Ctrl+Shift+C,
// and removing Copy's Ctrl+Shift+C resolves the whole chain.
@(test)
chain_appends_each_owner_and_resolves_when_no_chord_is_held_twice :: proc(t: ^testing.T) {
	chain: ui.Shortcut_Chain
	defer ui.shortcut_chain_destroy(&chain)
	if !chain_find_takes_palette(t, &chain) {return}
	testing.expect_value(t, ui.shortcut_chain_member_key(&chain, 1), "keys.app.command_palette")
	testing.expect_value(t, ui.shortcut_chain_context(&chain), "Ctrl+Shift+P is used twice. Change one to save.")
	find := chain.chips[chain.members[0].first]
	testing.expect(t, find.contested && find.pending, "Find's new chord is contested and not saved yet")
	palette := chain.chips[chain.members[1].first]
	testing.expect(t, palette.contested && !palette.pending, "the palette's saved chord is contested")

	testing.expect_value(t, chain_key(&chain, .Arrow_Down), ui.Chain_Outcome.Changed)
	testing.expect_value(t, chain_key(&chain, .Enter), ui.Chain_Outcome.Changed)
	testing.expect(t, ui.shortcut_chain_recording(&chain))
	chain_key(&chain, .C, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_chain_used_by(&chain), "Used by Copy")
	testing.expect_value(t, len(chain.members), 2)
	testing.expect_value(t, chain_key(&chain, .Enter), ui.Chain_Outcome.Changed)
	if !testing.expect_value(t, len(chain.members), 3) {return}
	testing.expect_value(t, ui.shortcut_chain_member_key(&chain, 2), "keys.edit.copy")
	testing.expect_value(t, chain.appended, 2)
	testing.expect_value(t, ui.shortcut_chain_context(&chain), "Ctrl+Shift+C is used twice. Change one to save.")
	copy_first := chain.chips[chain.members[2].first]
	copy_second := chain.chips[chain.members[2].first + 1]
	testing.expect(t, copy_first.contested && !copy_second.contested, "Copy keeps Ctrl+Insert unmarked")

	hit := ui.Chain_Hit{member = 2, chip = 0, part = .Remove}
	testing.expect_value(t, ui.shortcut_chain_press(&chain, hit), ui.Chain_Outcome.Resolved)
	find_value, find_changed := chain_change(&chain, "keys.terminal.find")
	testing.expect(t, find_changed && find_value == "Ctrl+Shift+P", find_value)
	palette_value, palette_changed := chain_change(&chain, "keys.app.command_palette")
	testing.expect(t, palette_changed && palette_value == "Ctrl+Shift+C", palette_value)
	copy_value, copy_changed := chain_change(&chain, "keys.edit.copy")
	testing.expect(t, copy_changed && copy_value == "Ctrl+Insert", copy_value)
	testing.expect_value(t, len(ui.shortcut_chain_changes(&chain)), 3)
}

// Clashes count against the drafts, so giving the palette Find's old chord resolves the chain.
@(test)
chain_resolves_a_swap :: proc(t: ^testing.T) {
	chain: ui.Shortcut_Chain
	defer ui.shortcut_chain_destroy(&chain)
	if !chain_find_takes_palette(t, &chain) {return}
	ui.shortcut_chain_record(&chain, 1, 0)
	chain_key(&chain, .F, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_chain_used_by(&chain), "", "Find no longer holds Ctrl+Shift+F")
	testing.expect_value(t, chain_key(&chain, .Enter), ui.Chain_Outcome.Resolved)
	testing.expect_value(t, len(chain.members), 2)
	find_value, _ := chain_change(&chain, "keys.terminal.find")
	palette_value, _ := chain_change(&chain, "keys.app.command_palette")
	testing.expect_value(t, find_value, "Ctrl+Shift+P")
	testing.expect_value(t, palette_value, "Ctrl+Shift+F")
}

// Escape while a chip records cancels only that recording; the next Escape drops the chain.
@(test)
chain_escape_cancels_the_recording_before_the_chain :: proc(t: ^testing.T) {
	chain: ui.Shortcut_Chain
	defer ui.shortcut_chain_destroy(&chain)
	if !chain_find_takes_palette(t, &chain) {return}
	ui.shortcut_chain_record(&chain, 1, 0)
	chain_key(&chain, .K, {.Control, .Shift})
	testing.expect_value(t, chain_key(&chain, .Escape), ui.Chain_Outcome.Changed)
	testing.expect(t, !ui.shortcut_chain_recording(&chain))
	testing.expect_value(t, chain.members[1].draft, "Ctrl+Shift+P")
	testing.expect_value(t, ui.shortcut_chain_context(&chain), "Ctrl+Shift+P is used twice. Change one to save.")
	testing.expect_value(t, chain_key(&chain, .Escape), ui.Chain_Outcome.Cancelled)
}

// A chord a member already holds is only marked, and the line counts every holder; two chords held
// twice at once are named as two clashes.
@(test)
chain_marks_chords_held_inside_it_and_counts_clashes :: proc(t: ^testing.T) {
	chain: ui.Shortcut_Chain
	defer ui.shortcut_chain_destroy(&chain)
	if !chain_find_takes_palette(t, &chain) {return}
	// New Tab is outside the chain: recording its chord on Find's + chip appends it.
	ui.shortcut_chain_press(&chain, {member = 0, part = .Add})
	chain_key(&chain, .T, {.Control, .Shift})
	testing.expect_value(t, chain_key(&chain, .Enter), ui.Chain_Outcome.Changed)
	testing.expect_value(t, len(chain.members), 3)
	testing.expect_value(t, ui.shortcut_chain_context(&chain), "2 shortcuts clash. Change one of each to save.")
	// The palette takes New Tab's chord too: held inside the chain, so nothing is appended.
	ui.shortcut_chain_record(&chain, 1, 1)
	chain_key(&chain, .T, {.Control, .Shift})
	testing.expect_value(t, ui.shortcut_chain_used_by(&chain), "Used by Find, New Tab")
	chain_key(&chain, .Enter)
	testing.expect_value(t, len(chain.members), 3)
	// Remove Find's and the palette's Ctrl+Shift+P: only Ctrl+Shift+T remains, held three times.
	ui.shortcut_chain_press(&chain, {member = 0, chip = 0, part = .Remove})
	ui.shortcut_chain_press(&chain, {member = 1, chip = 0, part = .Remove})
	testing.expect_value(t, ui.shortcut_chain_context(&chain), "Ctrl+Shift+T is used 3 times. Keep one to save.")
	// Delete removes the selected row's contested chip; two removals leave one holder.
	chain.selected = 0
	testing.expect_value(t, chain_key(&chain, .Delete), ui.Chain_Outcome.Changed)
	chain.selected = 1
	testing.expect_value(t, chain_key(&chain, .Delete), ui.Chain_Outcome.Resolved)
}
