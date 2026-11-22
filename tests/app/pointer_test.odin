package app_test

import "cosmos:input"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "cosmos:render"
import "aio:ui"

@(private)
pointer_expect_move :: proc(
	t: ^testing.T,
	s: ^app.App,
	w: ^app.Window,
	x, y: f32,
	shape: platform.Cursor_Shape,
) {
	before := s.verify.pointer_updates
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = i32(x), y = i32(y)})
	testing.expect_value(t, w.pointer_shape, shape)
	testing.expect(t, s.verify.pointer_updates - before <= 1, "one move must not flash another cursor")
}

@(test)
pointer_settings_page_and_fields_change_shape_once_per_move :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-settings", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	l := app.settings_layout(w)
	for offset in 0 ..< 4 {
		pointer_expect_move(t, s, w, l.list.x - 8 * w.scale,
			l.list.y + l.row_height + f32(offset), .Arrow)
	}
	pointer_expect_move(t, s, w, l.filter.x + l.filter.width / 2,
		l.filter.y + l.filter.height / 2, .Text)
	h, found := gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	pointer_expect_move(t, s, w, h.title.x + h.title.width / 2,
		h.title.y + h.title.height / 2, .Arrow)
}

@(test)
pointer_palette_scope_tabs_use_hand_query_uses_text :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-palette", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.palette_open(s, w)
	for mode in ui.Palette_Mode {
		ui.palette_set_mode(&s.palette, &s.registry, mode)
		l := ui.palette_layout(&s.palette, f32(w.width), f32(w.height), w.scale)
		// The query's text ends at the keyboard button, which takes the hand.
		pointer_expect_move(t, s, w, l.keys.x - 20 * w.scale, l.input.y + l.input.height / 2, .Text)
		pointer_expect_move(t, s, w, l.keys.x + l.keys.width / 2, l.keys.y + l.keys.height / 2, .Hand)
		r := l.modes[mode]
		pointer_expect_move(t, s, w, r.x + r.width / 2, r.y + r.height / 2, .Hand)
		gesture_button(s, w, .Left, true, r.x + r.width / 2, r.y + r.height / 2)
		gesture_button(s, w, .Left, false, r.x + r.width / 2, r.y + r.height / 2)
		testing.expect_value(t, s.palette.mode, mode)
		pointer_expect_move(t, s, w, l.footer.x + l.footer.width - 4,
			l.footer.y + l.footer.height / 2, .Arrow)
	}
}

@(private = "file")
pointer_center :: proc(r: render.Rect) -> (f32, f32) {return r.x + r.width / 2, r.y + r.height / 2}

@(test)
pointer_tabs_use_hand_except_on_the_selected_tab_body :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{false, true}) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "pointer-tabs", "profile.default.command = cmd.exe\n") {return}
		s, w := &f.state, f.state.windows[0]
		w.tabs_horizontal = horizontal
		w.width, w.height, w.scale = 1000, 700, 1
		w.rail_wide, w.rail = true, app.Rail_Docked{}
		app.window_relayout(s, w)
		app.tab_new(s, w)
		app.tab_select(s, w, 0)
		app.update_motion(s)
		body, other, close: render.Rect
		if horizontal {
			body, other = app.window_tab_rect(s, w, 0), app.window_tab_rect(s, w, 1)
			close = app.window_tab_close_rect(s, w, 0)
		} else {
			l, ok := app.rail_current_layout(w)
			if !testing.expect(t, ok) {continue}
			body, other = app.rail_row_rect_for_tab(w, 0), app.rail_row_rect_for_tab(w, 1)
			close = ui.rail_close_rect(l, 0, w.scale)
		}
		x, y := pointer_center(close)
		pointer_expect_move(t, s, w, body.x + 6, body.y + body.height / 2, .Arrow)
		pointer_expect_move(t, s, w, x, y, .Hand)
		x, y = pointer_center(other)
		pointer_expect_move(t, s, w, other.x + 6, y, .Hand)
		x, y = pointer_center(app.tab_orientation_button_rect(w))
		pointer_expect_move(t, s, w, x, y, .Hand)
		pane := w.panes[0].rect
		pointer_expect_move(t, s, w, pane.x + pane.width / 2, pane.y + pane.height / 2, .Text)
	}
}

