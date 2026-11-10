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
}
