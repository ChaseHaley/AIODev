package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:testing"

@(test)
palette_profiles_result_jumps_to_the_profile_table :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "profiles-jump", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.palette_open_mode(s, w, .Settings)
	ui.palette_text(&s.palette, &s.registry, "profiles")
	if !testing.expect(t, len(s.palette.results) > 0) {return}
	testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "profiles")
	outcome, _ := ui.palette_key(&s.palette, &s.registry, {key = .Enter, pressed = true})
	testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
	app.settings_reveal(s, w, {key = "profiles", search = .Clear})
	testing.expect_value(t, ui.editor_row(&w.editor).kind, ui.Row_Kind.Profile)
}

@(test)
palette_toggle_saves_through_the_settings_file_and_stays_open :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "inline-setting", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.palette_open_mode(s, w, .Settings)
	ui.palette_text(&s.palette, &s.registry, "cursor blink")
	if !testing.expect(t, len(s.palette.results) > 0) {return}
	testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "cursor.blink")
	outcome, _ := ui.palette_key(&s.palette, &s.registry, {key = .Arrow_Right, modifiers = {.Alt}, pressed = true})
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	chosen, chose := ui.palette_chosen_take(&s.palette).(ui.Chosen_Value)
	if !testing.expect(t, chose) {return}
	saved, _ := app.settings_save_value(s, chosen.key, chosen.value, "Could not save the setting.")
	testing.expect(t, saved)
	testing.expect(t, s.settings.cursor.blink, "the toggle reached the live settings")
	testing.expect(t, app.palette_active(s, w), "the palette stays open")
	outcome, _ = ui.palette_key(&s.palette, &s.registry, {key = .Arrow_Right, modifiers = {.Alt}, pressed = true})
	testing.expect_value(t, outcome, ui.Outcome.Changed)
}

@(test)
palette_controls_match_the_settings_page_and_keep_complex_settings_jump_only :: proc(t: ^testing.T) {
	expect_control :: proc(t: ^testing.T, key: string, control: ui.Palette_Control) {
		entry := settings.schema_find(key)
		if !testing.expect(t, entry != nil, key) {return}
		testing.expect_value(t, ui.palette_setting(entry^).control, control)
	}
	expect_control(t, "cursor.blink", .Toggle)
	expect_control(t, "pane.gap", .Slider)
	expect_control(t, "theme.name", .Choice)
	expect_control(t, "font.family", .Choice)
	expect_control(t, "tabs.orientation", .Choice)
	expect_control(t, "status.ignore_apps", .Text)
	expect_control(t, "input.leader", .None)
	expect_control(t, settings.PADDING_GROUPS_KEY, .None)
	size := ui.palette_setting(settings.schema_find("font.size")^)
	testing.expect_value(t, size.minimum, 6)
	testing.expect_value(t, size.maximum, 32)
	testing.expect_value(t, size.step, 1)
	testing.expect(t, ui.palette_setting(settings.schema_find("font.family")^).searchable)
	testing.expect(t, !ui.palette_setting(settings.schema_find("theme.name")^).searchable)
	gap := ui.palette_setting(settings.schema_find("pane.gap")^)
	testing.expect(t, gap.resettable)
	testing.expect_value(t, gap.default_value, "4")
	testing.expect(t, ui.palette_setting(settings.schema_find("input.leader")^).resettable)
	testing.expect(t, !ui.palette_setting(settings.schema_find(settings.PADDING_GROUPS_KEY)^).resettable)
}
