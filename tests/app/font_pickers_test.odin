package app_test

import app "../../src"
import "aio:settings"
import "aio:font"
import "aio:ui"
import "core:testing"
import "core:slice"

@(test)
font_pickers_filter_and_apply_independent_families_to_all_windows :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "font-pickers") {return}
	s := &f.state
	p := &s.windows[0].editor
	testing.expect(t, ui.editor_select_key(p, "font.family"))
	row := ui.editor_row(p)
	testing.expect_value(t, row.kind, ui.Row_Kind.Choice)
	testing.expect(t, slice.contains(row.choices, "Consolas"))
	testing.expect(t, !slice.contains(row.choices, "Segoe UI"))
	previous_shell := s.family
	previous_ui := s.ui_text.family
	updated := commit_text(t, p.source, "interface.font_family", "Consolas")
	testing.expect_value(t, app.settings_commit(s, p.source, updated, p), settings.Save_Error.None)
	testing.expect_value(t, s.family, previous_shell)
	testing.expect(t, s.ui_text.family != previous_ui)
	expected_ui, err := font.family_load(s.fonts, "Consolas")
	testing.expect_value(t, err, font.Error.None)
	for window in s.windows {testing.expect_value(t, window.ui_text.family, expected_ui)}
	updated = commit_text(t, p.source, "font.show_all", "true")
	testing.expect_value(t, app.settings_commit(s, p.source, updated, p), settings.Save_Error.None)
	testing.expect(t, ui.editor_select_key(p, "font.family"))
	testing.expect(t, slice.contains(ui.editor_row(p).choices, "Segoe UI"))
	updated = commit_text(t, p.source, "font.family", "Segoe UI")
	testing.expect_value(t, app.settings_commit(s, p.source, updated, p), settings.Save_Error.None)
	testing.expect_value(t, s.settings.interface.font_family, "Consolas")
	testing.expect_value(t, s.settings.font.family, "Segoe UI")
	updated = commit_text(t, p.source, "font.show_all", "false")
	testing.expect_value(t, app.settings_commit(s, p.source, updated, p), settings.Save_Error.None)
	testing.expect(t, ui.editor_select_key(p, "font.family"))
	testing.expect(t, slice.contains(ui.editor_row(p).choices, "Segoe UI"))
	testing.expect(t, ui.editor_select_key(p, "interface.font_family"))
	testing.expect(t, slice.contains(ui.editor_row(p).choices, "Segoe UI"))
}
