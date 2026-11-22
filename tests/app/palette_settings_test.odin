package app_test

import app "../../src"
import "cosmos:input"
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

// Comfy is one of Activity panel view's values: the palette finds the setting by it and names the
// value, and Settings search lists the same row.
@(test)
palette_and_settings_find_a_setting_by_a_choice_label :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "choice-label", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.palette_open_mode(s, w, .All)
	ui.palette_text(&s.palette, &s.registry, "comfy")
	if !testing.expect(t, len(s.palette.results) > 0) {return}
	testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "status.panel_view")
	testing.expect_value(t, s.palette.results[0].value, "Comfy")
	app.settings_reveal(s, w, {key = "pane.gap", search = .Clear})
	ui.field_set(&w.editor.filter, "comfy")
	ui.editor_filter(&w.editor)
	testing.expect_value(t, ui.editor_row(&w.editor).key, "status.panel_view")
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
	saved := app.settings_save_value(s, chosen.key, chosen.value, "Could not save the setting.")
	testing.expect(t, saved)
	testing.expect(t, s.settings.cursor.blink, "the toggle reached the live settings")
	testing.expect(t, app.palette_active(s, w), "the palette stays open")
	outcome, _ = ui.palette_key(&s.palette, &s.registry, {key = .Arrow_Right, modifiers = {.Alt}, pressed = true})
	testing.expect_value(t, outcome, ui.Outcome.Changed)
}

// Each step of a slider saves on top of the revision the previous step wrote.
@(test)
palette_slider_saves_consecutive_steps :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "inline-steps", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.palette_open_mode(s, w, .Settings)
	ui.palette_text(&s.palette, &s.registry, "pane.gap")
	if !testing.expect(t, len(s.palette.results) > 0) {return}
	testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "pane.gap")
	gap := s.settings.pane.gap
	for step in 1 ..= 2 {
		app.handle_event(s, input.Key_Event{window = w.id, key = .Arrow_Right, modifiers = {.Alt}, pressed = true})
		testing.expect_value(t, s.settings.pane.gap, gap + step)
	}
}

// Each flipped option of a multiple choice saves through the settings file with its list open, on
// top of the option flipped before it.
@(test)
palette_multiple_choice_saves_each_option_with_the_list_open :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "inline-multiple", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.palette_open_mode(s, w, .Settings)
	ui.palette_text(&s.palette, &s.registry, "interface.confirm")
	if !testing.expect(t, len(s.palette.results) > 0) {return}
	testing.expect_value(t, ui.palette_result_name(&s.palette, s.palette.results[0]), "interface.confirm")
	confirm := s.settings.interface.confirm
	app.handle_event(s, input.Key_Event{window = w.id, key = .Enter, modifiers = {.Control}, pressed = true})
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.Choice)
	app.handle_event(s, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, s.settings.interface.confirm, confirm ~ {.Close_Split_Tab})
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.Choice)
	app.handle_event(s, input.Key_Event{window = w.id, key = .Arrow_Down, pressed = true})
	app.handle_event(s, input.Key_Event{window = w.id, key = .Space, pressed = true})
	testing.expect_value(t, s.settings.interface.confirm, confirm ~ {.Close_Split_Tab, .Shell_Switch})
	app.handle_event(s, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect_value(t, ui.palette_editing(&s.palette), ui.Palette_Edit_Kind.None)
	testing.expect(t, app.palette_active(s, w), "Escape closes only the list")
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
	expect_control(t, "interface.confirm", .Choice)
	expect_control(t, "status.surfaces", .Choice)
	testing.expect(t, ui.palette_setting(settings.schema_find("interface.confirm")^).multiple)
	expect_control(t, "input.leader", .None)
	expect_control(t, settings.PADDING_GROUPS_KEY, .None)
	expect_control(t, settings.QUICK_LABELS_KEY, .None)
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
	testing.expect(t, !ui.palette_setting(settings.schema_find(settings.QUICK_LABELS_KEY)^).resettable)
	for entry in settings.SCHEMA {
		row := ui.palette_setting(entry)
		if row.control == .Slider {testing.expect(t, row.step > 0, entry.key)}
	}
}

@(test)
palette_setting_values_use_static_choice_labels :: proc(t: ^testing.T) {
	state: app.App
	app.palette_set_sources(&state)
	names, labels := settings.STATUS_PANEL_VIEW_NAME, settings.STATUS_PANEL_VIEW_LABEL
	for view in ([?]settings.Status_Panel_View{.Comfy, .Dense}) {
		state.settings.status.panel_view = view
		value, label := state.palette.values.value(state.palette.values.user, "status.panel_view")
		testing.expect_value(t, value, names[view])
		testing.expect_value(t, label, labels[view])
	}
}

@(test)
palette_setting_values_use_live_choice_labels :: proc(t: ^testing.T) {
	state: app.App
	append(&state.settings.themes, settings.Custom_Theme{id = "custom-theme", name = "My Theme"})
	defer delete(state.settings.themes)
	state.settings.theme.name = "custom-theme"
	app.palette_set_sources(&state)
	value, label := state.palette.values.value(state.palette.values.user, "theme.name")
	testing.expect_value(t, value, "custom-theme")
	testing.expect_value(t, label, "My Theme")
}
