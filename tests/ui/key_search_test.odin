package ui_test

import "aio:commands"
import "aio:input"
import "aio:ui"
import "core:testing"

@(private = "file")
LEADER :: commands.Shortcut{.Space, {.Control}}

// Commands shaped like the defaults the search must tell apart: two Ctrl+Shift letters, a digit, a leader
// alternative, a key-position binding, and a title that fuzzily matches `cs c`.
@(private = "file")
search_registry :: proc(t: ^testing.T) -> commands.Registry {
	parse :: proc(text: string) -> commands.Shortcut {
		shortcut, ok := commands.parse_shortcut(text)
		assert(ok)
		return shortcut
	}
	r := commands.create()
	items := [?]commands.Command {
		{id = 1, name = "terminal.find", title = "Find", shortcuts = {{0 = parse("Ctrl+Shift+F")}, 1}},
		{id = 2, name = "edit.copy", title = "Copy", shortcuts = {{0 = parse("Ctrl+Shift+C"), 1 = parse("Ctrl+Insert")}, 2}},
		{id = 3, name = "tab.select_8", title = "Select Tab 8", shortcuts = {{0 = parse("Alt+8")}, 1}},
		{id = 4, name = "pane.focus_left", title = "Focus Left",
			shortcuts = {{0 = parse("Ctrl+Alt+Left"), 1 = parse("Leader+H")}, 2}},
		{id = 5, name = "status.panel", title = "Show or Hide the Activity Panel",
			shortcuts = {{0 = parse("Physical+Ctrl+Shift+Y")}, 1}},
		{id = 6, name = "tab.close", title = "Close Selected Tabs"},
	}
	for item in items {testing.expect_value(t, commands.register(&r, item), commands.Error.None)}
	return r
}

@(private = "file")
down :: proc(key: input.Key, modifiers: input.Modifiers = {}, unshifted: rune = 0) -> input.Key_Event {
	return {key = key, modifiers = modifiers, pressed = true, unshifted = unshifted}
}

@(private = "file")
names :: proc(p: ^ui.Palette) -> []string {
	out := make([]string, len(p.results), context.temp_allocator)
	for result, i in p.results {out[i] = ui.palette_result_name(p, result)}
	return out
}

@(test)
palette_matches_shortcut_text_and_keeps_titles_first :: proc(t: ^testing.T) {
	r := search_registry(t)
	defer commands.destroy(&r)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	p.leader = LEADER
	for mode in ([?]ui.Palette_Mode{.All, .Commands}) {
		ui.palette_open_mode(&p, &r, mode)
		p.leader = LEADER
		for query in ([?]string{"alt8", "al8", "alt+8"}) {
			ui.field_set(&p.query, "")
			ui.palette_text(&p, &r, query)
			if !testing.expect(t, len(p.results) > 0) {continue}
			testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "tab.select_8")
			hit := p.results[0].shortcut.hit
			testing.expectf(t, hit.key && hit.modifiers == {.Alt}, "%q lights both keycaps", query)
		}
		ui.field_set(&p.query, "")
		ui.palette_text(&p, &r, "find")
		testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "terminal.find")
		testing.expect(t, p.results[0].title_match)
		// The chord outranks a title that only holds the letters in order.
		ui.field_set(&p.query, "")
		ui.palette_text(&p, &r, "cs c")
		got := names(&p)
		testing.expect_value(t, got[0], "edit.copy")
		testing.expect_value(t, p.results[0].shortcut.hit.match, commands.Shortcut_Match.Exact)
		ui.field_set(&p.query, "")
		ui.palette_text(&p, &r, "leader h")
		testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "pane.focus_left")
		testing.expect_value(t, p.results[0].shortcut.alternative, 1)
		ui.field_set(&p.query, "")
		ui.palette_text(&p, &r, "ctrl+insert")
		testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "edit.copy")
		testing.expect_value(t, p.results[0].shortcut.alternative, 1)
	}
}

