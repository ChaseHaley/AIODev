package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:testing"

@(private)
THEME_DELETE_THEMES :: "\ntheme.custom.alpha.base = studio-dark\ntheme.custom.alpha.cursor = #010203\n" +
	"theme.custom.beta.base = studio-dark\ntheme.custom.beta.cursor = #040506\n"

// One window showing Settings with two custom themes, alpha active.
@(private)
theme_delete_open :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (^app.Window, bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return nil, false}
	s, w := &f.state, f.state.windows[0]
	if !settings_tab_restore(t, s, w) {return nil, false}
	source := ui.editor_source(&w.editor)
	themes := strings.concatenate({source, THEME_DELETE_THEMES}, context.temp_allocator)
	updated := commit_text(t, themes, "theme.name", "alpha")
	if !testing.expect_value(t, app.settings_commit(s, source, updated), settings.Save_Error.None) {return nil, false}
	return w, testing.expect_value(t, s.settings.theme.name, "alpha")
}

@(private)
theme_delete_press :: proc(s: ^app.App, w: ^app.Window) {
	app.settings_reveal_page(s, &w.editor, {key = "theme.delete"})
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
	saved, has_file := app.settings_save_value(s, "theme.name", "beta", "Could not switch themes.")
	testing.expect(t, saved && has_file)
	testing.expect_value(t, s.settings.theme.name, "beta")
	theme_delete_press(s, w)
	testing.expect(t, settings.custom_theme_find(&s.settings, "beta") != nil)
	testing.expect(t, strings.contains(w.editor.message, "beta"))
	theme_delete_press(s, w)
	testing.expect(t, settings.custom_theme_find(&s.settings, "beta") == nil)
	testing.expect(t, settings.custom_theme_find(&s.settings, "alpha") != nil)
	testing.expect(t, w.theme_delete == nil)
}

@(test)
theme_delete_prompt_ends_when_the_page_moves_on :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	w, ok := theme_delete_open(t, &f, "theme-delete-disarm")
	if !ok {return}
	s := &f.state
	theme_delete_press(s, w)
	testing.expect(t, w.theme_delete != nil)
	app.settings_key(s, w, {key = .Arrow_Down, pressed = true})
	testing.expect(t, w.theme_delete == nil)
	testing.expect_value(t, w.editor.message, "")
	theme_delete_press(s, w)
	app.settings_key(s, w, {key = .Escape, pressed = true})
	testing.expect(t, w.theme_delete == nil)
	theme_delete_press(s, w)
	testing.expect(t, w.theme_delete != nil)
	app.run_action(s, w, .Tab_1)
	testing.expect(t, !app.settings_active(w))
	testing.expect(t, w.theme_delete == nil, "leaving Settings ends the prompt")
	app.run_action(s, w, .Settings_UI)
	theme_delete_press(s, w)
	app.settings_reveal_page(s, &w.editor, {key = "theme.delete", reload = true})
	testing.expect(t, w.theme_delete == nil, "reloading the page ends the prompt")
	theme_delete_press(s, w)
	app.reload_settings(s, false)
	testing.expect(t, w.theme_delete == nil, "reloading settings ends the prompt")
	theme_delete_press(s, w)
	app.run_action(s, w, .Close_Tab)
	testing.expect(t, !ui.editor_loaded(&w.editor))
	testing.expect(t, w.theme_delete == nil, "closing Settings ends the prompt")
	testing.expect(t, settings.custom_theme_find(&s.settings, "alpha") != nil)
	testing.expect_value(t, s.settings.theme.name, "alpha")
}
