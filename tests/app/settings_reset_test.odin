package app_test

import app "../../src"
import "aio:settings"
import "aio:ui"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
settings_factory_reset_cancels_then_replaces_every_category_and_open_page :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "factory-reset") {return}
	s, w := &f.state, f.state.windows[0]
	updated := strings.concatenate({ui.editor_source(&w.editor),
		"\nfont.size = 22\npane.gap = 13\nkeys.tab.next = Alt+N\n",
		"profile.custom.name = Custom\nprofile.custom.command = cmd.exe\n",
		"theme.custom.mine.base = studio-dark\ntheme.custom.mine.text = #123456\n"}, context.temp_allocator)
	if !testing.expect_value(t, app.settings_commit(s, ui.editor_source(&w.editor), updated), settings.Save_Error.None) {return}
	app.editor_outcome(s, w, .Reset_All)
	c := app.confirmation_current(w)
	if !testing.expect(t, c != nil && app.confirmation_asking(w, app.Settings_Reset) != nil) {return}
	testing.expect_value(t, c.focus, ui.Confirm_Button.Cancel)
	app.confirmation_finish(s, w, false)
	testing.expect_value(t, ui.editor_source(&w.editor), updated)
	testing.expect_value(t, s.settings.font.size, 22)
	app.editor_outcome(s, w, .Reset_All)
	app.confirmation_finish(s, w, true)
	defaults, err := settings.default_text()
	defer delete(defaults)
	testing.expect_value(t, err, nil)
	saved, read_error := os.read_entire_file(s.settings_path, context.allocator)
	defer delete(saved)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(saved), defaults)
	for window in s.windows {
		testing.expect_value(t, ui.editor_source(&window.editor), defaults)
		testing.expect_value(t, ui.field_string(&window.editor.filter), "")
	}
	testing.expect_value(t, len(s.settings.keys), 0)
	testing.expect(t, settings.profile_find(&s.settings.profiles, "custom") == nil)
	factory, factory_error := settings.defaults()
	defer settings.destroy(&factory)
	testing.expect_value(t, factory_error, nil)
	testing.expect_value(t, s.settings.font.size, factory.font.size)
	testing.expect_value(t, s.settings.pane.gap, factory.pane.gap)
}

@(test)
settings_factory_reset_refuses_external_edit_after_question_opens :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !commit_open_pages(t, &f, "factory-reset-conflict") {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_outcome(s, w, .Reset_All)
	external := strings.concatenate({ui.editor_source(&w.editor), "\npane.gap = 17\n"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(s.settings_path, external), nil)
	app.confirmation_finish(s, w, true)
	saved, err := os.read_entire_file(s.settings_path, context.allocator)
	defer delete(saved)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, string(saved), external)
}