@(test)
palette_offers_an_unassigned_chord_to_a_chosen_command :: proc(t: ^testing.T) {
	r := search_registry(t)
	defer commands.destroy(&r)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &r, .All)
	ui.palette_text(&p, &r, "ctrl+shift+g")
	if !testing.expect(t, len(p.results) > 0) {return}
	testing.expect_value(t, p.results[0].kind, ui.Palette_Kind.Unassigned)
	testing.expect_value(t, p.results[0].chord, commands.Shortcut{.G, {.Control, .Shift}})
	// Used chords, by key name or position, and the leader are not offered.
	p.leader = LEADER
	for query in ([?]string{"ctrl+shift+c", "ctrl shift y", "ctrl space", "shift g"}) {
		ui.field_set(&p.query, "")
		ui.palette_text(&p, &r, query)
		for result in p.results {testing.expectf(t, result.kind != .Unassigned, "%q is not free", query)}
	}
	ui.field_set(&p.query, "")
	ui.palette_text(&p, &r, "ctrl+shift+g")
	outcome, _ := ui.palette_key(&p, &r, down(.Enter))
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, p.mode, ui.Palette_Mode.Commands)
	testing.expect_value(t, ui.palette_query(&p), "")
	testing.expect(t, p.assign != nil)
	ui.palette_text(&p, &r, "find")
	ui.palette_key(&p, &r, down(.Enter))
	if !testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Shortcut) {return}
	outcome, _ = ui.palette_key(&p, &r, down(.Enter))
	key, value := chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, key, "keys.terminal.find")
	testing.expect_value(t, value, "Ctrl+Shift+F, Ctrl+Shift+G")
}

@(test)
palette_records_chords_held_modifiers_leader_and_positions :: proc(t: ^testing.T) {
	r := search_registry(t)
	defer commands.destroy(&r)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	ui.palette_open_mode(&p, &r, .Tabs)
	p.leader = LEADER
	ui.palette_text(&p, &r, "find")
	ui.palette_key(&p, &r, down(.K, {.Alt}, 'k'))
	testing.expect(t, ui.palette_recording(&p))
	testing.expect_value(t, p.mode, ui.Palette_Mode.Commands)
	testing.expect_value(t, len(p.results), 0)
	// Ctrl+Shift+C is Copy's own chord and a clipboard chord; recording takes it as the query.
	ui.palette_key(&p, &r, down(.C, {.Control, .Shift}, 'c'))
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Recorded)
	got := names(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "edit.copy")}
	// Typing over recorded keys starts a text search; while recording, typing is ignored.
	ui.palette_text(&p, &r, "c")
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
	testing.expect_value(t, ui.palette_query(&p), "c")
	ui.palette_key(&p, &r, down(.K, {.Alt}, 'k'))
	testing.expect_value(t, ui.palette_text(&p, &r, "x"), ui.Outcome.None)
	testing.expect_value(t, ui.palette_query(&p), "c")
	ui.palette_key(&p, &r, down(.C, {.Control, .Shift}, 'c'))
	ui.palette_key(&p, &r, down(.Escape))
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
	testing.expect_value(t, ui.palette_query(&p), "Ctrl+Shift+C")
	testing.expect_value(t, names(&p)[0], "edit.copy")

	ui.palette_key(&p, &r, down(.K, {.Alt}, 'k'))
	ui.palette_key(&p, &r, down(.Control_Left, {.Control}))
	ui.palette_key(&p, &r, down(.Shift_Left, {.Control, .Shift}))
	testing.expect(t, ui.palette_recording(&p))
	testing.expect_value(t, len(p.results), 3)
	ui.palette_key(&p, &r, down(.Space, {.Control}, ' '))
	got = names(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "pane.focus_left")}
	ui.palette_key(&p, &r, down(.H, {}, 'h'))
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Recorded)
	got = names(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "pane.focus_left")}
	testing.expect_value(t, p.results[0].shortcut.alternative, 1)

	// Backspace records again; the Y position matches its Physical binding whatever the layout types.
	ui.palette_key(&p, &r, down(.Backspace))
	testing.expect(t, ui.palette_recording(&p))
	ui.palette_key(&p, &r, down(.Y, {.Control, .Shift}, 'z'))
	got = names(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "status.panel")}

	// A free recorded chord is offered too, and the button leaves record mode.
	ui.palette_key(&p, &r, down(.Backspace))
	ui.palette_key(&p, &r, down(.G, {.Control, .Shift}, 'g'))
	if testing.expect(t, len(p.results) > 0) {
		testing.expect_value(t, p.results[0].kind, ui.Palette_Kind.Unassigned)
	}
	l := ui.palette_layout(&p, 1000, 800, 1)
	testing.expect(t, l.keys.width > 0)
	outcome, _ := ui.palette_mouse_press(&p, &r, l, l.keys.x + l.keys.width / 2, l.keys.y + l.keys.height / 2)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
	testing.expect_value(t, ui.palette_query(&p), "Ctrl+Shift+G")
	ui.palette_close(&p)
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
}

