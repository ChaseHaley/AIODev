package app_test

import "core:testing"
import app "../../src"
import "aio:settings"
import "aio:ui"

// A link program added on the Settings page takes its edits from its own rows, moves with
// Ctrl+Up and goes after a confirmation, each change reaching the file and the running settings.
@(test)
opener_table_adds_edits_moves_and_removes_a_program :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "openers", "") {return}
	w := f.state.windows[0]
	e := profile_open(&f)

	if !testing.expect(t, ui.editor_select_key(e, "openers.add")) {return}
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, !e.error)
	testing.expect(t, profile_file_has(f.path, `opener.program-1.name = "New Program"`))
	testing.expect_value(t, e.opener_expanded, "program-1")
	testing.expect_value(t, ui.editor_row(e).key, "opener.program-1")

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.command")) {return}
	ui.field_set(&e.value, "nvim %1")
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, !e.error)
	testing.expect(t, profile_file_has(f.path, `opener.program-1.command = "nvim %1"`))

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.placement")) {return}
	testing.expect_value(t, ui.editor_row(e).kind, ui.Row_Kind.Choice)
	ui.field_set(&e.value, "tab")
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, profile_file_has(f.path, "opener.program-1.placement = tab"))
	opener := settings.opener_find(&f.state.settings.openers, "program-1")
	if !testing.expect(t, opener != nil) {return}
	testing.expect_value(t, opener.command, "nvim %1")
	testing.expect_value(t, opener.placement, settings.Opener_Placement.Tab)

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.command")) {return}
	ui.field_set(&e.value, "  ")
	ui.editor_focus_row(e)
	app.editor_outcome(&f.state, w, .Save)
	testing.expect_value(t, e.error_text, "A link program needs a command line.")
	testing.expect(t, profile_file_has(f.path, `opener.program-1.command = "nvim %1"`))

	if !testing.expect(t, ui.editor_reveal(e, ui.Reveal_Row{"openers.add"})) {return}
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, profile_file_has(f.path, "opener.order = program-1, program-2"))
	if !testing.expect(t, ui.editor_select_key(e, "opener.program-2")) {return}
	profile_press(&f, {key = .Arrow_Up, modifiers = {.Control}})
	testing.expect(t, profile_file_has(f.path, "opener.order = program-2, program-1"))
	testing.expect_value(t, f.state.settings.openers.order[0], "program-2")

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	removing := app.confirmation_asking(w, app.Opener_Remove)
	if !testing.expect(t, removing != nil) {return}
	testing.expect_value(t, app.editor_opener_remove_text(removing^).title, "Delete New Program?")
	app.confirmation_finish(&f.state, w, true)
	testing.expect(t, profile_file_lacks(f.path, "opener.program-1."))
	testing.expect(t, profile_file_has(f.path, "opener.order = program-2"))
	testing.expect(t, settings.opener_find(&f.state.settings.openers, "program-1") == nil)
	testing.expect_value(t, len(f.state.settings.openers.items), 1)

	// The last program goes the same way, taking the order line with it.
	if !testing.expect(t, ui.editor_select_key(e, "opener.program-2")) {return}
	profile_press(&f, {key = .Tab})
	profile_press(&f, {key = .Delete})
	if !testing.expect(t, app.confirmation_asking(w, app.Opener_Remove) != nil) {return}
	app.confirmation_finish(&f.state, w, true)
	testing.expect(t, profile_file_lacks(f.path, "opener.program-2."))
	testing.expect(t, profile_file_lacks(f.path, "opener.order ="))
	testing.expect_value(t, len(f.state.settings.openers.items), 0)
}

// A typed name or command line saves when the keyboard moves on, Escape still discards it, and a
// value the file refuses rings its row. Offered for switches files and folders independently.
@(test)
opener_fields_save_when_left_and_offers_files_and_folders_separately :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "opener-fields", "") {return}
	w := f.state.windows[0]
	e := profile_open(&f)
	if !testing.expect(t, ui.editor_select_key(e, "openers.add")) {return}
	app.editor_outcome(&f.state, w, .Save)

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.name")) {return}
	ui.editor_focus_row(e)
	ui.field_set(&e.value, "Neovim")
	profile_press(&f, {key = .Arrow_Down})
	testing.expect(t, profile_file_has(f.path, `opener.program-1.name = "Neovim"`))
	testing.expect_value(t, ui.editor_row(e).key, "opener.program-1.command")
	testing.expect(t, !e.error)

	ui.editor_focus_row(e)
	ui.field_set(&e.value, "vim %1")
	profile_press(&f, {key = .Escape})
	profile_press(&f, {key = .Arrow_Down})
	testing.expect(t, profile_file_has(f.path, `opener.program-1.command = "notepad.exe %1"`))

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.command")) {return}
	ui.editor_focus_row(e)
	ui.field_set(&e.value, " ")
	profile_press(&f, {key = .Arrow_Up})
	testing.expect_value(t, ui.editor_row(e).key, "opener.program-1.name")
	testing.expect_value(t, e.error_key, "opener.program-1.command")
	testing.expect_value(t, e.error_text, "A link program needs a command line.")
	testing.expect(t, profile_file_has(f.path, `opener.program-1.command = "notepad.exe %1"`))

	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.offers")) {return}
	testing.expect(t, ui.editor_row(e).multiple)
	testing.expect_value(t, ui.editor_row(e).choice_mask, u32(0b01))
	e.choice_set = 0b11
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, profile_file_has(f.path, "opener.program-1.offers = files, folders"))
	testing.expect_value(t, ui.editor_row(e).key, "opener.program-1.offers")
	opener := settings.opener_find(&f.state.settings.openers, "program-1")
	if !testing.expect(t, opener != nil) {return}
	testing.expect_value(t, opener.offers, settings.OPENER_OFFERS_ALL)
	e.choice_set = 0
	app.editor_outcome(&f.state, w, .Save)
	testing.expect_value(t, e.error_text, "Choose files, folders or both.")
	testing.expect_value(t, e.choice_set, u32(0b11))
	testing.expect(t, profile_file_has(f.path, "opener.program-1.offers = files, folders"))

	// The Icon row takes a PNG path and, cleared, leaves the program to a found icon.
	if !testing.expect(t, ui.editor_select_key(e, "opener.program-1.icon")) {return}
	testing.expect_value(t, ui.editor_row(e).kind, ui.Row_Kind.Icon_File)
	ui.editor_focus_row(e)
	ui.field_set(&e.value, `icons\viewer.png`)
	app.editor_outcome(&f.state, w, .Save)
	testing.expect(t, profile_file_has(f.path, `opener.program-1.icon = "icons\viewer.png"`))
	opener = settings.opener_find(&f.state.settings.openers, "program-1")
	if testing.expect(t, opener != nil) {testing.expect_value(t, opener.icon, `icons\viewer.png`)}
	ui.field_set(&e.value, "")
	app.editor_outcome(&f.state, w, .Save)
	opener = settings.opener_find(&f.state.settings.openers, "program-1")
	if testing.expect(t, opener != nil) {testing.expect_value(t, opener.icon, "")}
}
