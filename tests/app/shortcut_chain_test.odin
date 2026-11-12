package app_test

import app "../../src"
import "aio:commands"
import "aio:input"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"

@(private = "file")
chain_keys :: proc(s: ^app.App, keys: ..input.Key_Event) {
	for key in keys {palette_binding_press_key(s, key)}
}

@(private = "file")
chain_file :: proc(t: ^testing.T, f: ^Palette_Fixture) -> string {
	data, err := os.read_entire_file(f.path, context.temp_allocator)
	testing.expect_value(t, err, nil)
	return string(data)
}

// The owner's example ends with these three lines in the file.
@(private = "file")
chain_expect_saved :: proc(t: ^testing.T, s: ^app.App, text: string) {
	testing.expect(t, strings.contains(text, "keys.terminal.find = Ctrl+Shift+P"), text)
	testing.expect(t, strings.contains(text, "keys.app.command_palette = Ctrl+Shift+C"), text)
	testing.expect(t, strings.contains(text, "keys.edit.copy = Ctrl+Insert"), text)
	find := commands.find_by_shortcut(&s.registry, {.P, {.Control, .Shift}})
	if testing.expect(t, find != nil) {testing.expect_value(t, find.name, "terminal.find")}
	palette := commands.find_by_shortcut(&s.registry, {.C, {.Control, .Shift}})
	if testing.expect(t, palette != nil) {testing.expect_value(t, palette.name, "app.command_palette")}
	saved := ui.notices_live(&s.notices)
	testing.expect(t, len(saved) > 0 && saved[len(saved) - 1].text == "Saved" && saved[len(saved) - 1].action == "Undo")
}

// Find takes Ctrl+Shift+P, Show Command Palette then takes Copy's Ctrl+Shift+C, and removing Copy's
// Ctrl+Shift+C saves all three in one write; Ctrl+Z puts the file back in one write.
@(test)
settings_conflict_chain_saves_the_owners_example_and_undoes_it_as_one_write :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "chain-settings", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	p := &w.editor
	app.handle_event(s, input.Text_Event{w.id, "keys.terminal.find"})
	if !testing.expect_value(t, ui.editor_row(p).key, "keys.terminal.find") {return}
	before := chain_file(t, &f)
	chain_keys(s, {key = .Enter}, {key = .Enter}, {key = .P, modifiers = {.Control, .Shift}})
	testing.expect_value(t, ui.shortcut_capture_used_by(&p.capture), "Used by Show Command Palette")
	testing.expect(t, !ui.editor_chained(p), "recording only notes the clash")
	chain_keys(s, {key = .Enter})
	if !testing.expect(t, ui.editor_chained(p)) {return}
	testing.expect_value(t, len(p.chain.members), 2)
	testing.expect_value(t, ui.shortcut_chain_context(&p.chain), "Ctrl+Shift+P is used twice. Change one to save.")
	chain_keys(s, {key = .Arrow_Down}, {key = .Enter}, {key = .C, modifiers = {.Control, .Shift}})
	testing.expect_value(t, ui.shortcut_chain_used_by(&p.chain), "Used by Copy")
	chain_keys(s, {key = .Enter})
	if !testing.expect_value(t, len(p.chain.members), 3) {return}
	testing.expect_value(t, ui.shortcut_chain_member_key(&p.chain, 2), "keys.edit.copy")
	testing.expect_value(t, chain_file(t, &f), before)
	chain_keys(s, {key = .Arrow_Down}, {key = .Delete})
	testing.expect(t, !ui.editor_chained(p), "a resolved chain saves and closes")
	saved := chain_file(t, &f)
	chain_expect_saved(t, s, saved)
	testing.expect_value(t, ui.field_string(&p.filter), "keys.terminal.find")
	testing.expect_value(t, ui.editor_row(p).key, "keys.terminal.find")
	chain_keys(s, {key = .Z, modifiers = {.Control}})
	testing.expect_value(t, chain_file(t, &f), before)
	find := commands.find_by_shortcut(&s.registry, {.F, {.Control, .Shift}})
	if testing.expect(t, find != nil) {testing.expect_value(t, find.name, "terminal.find")}
}

@(test)
palette_conflict_chain_saves_the_owners_example_and_undoes_it_as_one_write :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "chain-palette", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	p := &s.palette
	app.palette_open_mode(s, w, .Commands)
	ui.palette_text(p, &s.registry, "Find")
	find := -1
	for result, i in p.results {if ui.palette_result_name(p, result) == "terminal.find" {find = i}}
	if !testing.expect(t, find >= 0) {return}
	p.selected = find
	before := chain_file(t, &f)
	chain_keys(s, {key = .Enter, modifiers = {.Control}}, {key = .Enter}, {key = .P, modifiers = {.Control, .Shift}})
	testing.expect_value(t, ui.palette_used_by(p), "Used by Show Command Palette")
	chain_keys(s, {key = .Enter})
	if !testing.expect_value(t, ui.palette_editing(p), ui.Palette_Edit_Kind.Chain) {return}
	testing.expect_value(t, len(p.results), 2)
	chain_keys(s, {key = .Arrow_Down}, {key = .Enter}, {key = .C, modifiers = {.Control, .Shift}}, {key = .Enter})
	testing.expect_value(t, len(p.results), 3)
	testing.expect_value(t, chain_file(t, &f), before)
	chain_keys(s, {key = .Arrow_Down}, {key = .Delete})
	testing.expect_value(t, ui.palette_editing(p), ui.Palette_Edit_Kind.None)
	chain_expect_saved(t, s, chain_file(t, &f))
	testing.expect_value(t, ui.palette_query(p), "Find")
	testing.expect_value(t, p.selected, find)
	testing.expect(t, app.palette_active(s, w))
	chain_keys(s, {key = .Z, modifiers = {.Control}})
	testing.expect_value(t, chain_file(t, &f), before)
}

// A file changed outside the app while a chain is open makes its save a conflict: the file keeps the
// outside edit, the page falls behind it, and the chain stays open with its work.
@(test)
settings_conflict_chain_never_overwrites_an_outside_edit :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "chain-stale", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	p := &w.editor
	app.handle_event(s, input.Text_Event{w.id, "keys.terminal.find"})
	chain_keys(s, {key = .Enter}, {key = .Enter}, {key = .P, modifiers = {.Control, .Shift}}, {key = .Enter})
	if !testing.expect(t, ui.editor_chained(p)) {return}
	outside := strings.concatenate({chain_file(t, &f), "# outside edit\n"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(f.path, transmute([]u8)outside), nil)
	chain_keys(s, {key = .Arrow_Down}, {key = .Delete})
	testing.expect_value(t, chain_file(t, &f), outside)
	testing.expect(t, ui.editor_chained(p), "the chain keeps its work")
	_, stale := p.revision.(ui.Editor_Stale)
	testing.expect(t, stale)
}