@(private = "file")
search_editor :: proc(t: ^testing.T, p: ^ui.Editor) {
	rows := [?]struct {
		row:   ui.Editor_Row,
		group: string,
	} {
		{{key = "input.leader", title = "Leader Key", value = "Ctrl+Space", kind = .Shortcut,
			shortcut_mode = .Single}, "Input"},
		{{key = "keys.terminal.find", title = "Find", value = "Ctrl+Shift+F", kind = .Shortcut},
			"Terminal Shortcuts"},
		{{key = "keys.edit.copy", title = "Copy", value = "Ctrl+Shift+C, Ctrl+Insert", kind = .Shortcut},
			"Edit Shortcuts"},
		{{key = "keys.tab.close", title = "Close Selected Tabs", value = "", kind = .Shortcut}, "Tab Shortcuts"},
		{{key = "keys.pane.focus_left", title = "Focus Left", value = "Ctrl+Alt+Left, Leader+H",
			kind = .Shortcut}, "Pane Shortcuts"},
		{{key = "keys.status.panel", title = "Activity Panel", value = "Physical+Ctrl+Shift+Y",
			kind = .Shortcut}, "Status Shortcuts"},
	}
	for r in rows {testing.expect_value(t, ui.editor_add(p, r.row, r.group), nil)}
	p.capture.leader = LEADER
	ui.editor_filter(p)
}

@(private = "file")
editor_keys :: proc(p: ^ui.Editor) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for item in p.items {if item.row >= 0 {append(&out, p.rows[item.row].key)}}
	return out[:]
}

@(test)
settings_search_shares_the_shortcut_grammar_and_offers_free_chords :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	search_editor(t, &p)
	ui.editor_text(&p, "cs c")
	got := editor_keys(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "keys.edit.copy")}
	item := p.items[p.selected]
	testing.expect(t, item.shortcut.hit.modifiers == {.Control, .Shift} && item.shortcut.hit.key)
	ui.field_set(&p.filter, "")
	ui.editor_text(&p, "ctrl insert")
	testing.expect_value(t, p.items[p.selected].shortcut.alternative, 1)
	ui.field_set(&p.filter, "")
	ui.editor_text(&p, "ctrl shift g")
	testing.expect_value(t, len(p.items), 0)
	free, offered := ui.editor_free_chord(&p).?
	testing.expect(t, offered && free == commands.Shortcut{.G, {.Control, .Shift}})
	testing.expect_value(t, ui.editor_key(&p, down(.Enter)), ui.Editor_Outcome.Assign_Shortcut)
	ui.field_set(&p.filter, "")
	ui.editor_text(&p, "ctrl shift y")
	testing.expect_value(t, len(editor_keys(&p)), 1)
	testing.expect(t, ui.editor_free_chord(&p) == nil)
}

