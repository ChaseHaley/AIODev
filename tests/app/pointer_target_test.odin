package app_test

import app "../../src"
import "aio:render"
import "aio:ui"
import "core:testing"

// The find bar floats over the docked Activity panel. Hover, cursor and press must all reach the find
// bar there, and the panel must see the pointer leave.
@(test)
pointer_find_bar_over_activity_panel_owns_hover_cursor_and_press :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-find-activity") {return}
	s, w := &f.state, f.state.windows[0]
	s.settings.status.panel = true
	s.settings.status.panel_side = .Right
	w.status.panel_width = 480
	app.window_relayout(s, w)
	ui.find_open(&w.find)
	l, _ := app.find_controls(w, app.focused_session(s, w))
	panel := app.status_panel_rect(s, w)
	close := pointer_centre(l.close)
	toggle := pointer_centre(l.regex_toggle)
	overlaps := pointer_inside(panel, close.x, close.y)
	if !testing.expect(t, overlaps, "the find bar must overlap the panel") {return}
	testing.expect(t, pointer_inside(panel, toggle.x, toggle.y))

	below := [2]f32{close.x, l.panel.y + l.panel.height + 40 * w.scale}
	testing.expect_value(t, app.pointer_target(s, w, below.x, below.y), app.Pointer_Target.Status_Panel)
	pointer_expect_move(t, s, w, below.x, below.y, .Arrow)
	testing.expect_value(t, w.status.hover_surface, app.Status_Surface.Panel)

	for point in ([?][2]f32{toggle, close}) {
		testing.expect_value(t, app.pointer_target(s, w, point.x, point.y), app.Pointer_Target.Find)
		pointer_expect_move(t, s, w, point.x, point.y, .Hand)
		testing.expect_value(t, w.status.hover_surface, app.Status_Surface.None)
	}
	testing.expect_value(t, w.find.hover, ui.Find_Outcome.Close)

	gesture_button(s, w, .Left, true, toggle.x, toggle.y)
	gesture_button(s, w, .Left, false, toggle.x, toggle.y)
	testing.expect(t, w.find.regex)
	gesture_button(s, w, .Left, true, close.x, close.y)
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect(t, !w.find.open)
	testing.expect_value(t, app.pointer_target(s, w, close.x, close.y), app.Pointer_Target.Status_Panel)
}

// A press that starts on a find button keeps the pointer with the find bar while it is held, even over
// the surfaces beneath.
@(test)
pointer_held_find_press_keeps_the_pointer :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-find-held") {return}
	s, w := &f.state, f.state.windows[0]
	ui.find_open(&w.find)
	l, _ := app.find_controls(w, app.focused_session(s, w))
	close := pointer_centre(l.close)
	gesture_button(s, w, .Left, true, close.x, close.y)
	pane := w.panes[0].rect
	inside := [2]f32{pane.x + pane.width / 2, pane.y + pane.height / 2}
	pointer_expect_move(t, s, w, inside.x, inside.y, .Arrow)
	testing.expect(t, !w.selecting)
	gesture_button(s, w, .Left, false, inside.x, inside.y)
	testing.expect(t, w.find.open, "releasing off the button must not close the bar")
	pointer_expect_move(t, s, w, inside.x, inside.y, .Text)
}

@(private)
pointer_centre :: proc(r: render.Rect) -> [2]f32 {return {r.x + r.width / 2, r.y + r.height / 2}}

@(private)
pointer_inside :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// An open menu owns the whole window: surfaces beneath it lose their hover and no press reaches them.
@(test)
pointer_open_menu_owns_the_window_and_clears_hover_beneath :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-menu-modal") {return}
	s, w := &f.state, f.state.windows[0]
	w.width, w.height = i32(1400 * w.scale), i32(900 * w.scale)
	app.window_relayout(s, w)
	windows := len(s.windows)
	caption := [2]f32{f32(w.width) - 23 * w.scale, 20 * w.scale}
	pointer_expect_move(t, s, w, caption.x, caption.y, .Arrow)
	testing.expect_value(t, w.caption_hover, 2)
	app.tab_menu_open(s, w, 0, 40 * w.scale, 60 * w.scale)
	if !testing.expect(t, w.tab_menu.open) {return}
	testing.expect_value(t, app.pointer_target(s, w, caption.x, caption.y), app.Pointer_Target.Tab_Menu)
	menu, _ := app.tab_menu_rect(w)
	testing.expect(t, !pointer_inside(menu, caption.x, caption.y), "the caption must lie outside the menu")
	pointer_expect_move(t, s, w, caption.x, caption.y + 1, .Arrow)
	testing.expect_value(t, w.caption_hover, -1)
	gesture_button(s, w, .Left, true, caption.x, caption.y)
	gesture_button(s, w, .Left, false, caption.x, caption.y)
	testing.expect(t, !w.tab_menu.open, "a press off the menu closes it")
	testing.expect(t, ui.armed_down(w.caption_armed) == false, "the press must not reach the caption")
	testing.expect_value(t, len(s.windows), windows)
}

// A release belongs to the surface that took the press, even over another surface's button.
@(test)
pointer_release_reaches_the_press_owner :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-release-owner") {return}
	s, w := &f.state, f.state.windows[0]
	windows := len(s.windows)
	ui.find_open(&w.find)
	l, _ := app.find_controls(w, app.focused_session(s, w))
	close := pointer_centre(l.close)
	caption := [2]f32{f32(w.width) - 23 * w.scale, 20 * w.scale}
	testing.expect_value(t, app.pointer_target(s, w, caption.x, caption.y), app.Pointer_Target.Caption)
	gesture_button(s, w, .Left, true, close.x, close.y)
	gesture_button(s, w, .Left, false, caption.x, caption.y)
	testing.expect(t, w.find.open, "a release off the find close button must not close the bar")
	testing.expect(t, !ui.armed_down(w.find.armed))
	testing.expect_value(t, len(s.windows), windows)

	gesture_button(s, w, .Left, true, caption.x, caption.y)
	gesture_button(s, w, .Left, false, close.x, close.y)
	testing.expect(t, !ui.armed_down(w.caption_armed))
	testing.expect(t, w.find.open, "a caption press must not close the find bar on release")
	testing.expect_value(t, len(s.windows), windows)
}

// A settings page under the find bar loses its row hover as soon as the bar takes the pointer.
@(test)
pointer_settings_hover_clears_under_the_find_bar :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-settings-find") {return}
	s, w := &f.state, f.state.windows[0]
	w.width, w.height = i32(1400 * w.scale), i32(900 * w.scale)
	app.window_relayout(s, w)
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	ui.find_open(&w.find)
	fl, _ := app.find_controls(w, app.focused_session(s, w))
	el := app.settings_layout(w)
	row := [2]f32{el.list.x + el.list.width / 2, el.list.y + el.row_height / 2}
	if !testing.expect(t, !pointer_inside(fl.panel, row.x, row.y), "the row must lie outside the bar") {return}
	testing.expect_value(t, app.pointer_target(s, w, row.x, row.y), app.Pointer_Target.Settings_Page)
	pointer_expect_move(t, s, w, row.x, row.y, .Arrow)
	if !testing.expect(t, w.editor.hover_item >= 0, "the settings row must take the hover") {return}
	close := pointer_centre(fl.close)
	testing.expect_value(t, app.pointer_target(s, w, close.x, close.y), app.Pointer_Target.Find)
	pointer_expect_move(t, s, w, close.x, close.y, .Hand)
	testing.expect_value(t, w.editor.hover_item, -1)
}
