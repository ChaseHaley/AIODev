package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private, rodata)
THEME_DELETE_THEMES := [?][2]string {
	{"theme.custom.alpha.base", "studio-dark"},
	{"theme.custom.alpha.cursor", "#010203"},
	{"theme.custom.beta.base", "studio-dark"},
	{"theme.custom.beta.cursor", "#040506"},
	{"theme.name", "alpha"},
}

// One window showing Settings with two custom themes, alpha active.
@(private)
theme_delete_open :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (^app.Window, bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return nil, false}
	s, w := &f.state, f.state.windows[0]
	if !settings_tab_restore(t, s, w) {return nil, false}
	for line in THEME_DELETE_THEMES {
		status := commit_value(s, line[0], line[1], app.Settings_Page{&w.editor})
		if !testing.expect_value(t, status, app.Settings_Status.Applied) {return nil, false}
	}
	return w, testing.expect_value(t, s.settings.theme.name, "alpha")
}

@(private)
theme_delete_press :: proc(s: ^app.App, w: ^app.Window) {
	app.settings_reveal_page(&w.editor, {key = "theme.delete"})
	app.editor_outcome(s, w, .Save)
}

// The prompt names the active theme; a theme switch while it is up must not let the next press
// delete the theme the user switched to without asking about it.
@(test)
theme_delete_confirms_only_the_theme_its_prompt_named :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	w, ok := theme_delete_open(t, &f, "theme-delete-named")
	if !ok {return}
	s := &f.state
	theme_delete_press(s, w)
	testing.expect(t, strings.contains(w.editor.message, "alpha"))
	// The palette's theme switch saves through the file while the prompt is up.
	testing.expect(t, app.settings_save_value(s, "theme.name", "beta", "Could not switch themes."))
	testing.expect_value(t, s.settings.theme.name, "beta")
	theme_delete_press(s, w)
	testing.expect(t, settings.custom_theme_find(&s.settings, "beta") != nil)
	testing.expect(t, strings.contains(w.editor.message, "beta"))
	theme_delete_press(s, w)
	testing.expect(t, settings.custom_theme_find(&s.settings, "beta") == nil)
	testing.expect(t, settings.custom_theme_find(&s.settings, "alpha") != nil)
	testing.expect(t, !w.editor.delete_armed)
}

@(test)
theme_delete_prompt_ends_when_the_page_moves_on :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	w, ok := theme_delete_open(t, &f, "theme-delete-disarm")
	if !ok {return}
	s := &f.state
	theme_delete_press(s, w)
	testing.expect(t, w.editor.delete_armed)
	app.settings_key(s, w, {key = .Arrow_Down, pressed = true})
	testing.expect(t, !w.editor.delete_armed)
	testing.expect_value(t, w.editor.message, "")
	theme_delete_press(s, w)
	app.settings_key(s, w, {key = .Escape, pressed = true})
	testing.expect(t, !w.editor.delete_armed)
	theme_delete_press(s, w)
	testing.expect(t, w.editor.delete_armed)
	app.run_action(s, w, .Tab_1)
	testing.expect(t, !app.settings_active(w))
	testing.expect(t, !w.editor.delete_armed, "leaving Settings ends the prompt")
	app.run_action(s, w, .Settings_UI)
	theme_delete_press(s, w)
	testing.expect(t, app.settings_load(s, &w.editor))
	testing.expect(t, !w.editor.delete_armed, "reloading the page ends the prompt")
	theme_delete_press(s, w)
	app.reload_settings(s, false)
	testing.expect(t, !w.editor.delete_armed, "reloading settings ends the prompt")
	theme_delete_press(s, w)
	app.run_action(s, w, .Close_Tab)
	testing.expect(t, !ui.editor_loaded(&w.editor))
	testing.expect(t, !w.editor.delete_armed, "closing Settings ends the prompt")
	testing.expect(t, settings.custom_theme_find(&s.settings, "alpha") != nil)
	testing.expect_value(t, s.settings.theme.name, "alpha")
}
