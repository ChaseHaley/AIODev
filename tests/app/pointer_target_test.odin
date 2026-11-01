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