@(test)
pointer_settings_controls_use_hand :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pointer-controls", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	l := app.settings_layout(w)
	if !testing.expect(t, pointer_settings_select_top(w, "pane.markdown_floating")) {return}
	x, y := pointer_center(ui.editor_row_parts(&w.editor, l, w.editor.selected).toggle)
	pointer_expect_move(t, s, w, x, y, .Hand)
	if !testing.expect(t, pointer_settings_select_top(w, "font.family")) {return}
	parts := ui.editor_row_parts(&w.editor, l, w.editor.selected)
	x, y = pointer_center(parts.field)
	pointer_expect_move(t, s, w, x, y, .Hand)
	x, y = pointer_center(parts.reset)
	pointer_expect_move(t, s, w, x, y, .Hand)
	h, found := gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	x, y = pointer_center(h.buttons[.Split_Right])
	pointer_expect_move(t, s, w, x, y, .Hand)
}

// Selection keeps a row inside the fitted page, possibly on its last row under the fixture's notice toast.
@(private)
pointer_settings_select_top :: proc(w: ^app.Window, key: string) -> bool {
	if !ui.editor_select_key(&w.editor, key) {return false}
	w.editor.scroll = w.editor.selected
	return true
}

// Fullscreen hides the title bar and tabs, so the pane header at the top edge owns the pointer there, with
// either tab orientation: each button takes the hand, its hover and its press, and a click runs it. The
// hidden caption buttons and tab strip once kept claiming that strip, so the header showed the arrow and no
// hover, Split right did nothing and Close closed the window.
@(test)
pointer_fullscreen_pane_header_owns_the_top_edge :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{false, true}) {
		f: Palette_Fixture
		defer palette_fixture_destroy(t, &f)
		if !palette_fixture_create(t, &f, "pointer-fullscreen-header", second_window = false) {return}
		s, w := &f.state, f.state.windows[0]
		s.animations = false
		w.tabs_horizontal = horizontal
		app.window_relayout(s, w)
		app.pane_split(s, w, .Right)
		app.run_action(s, w, .Fullscreen_Pane)
		if !testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Screen) {return}
		if !testing.expect_value(t, len(w.panes), 1) {return}
		pane := w.panes[0]
		view: ^app.Pane_View
		for &candidate in w.views {if candidate.content == pane.content {view = &candidate}}
		if !testing.expect(t, view != nil) {return}
		l := app.pane_header_layout(w, pane)
		for r, button in l.buttons {
			if r.width <= 0 || app.pane_header_refused(w, pane, button) != .None {continue}
			x, y := pointer_center(r)
			testing.expectf(t, app.pointer_target(s, w, x, y) == .Pane_Header,
				"horizontal tabs %v: %v belongs to the header, not %v", horizontal, button,
				app.pointer_target(s, w, x, y))
			pointer_expect_move(t, s, w, x, y, .Hand)
			testing.expectf(t, view.header_hover == button, "horizontal tabs %v: %v hovers", horizontal, button)
			testing.expectf(t, w.caption_hover == nil && w.tab_hover == nil,
				"horizontal tabs %v: no hidden caption button or tab hovers over %v", horizontal, button)
		}

		// A press arms the button and a release away from it runs nothing.
		x, y := pointer_center(l.buttons[.Zoom])
		gesture_button(s, w, .Left, true, x, y)
		testing.expectf(t, ui.armed_is(view.header_armed, app.Pane_Header_Target(app.Pane_Header_Button.Zoom)),
			"horizontal tabs %v: Zoom shows its press", horizontal)
		gesture_button(s, w, .Left, false, pane.rect.x + pane.rect.width / 2, pane.rect.y + pane.rect.height / 2)
		testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Screen)

		gesture_click_header(s, w, .Split_Right, l)
		testing.expectf(t, len(w.panes) == 3, "horizontal tabs %v: Split right splits", horizontal)

		app.run_action(s, w, .Fullscreen_Pane)
		if !testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Screen) {return}
		gesture_click_header(s, w, .Close, app.pane_header_layout(w, w.panes[0]))
		testing.expect_value(t, len(s.windows), 1)
		testing.expectf(t, len(w.panes) == 2, "horizontal tabs %v: Close closes the pane", horizontal)
	}
}
