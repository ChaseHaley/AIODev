package app_test

import app "../../src"
import "cosmos:font"
import "aio:views"
import "core:testing"
import "core:slice"
import "cosmos:ui"

@(test)
font_pickers_filter_and_apply_independent_families_to_all_windows :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "font-pickers") {return}
	s := &f.state
	p := &s.windows[0].editor
	for item in p.rows {testing.expect(t, item.key != "font.show_all")}
	testing.expect(t, views.editor_select_key(p, "font.family"))
	row := views.editor_row(p)
	testing.expect_value(t, row.kind, views.Row_Kind.Choice)
	testing.expect(t, slice.contains(row.choices, "Cascadia Code"))
	testing.expect(t, !slice.contains(row.choices, "Selawik"))
	previous_shell := s.family
	previous_ui := s.ui_text.family
	testing.expect_value(t, commit_value(s, "interface.font_family", "Cascadia Code", app.Settings_Page{p}), app.Settings_Status.Applied)
	testing.expect_value(t, s.family, previous_shell)
	testing.expect(t, s.ui_text.family != previous_ui)
	expected_ui, err := font.family_load(s.fonts, "Cascadia Code")
	testing.expect_value(t, err, font.Error.None)
	for window in s.windows {testing.expect_value(t, window.ui_text.family, expected_ui)}
	testing.expect(t, views.editor_select_key(p, "font.family"))
	views.editor_key(p, {key = .Enter, pressed = true})
	views.editor_text(p, "Selaw")
	views.editor_key(p, {key = .Tab, pressed = true})
	outcome := views.editor_key(p, {key = .Space, pressed = true})
	testing.expect_value(t, outcome, views.Editor_Outcome.Font_Filter)
	app.editor_outcome(s, s.windows[0], outcome)
	testing.expect(t, s.settings.font.show_all)
	testing.expect_value(t, views.editor_popup(p), views.Editor_Popup.Choice)
	testing.expect_value(t, ui.field_string(&p.dropdown.search), "Selaw")
	testing.expect_value(t, s.family, previous_shell)
	testing.expect(t, views.editor_choice_toggle_focused(p))
	views.editor_key(p, {key = .Escape, pressed = true})
	testing.expect(t, slice.contains(views.editor_row(p).choices, "Selawik"))
	testing.expect_value(t, commit_value(s, "font.family", "Selawik", app.Settings_Page{p}), app.Settings_Status.Applied)
	testing.expect_value(t, s.settings.interface.font_family, "Cascadia Code")
	testing.expect_value(t, s.settings.font.family, "Selawik")
	testing.expect_value(t, commit_value(s, "font.show_all", "false", app.Settings_Page{p}), app.Settings_Status.Applied)
	testing.expect(t, views.editor_select_key(p, "font.family"))
	testing.expect(t, slice.contains(views.editor_row(p).choices, "Selawik"))
	testing.expect(t, views.editor_select_key(p, "interface.font_family"))
	testing.expect(t, slice.contains(views.editor_row(p).choices, "Selawik"))
}
