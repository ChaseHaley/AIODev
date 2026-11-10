package app_test

import "core:testing"
import app "../../src"
import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:ui"

@(private = "file")
move :: proc(s: ^app.App, w: ^app.Window, x, y: f32) {
	app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = i32(x), y = i32(y)})
}

// The glyph of the pane the view shows alone; empty when its header carries none.
@(private = "file")
glyph :: proc(w: ^app.Window) -> render.Rect {
	for pane in app.window_tiled_rects(w) {
		if pane.node == layout.focus_tiled(app.window_tree(w)) {return app.pane_header_layout(w, pane).widget}
	}
	return {}
}

// Only a view that shows one of several tiled panes carries the glyph: never the split view, nor a zoomed
// pane alone in its tab. Hovering it opens the map in every view, Fullscreen included, where the title bar's
// controls are gone from above the header.
@(test)
hidden_panes_glyph_shows_while_a_view_hides_panes :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "hidden-panes-glyph", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.animations = false
	app.run_action(s, w, .Zoom_Pane)
	testing.expect_value(t, glyph(w), render.Rect{})
	app.run_action(s, w, .Zoom_Pane)
	app.pane_split(s, w, .Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	for pane in w.panes {testing.expect_value(t, app.pane_header_layout(w, pane).widget, render.Rect{})}
	for action in ([?]app.Action{.Zoom_Pane, .Fill_Window_Pane, .Fullscreen_Pane}) {
		app.run_action(s, w, action)
		g := glyph(w)
		if !testing.expectf(t, g.width > 0 && g.height > 0, "%v shows the glyph", action) {continue}
		header := app.pane_header_layout(w, w.panes[0])
		testing.expectf(t, header.title.x >= g.x + g.width, "%v: the title follows the glyph", action)
		move(s, w, g.x + g.width / 2, g.y + g.height / 2)
		testing.expectf(t, w.hidden_panes.reveal.open, "%v: hovering the glyph opens the map", action)
		move(s, w, f32(w.width) / 2, f32(w.height) - 40)
		app.run_action(s, w, action)
		testing.expectf(t, glyph(w) == {}, "leaving %v drops the glyph", action)
	}
}

// Hovering the glyph opens the map, which stays open across the gap, while the pointer heads diagonally for
// a far card over the header, and over its cells; a press on another pane shows that pane in the same view.
// Turning away from the map closes it.
@(test)
hidden_panes_map_switches_the_shown_pane_and_keeps_the_view :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "hidden-panes-map", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	s.animations = false
	app.pane_split(s, w, .Right)
	if !testing.expect_value(t, len(w.panes), 2) {return}
	left, right := w.panes[0], w.panes[1]
	app.pane_focus(s, w, left.node)
	app.run_action(s, w, .Zoom_Pane)
	g := glyph(w)
	if !testing.expect(t, g.width > 0) {return}

	move(s, w, g.x + g.width / 2, g.y + g.height / 2)
	testing.expect(t, w.hidden_panes.reveal.open, "hovering the glyph opens the map")
	surface := ui.hidden_panes_map_rect(g, f32(w.width), f32(w.height), w.scale)
	move(s, w, g.x + g.width / 2, (g.y + g.height + surface.y) / 2)
	testing.expect(t, w.hidden_panes.reveal.open, "the gap under the glyph keeps the map")
	move(s, w, g.x + g.width / 2, g.y + g.height / 2)
	// A tenth of the way from the glyph to the right card: past the glyph, over the header, above the map.
	apex := [2]f32{g.x + g.width / 2, g.y + g.height / 2}
	aim := apex + ([2]f32{surface.x + surface.width * 0.9, surface.y + surface.height / 2} - apex) * 0.1
	testing.expect(t, aim.x > g.x + g.width && aim.y < surface.y, "the aim leaves the glyph short of the map")
	move(s, w, aim.x, aim.y)
	testing.expect(t, w.hidden_panes.reveal.open && w.hidden_panes.reveal.aiming, "heading for the map keeps it")

	// The right pane fills the right half of the map, inside its padding.
	x, y := surface.x + surface.width * 0.75, surface.y + surface.height / 2
	move(s, w, x, y)
	testing.expect_value(t, w.hidden_panes.hovered.? or_else -1, 1)
	gesture_button(s, w, .Left, true, x, y)
	gesture_button(s, w, .Left, false, x, y)
	testing.expect_value(t, app.window_tree(w).focus, right.node)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Zoom)
	if !testing.expect_value(t, len(app.window_tiled_rects(w)), 1) {return}
	testing.expect_value(t, app.window_tiled_rects(w)[0].content, right.content)
	testing.expect(t, !w.hidden_panes.reveal.open, "choosing a pane closes the map")

	g = glyph(w)
	move(s, w, g.x + g.width / 2, g.y + g.height / 2)
	testing.expect(t, w.hidden_panes.reveal.open)
	move(s, w, g.x + g.width + 60, g.y + g.height / 2 - 6)
	testing.expect(t, !w.hidden_panes.reveal.open, "turning away along the header closes the map")
}