@(test)
settings_search_records_keys_and_returns_to_text :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	search_editor(t, &p)
	ui.editor_text(&p, "focus")
	ui.editor_key(&p, down(.K, {.Alt}, 'k'))
	testing.expect(t, ui.editor_recording(&p))
	testing.expect_value(t, len(p.items), 0)
	ui.editor_key(&p, down(.C, {.Control, .Shift}, 'c'))
	got := editor_keys(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "keys.edit.copy")}
	ui.editor_key(&p, down(.Escape))
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
	testing.expect_value(t, ui.field_string(&p.filter), "Ctrl+Shift+C")
	testing.expect_value(t, editor_keys(&p)[0], "keys.edit.copy")

	// Nothing recorded: Esc keeps the text typed before.
	ui.editor_key(&p, down(.K, {.Alt}, 'k'))
	ui.editor_key(&p, down(.Escape))
	testing.expect_value(t, ui.field_string(&p.filter), "Ctrl+Shift+C")

	// The leader lists its sequences and the leader's own row; its key narrows them.
	ui.editor_key(&p, down(.K, {.Alt}, 'k'))
	ui.editor_key(&p, down(.Space, {.Control}, ' '))
	got = editor_keys(&p)
	if testing.expect_value(t, len(got), 2) {
		testing.expect_value(t, got[0], "input.leader")
		testing.expect_value(t, got[1], "keys.pane.focus_left")
	}
	ui.editor_key(&p, down(.H, {}, 'h'))
	got = editor_keys(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "keys.pane.focus_left")}
	testing.expect_value(t, p.items[p.selected].shortcut.alternative, 1)

	// Leaving the field keeps the rows: the recorded keys become the typed query.
	ui.editor_key(&p, down(.Tab))
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
	testing.expect_value(t, ui.field_string(&p.filter), "Leader+H")
	testing.expect_value(t, ui.editor_row(&p).key, "keys.pane.focus_left")

	// Physical bindings match by position; held modifiers list the chords under them.
	ui.editor_browse(&p)
	ui.editor_key(&p, down(.K, {.Alt}, 'k'))
	ui.editor_key(&p, down(.Y, {.Control, .Shift}, 'z'))
	got = editor_keys(&p)
	if testing.expect_value(t, len(got), 1) {testing.expect_value(t, got[0], "keys.status.panel")}
	ui.editor_key(&p, down(.Backspace))
	ui.editor_key(&p, down(.Control_Left, {.Control}))
	ui.editor_key(&p, down(.Shift_Left, {.Control, .Shift}))
	testing.expect_value(t, len(editor_keys(&p)), 3)
	// Typing over recorded keys starts a new text search.
	ui.editor_key(&p, down(.F, {.Control, .Shift}, 'f'))
	ui.editor_text(&p, "copy")
	testing.expect_value(t, p.keys.state, ui.Key_Search_State.Off)
	testing.expect_value(t, ui.field_string(&p.filter), "copy")
}

@(private = "file")
copy_unavailable :: proc(_: rawptr, id: commands.Command_Id) -> bool {return id != 2}

@(test)
palette_lists_unavailable_commands_only_for_their_shortcut :: proc(t: ^testing.T) {
	r := search_registry(t)
	defer commands.destroy(&r)
	p: ui.Palette
	testing.expect_value(t, ui.palette_init(&p, nil), nil)
	defer ui.palette_destroy(&p)
	ui.palette_set_availability(&p, {available = copy_unavailable})
	ui.palette_open_mode(&p, &r, .Commands)
	ui.palette_text(&p, &r, "copy")
	for result in p.results {testing.expect(t, ui.palette_result_name(&p, result) != "edit.copy")}
	ui.field_set(&p.query, "")
	ui.palette_text(&p, &r, "ctrl+shift+c")
	if !testing.expect(t, len(p.results) > 0) {return}
	testing.expect_value(t, ui.palette_result_name(&p, p.results[0]), "edit.copy")
	testing.expect(t, p.results[0].unavailable)
	outcome, _ := ui.palette_key(&p, &r, down(.Enter))
	testing.expect_value(t, outcome, ui.Outcome.None)
	testing.expect(t, ui.presence_is_open(p.presence))
}
