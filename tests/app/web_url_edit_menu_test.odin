package app_test

import app "../../src"
import "cosmos:platform"
import "aio:ui"
import "core:testing"

// The menu rows by label, with whether each is enabled, and how many separators the menu has.
@(private = "file")
menu_rows :: proc(w: ^app.Window) -> (rows: map[string]bool, separators: int) {
	for item in w.edit_menu.items {
		if item.separator {separators += 1} else {rows[item.label] = item.enabled}
	}
	return
}

@(private = "file")
choose :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, label: string) {
	for item, index in w.edit_menu.items {
		if item.label != label {continue}
		ui.menu_select(&w.edit_menu, index)
		app.edit_menu_choose(s, w)
		return
	}
	testing.expectf(t, false, "no %s row", label)
}

@(test)
web_url_edit_menu_offers_what_a_field_can_do :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "web-url-menu", false) {return}
	s, w := &f.state, f.state.windows[0]
	pane := app.web_pane_create(s, "https://example.com/a")
	if !testing.expect(t, pane != nil) {return}
	id := pane.id
	testing.expect(t, platform.clipboard_set_text(&s.platform, "pasted"))

	// A field that is not being edited starts to be, all selected, as a click in it would have.
	app.edit_menu_open_web_url(s, w, id, 20, 20)
	target, shown := w.overlay.(app.Overlay_Edit_Menu)
	if !testing.expect(t, shown, "the menu should be open") {return}
	_, for_url := target.target.(app.Edit_Menu_Web_Url)
	testing.expect(t, for_url)
	testing.expect(t, pane.url_editing)
	rows, separators := menu_rows(w)
	defer delete(rows)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, separators, 1)
	testing.expect(t, rows["Cut"] && rows["Copy"] && rows["Paste"] && rows["Select all"])
	testing.expect_value(t, ui.field_selected_text(&pane.url_field), "https://example.com/a")

	// With nothing selected Cut and Copy do nothing; Select all and Paste still can.
	app.overlay_close(s, w)
	pane.url_field.anchor = pane.url_field.cursor
	app.edit_menu_open_web_url(s, w, id, 20, 20)
	delete(rows)
	rows, _ = menu_rows(w)
	testing.expect(t, !rows["Cut"] && !rows["Copy"], "nothing is selected")
	testing.expect(t, rows["Paste"] && rows["Select all"])
	app.overlay_close(s, w)

	// An empty field has nothing to select either.
	ui.field_set(&pane.url_field, "")
	app.edit_menu_open_web_url(s, w, id, 20, 20)
	delete(rows)
	rows, _ = menu_rows(w)
	testing.expect(t, !rows["Cut"] && !rows["Copy"] && !rows["Select all"] && rows["Paste"])
	app.overlay_close(s, w)
}

@(test)
web_url_edit_menu_commands_edit_the_field_and_keep_it_editing :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "web-url-menu-edit", false) {return}
	s, w := &f.state, f.state.windows[0]
	pane := app.web_pane_create(s, "")
	if !testing.expect(t, pane != nil) {return}
	id := pane.id
	pane.url_editing = true
	ui.field_set(&pane.url_field, "alpha beta")
	pane.url_field.anchor = 6
	pane.url_field.cursor = 10

	app.edit_menu_open_web_url(s, w, id, 20, 20)
	w.dirty = false
	choose(t, s, w, "Copy")
	copied, ok := platform.clipboard_get_text(&s.platform, context.temp_allocator)
	testing.expect(t, ok && copied == "beta", copied)
	testing.expect(t, !app.edit_menu_shown(w), "choosing a row closes the menu")
	testing.expect(t, pane.url_editing && w.dirty)
	testing.expect_value(t, ui.field_string(&pane.url_field), "alpha beta")

	app.edit_menu_open_web_url(s, w, id, 20, 20)
	choose(t, s, w, "Cut")
	testing.expect_value(t, ui.field_string(&pane.url_field), "alpha ")
	testing.expect(t, pane.url_editing)

	app.edit_menu_open_web_url(s, w, id, 20, 20)
	choose(t, s, w, "Paste")
	testing.expect_value(t, ui.field_string(&pane.url_field), "alpha beta")
	testing.expect_value(t, pane.url_field.cursor, 10)

	w.dirty = false
	app.edit_menu_open_web_url(s, w, id, 20, 20)
	choose(t, s, w, "Select all")
	testing.expect_value(t, ui.field_selected_text(&pane.url_field), "alpha beta")
	testing.expect(t, pane.url_editing && w.dirty)
}

@(test)
web_url_edit_menu_for_a_missing_pane_does_not_open :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "web-url-menu-missing", false) {return}
	s, w := &f.state, f.state.windows[0]
	app.edit_menu_open_web_url(s, w, 12345, 20, 20)
	testing.expect(t, !app.edit_menu_shown(w))
}
