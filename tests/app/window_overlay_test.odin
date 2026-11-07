package app_test

import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:ui"

@(test)
overlay_rename_replaces_tab_menu_and_receives_text_and_keys :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "overlay-rename", false) {return}
	s, w := &f.state, f.state.windows[0]
	app.tab_menu_open(s, w, 0, 20, 20)
	if !testing.expect(t, app.tab_menu_shown(w)) {return}
	app.rename_open(s, w, true, 0)
	testing.expect(t, app.rename_shown(w) && !app.tab_menu_shown(w))
	app.handle_event(s, platform.Text_Event{window = w.id, text = "Named from menu"})
	app.handle_event(s, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect(t, !app.rename_shown(w))
	testing.expect_value(t, w.workspace.tabs[0].name, "Named from menu")
}

@(test)
overlay_openers_replace_each_other_and_cancel_uncommitted_names :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "overlay-openers", false) {return}
	s, w := &f.state, f.state.windows[0]
	kept := w.workspace.name
	for opener in 0..<6 {
		app.workspace_name_begin(s, w)
		ui.field_set(&w.rename, "Uncommitted name")
		switch opener {
		case 0: app.tab_menu_open(s, w, 0, 20, 20)
		case 1: app.profile_menu_open_new_tab(s, w, 20, 20)
		case 2: app.document_menu_open_focused(s, w)
		case 3: app.workspace_picker_open(s, w)
		case 4: app.palette_open(s, w)
		case 5:
			app.pane_split(s, w, .Right)
			app.pending_close_open_tab(s, w, 0)
		}
		testing.expect(t, !app.rename_shown(w))
		testing.expect_value(t, w.workspace.name, kept)
		app.window_overlays_cancel(s, w)
		testing.expect_value(t, app.overlay_kind(s, w), app.Overlay_Kind.None)
	}
	app.tab_menu_open(s, w, 0, 20, 20)
	app.palette_open(s, w)
	testing.expect(t, app.palette_active(s, w) && !app.tab_menu_shown(w))
	app.profile_menu_open_new_tab(s, w, 20, 20)
	testing.expect(t, app.profile_menu_shown(w) && !app.palette_active(s, w))
	app.document_menu_open_focused(s, w)
	testing.expect(t, app.document_menu_shown(w) && !app.profile_menu_shown(w))
}
