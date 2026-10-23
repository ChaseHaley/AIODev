package app_test

import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:settings"
import "aio:ui"

@(private)
Reveal_Fixture :: struct {
	state:     app.App,
	editor:    ui.Editor,
	directory: string,
	path:      string,
}

@(private)
reveal_fixture_create :: proc(t: ^testing.T, f: ^Reveal_Fixture, text: string) -> bool {
	directory, directory_error := os.make_directory_temp("", "aio-reveal-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return false}
	f.directory = directory
	f.path = strings.concatenate({directory, "/settings.ini"})
	if !testing.expect_value(t, os.write_entire_file(f.path, text), nil) {return false}
	f.state = app.App{settings_path = f.path, registry = commands.create()}
	if !testing.expect_value(t, app.register_actions(&f.state.registry), commands.Error.None) {
		return false
	}
	rows := [?]ui.Editor_Row {
		{key = "font.size", title = "Font Size", value = "12", kind = .Integer},
		{key = "pane.gap", title = "Pane Gap", value = "8", kind = .Integer},
		{key = "tab.confirm_close", title = "Confirm Close", value = "true", kind = .Toggle},
		{key = "keys.pane.split_right", title = "Split Right", value = "Alt+Shift+R", kind = .Shortcut},
		{key = "keys.tab.new", title = "New Tab", value = "Ctrl+T", kind = .Shortcut},
	}
	for row in rows {
		if !testing.expect_value(t, ui.editor_add(&f.editor, row, "Test"), nil) {return false}
	}
	ui.editor_filter(&f.editor)
	return true
}

@(private)
reveal_fixture_destroy :: proc(t: ^testing.T, f: ^Reveal_Fixture) {
	ui.editor_destroy(&f.editor)
	commands.destroy(&f.state.registry)
	settings.destroy(&f.state.settings)
	settings.diagnostics_destroy(&f.state.settings_diagnostics)
	os.remove(f.path)
	delete(f.path)
	os.remove(f.directory)
	delete(f.directory)
}

@(private)
reveal_row_key :: proc(e: ^ui.Editor) -> string {
	row := ui.editor_row(e)
	return row == nil ? "" : row.key
}

// A palette jump clears the search, so its target is never hidden by the search it replaces, and
// focus moves to the row's control only when that row accepts typing.
@(test)
settings_reveal_palette_clears_the_search_and_focuses_an_editable_row :: proc(t: ^testing.T) {
	f: Reveal_Fixture
	defer reveal_fixture_destroy(t, &f)
	if !reveal_fixture_create(t, &f, "font.size = 12\n") {return}
	e := &f.editor
	app.settings_reveal_page(&f.state, e, {query = "font", search = .Scope})
	testing.expect_value(t, ui.field_string(&e.filter), "font")
	app.settings_reveal_page(&f.state, e, {key = "pane.gap", search = .Clear, focus = .Control})
	testing.expect_value(t, ui.field_string(&e.filter), "")
	testing.expect_value(t, reveal_row_key(e), "pane.gap")
	testing.expect_value(t, e.focus, ui.Editor_Focus.Control)
	testing.expect_value(t, e.message, "")
	app.settings_reveal_page(&f.state, e, {key = "keys.tab.new", search = .Clear, focus = .Control})
	testing.expect_value(t, reveal_row_key(e), "keys.tab.new")
	testing.expect_value(t, ui.editor_row(e).kind, ui.Row_Kind.Shortcut)
	testing.expect_value(t, e.focus, ui.Editor_Focus.Search)
	app.settings_reveal_page(&f.state, e, {key = "no.such.key", search = .Clear, focus = .Control})
	testing.expect_value(t, reveal_row_key(e), "font.size")
	testing.expect_value(t, e.focus, ui.Editor_Focus.Search)
}

// The shortcut action narrows the page to key bindings without selecting one of them.
@(test)
settings_reveal_shortcut_scopes_the_search_to_key_bindings :: proc(t: ^testing.T) {
	f: Reveal_Fixture
	defer reveal_fixture_destroy(t, &f)
	if !reveal_fixture_create(t, &f, "font.size = 12\n") {return}
	e := &f.editor
	app.settings_reveal_page(&f.state, e, {query = "font", search = .Scope})
	app.settings_reveal_page(&f.state, e, {query = "keys.", search = .Scope})
	testing.expect_value(t, ui.field_string(&e.filter), "keys.")
	testing.expect(t, strings.has_prefix(reveal_row_key(e), "keys."))
	visible := 0
	for item in e.items {
		if item.row < 0 {continue}
		visible += 1
		testing.expect(t, strings.has_prefix(e.rows[item.row].key, "keys."))
	}
	testing.expect_value(t, visible, 2)
	testing.expect_value(t, e.focus, ui.Editor_Focus.Search)
	testing.expect_value(t, e.message, "")
}

// The tab action clears the search, then selects its own row, so the selection survives the filter
// that showed the whole page again.
@(test)
settings_reveal_tab_selects_the_confirm_close_row :: proc(t: ^testing.T) {
	f: Reveal_Fixture
	defer reveal_fixture_destroy(t, &f)
	if !reveal_fixture_create(t, &f, "font.size = 12\n") {return}
	e := &f.editor
	app.settings_reveal_page(&f.state, e, {query = "font", search = .Scope})
	app.settings_reveal_page(&f.state, e, {key = "tab.confirm_close", search = .Clear})
	testing.expect_value(t, ui.field_string(&e.filter), "")
	testing.expect_value(t, reveal_row_key(e), "tab.confirm_close")
	testing.expect_value(t, e.focus, ui.Editor_Focus.Search)
	testing.expect_value(t, e.message, "")
}

// The theme handler reloads the page it just rewrote, keeps the user's search, selects its row and
// reports the outcome in the page.
@(test)
settings_reveal_theme_preserves_the_search_across_a_reload_and_posts_its_message :: proc(t: ^testing.T) {
	f: Reveal_Fixture
	defer reveal_fixture_destroy(t, &f)
	if !reveal_fixture_create(t, &f, "profile.default.command = pwsh.exe\n") {return}
	e := &f.editor
	ui.field_set(&e.filter, "profile")
	ui.editor_filter(e)
	// The reload is what adds the settings rows; this page only has the fixture's rows.
	testing.expect(t, !ui.editor_select_key(e, "profile.default.command"))
	if !testing.expect_value(t, os.write_entire_file(f.path, "profile.default.command = cmd.exe\n"), nil) {
		return
	}
	app.settings_reveal_page(
		&f.state,
		e,
		{
			key = "profile.default.command",
			search = .Preserve,
			reload = true,
			message = "Shell foreground and background now follow the theme.",
		},
	)
	testing.expect_value(t, ui.field_string(&e.filter), "profile")
	testing.expect_value(t, reveal_row_key(e), "profile.default.command")
	testing.expect_value(t, ui.editor_row(e).value, "cmd.exe")
	testing.expect_value(t, e.message, "Shell foreground and background now follow the theme.")
	testing.expect(t, !e.error)
}
