package app_test

import "core:testing"
import app "../../src"
import "aio:input"
import "aio:layout"

// The float of float_fixture split in two, its right pane focused: one tiled pane below a float of two.
@(private = "file")
split_float_fixture :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (^app.App, ^app.Window, bool) {
	s, w, _, ok := float_fixture(t, f, name)
	if !ok {return nil, nil, false}
	app.pane_split(s, w, .Right)
	tree := app.window_tree(w)
	ok = testing.expect_value(t, len(app.floating_rects(w)), 2) &&
		testing.expect_value(t, len(app.window_tiled_rects(w)), 1) &&
		testing.expect(t, layout.is_floating(tree, tree.focus))
	return s, w, ok
}

@(private = "file")
rect_union :: proc(a, b: layout.Rect) -> layout.Rect {
	x, y := min(a.x, b.x), min(a.y, b.y)
	return {x, y, max(a.x + a.width, b.x + b.width) - x, max(a.y + a.height, b.y + b.height) - y}
}

// Zoom on a floating pane fills its float and nothing else: the float keeps its frame, the tiled pane and
// the tab's own view stay, and Zoom again shows the float's split.
@(test)
float_views_zoom_fills_the_float :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := split_float_fixture(t, &f, "float-zoom")
	if !ok {return}
	tree := app.window_tree(w)
	focus := tree.focus
	floats := app.floating_rects(w)
	content := rect_union(floats[0].rect, floats[1].rect)
	tiled := app.window_tiled_rects(w)[0]
	frame, _ := layout.float_rect(tree, focus, app.floating_area(w))

	app.run_action(s, w, .Zoom_Pane)
	testing.expect(t, layout.float_zoomed(tree, focus))
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Split)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.None)
	if testing.expect_value(t, len(app.floating_rects(w)), 1) {
		testing.expect_value(t, app.floating_rects(w)[0].node, focus)
		testing.expect_value(t, app.floating_rects(w)[0].rect, content)
	}
	testing.expect_value(t, app.window_tiled_rects(w)[0].rect, tiled.rect)
	after, _ := layout.float_rect(tree, focus, app.floating_area(w))
	testing.expect_value(t, after, frame)

	app.run_action(s, w, .Zoom_Pane)
	testing.expect(t, !layout.float_zoomed(tree, focus))
	testing.expect_value(t, len(app.floating_rects(w)), 2)
}

// Fill window and Fullscreen on a floating pane show it alone, as on a tiled pane; leaving returns it to
// its float above the tiled pane.
@(test)
float_views_fill_and_fullscreen_show_the_float_pane_alone :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := split_float_fixture(t, &f, "float-fill")
	if !ok {return}
	tree := app.window_tree(w)
	focus := tree.focus
	for action in ([?]app.Action{.Fill_Window_Pane, .Fullscreen_Pane}) {
		app.run_action(s, w, action)
		if action == .Fullscreen_Pane && w.pane_fill != .Screen {
			// The platform under test may refuse full screen, so the state is set by hand as
			// pane_view_test.odin does.
			floating, _ := layout.float_of(tree, focus)
			tree.fill, tree.fill_float, w.pane_fill = .Screen, floating.id, .Screen
			app.window_relayout(s, w)
		}
		testing.expect_value(t, layout.fill_floating(tree), focus)
		testing.expect(t, !tree.zoomed)
		if testing.expect_value(t, len(w.panes), 1) {
			testing.expect_value(t, w.panes[0].node, focus)
			testing.expect_value(t, w.panes[0].rect, app.window_content_area(s, w))
		}
		testing.expect_value(t, len(w.dividers), 0)
		testing.expect(t, !app.rail_visible(w))
		app.run_action(s, w, action)
		testing.expect_value(t, w.pane_fill, layout.Pane_Fill.None)
		testing.expect_value(t, len(app.floating_rects(w)), 2)
		testing.expect_value(t, len(app.window_tiled_rects(w)), 1)
	}
}

// A fill showing a floating pane shows whichever pane focus moves to; on a tiled pane it is the tiled
// fill, with the floats above it again.
@(test)
float_views_fill_follows_focus_out_of_the_float :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := split_float_fixture(t, &f, "float-fill-focus")
	if !ok {return}
	tree := app.window_tree(w)
	right := tree.focus
	app.run_action(s, w, .Fill_Window_Pane)
	app.run_action(s, w, .Focus_Left)
	testing.expect(t, tree.focus != right && layout.is_floating(tree, tree.focus))
	testing.expect_value(t, layout.fill_floating(tree), tree.focus)
	if testing.expect_value(t, len(w.panes), 1) {testing.expect_value(t, w.panes[0].node, tree.focus)}
	app.run_action(s, w, .Focus_Left)
	testing.expect(t, !layout.is_floating(tree, tree.focus))
	testing.expect_value(t, layout.fill_floating(tree), layout.INVALID_NODE)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.Content)
	testing.expect_value(t, len(app.window_tiled_rects(w)), 1)
	testing.expect_value(t, len(app.floating_rects(w)), 2)
	// Focusing the float again leaves the tiled fill with the float above it.
	app.pane_focus(s, w, right)
	testing.expect_value(t, layout.fill_floating(tree), layout.INVALID_NODE)
	testing.expect_value(t, len(app.floating_rects(w)), 2)
}

// A view chosen on a floating pane leaves the tiling's alone: zooming a float over a tiled fill keeps the
// fill, and filling the window from it takes the fill over.
@(test)
float_views_act_on_the_focused_pane_container :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := split_float_fixture(t, &f, "float-container")
	if !ok {return}
	tree := app.window_tree(w)
	floating := tree.focus
	tiled := app.window_tiled_rects(w)[0].node
	app.pane_focus(s, w, tiled)
	app.run_action(s, w, .Zoom_Pane)
	testing.expect(t, tree.zoomed)
	app.pane_focus(s, w, floating)
	app.run_action(s, w, .Zoom_Pane)
	testing.expect(t, tree.zoomed, "zooming the float keeps the tiling's zoom")
	testing.expect(t, layout.float_zoomed(tree, floating))
	app.run_action(s, w, .Zoom_Pane)
	testing.expect(t, tree.zoomed)
	testing.expect(t, !layout.float_zoomed(tree, floating))
	app.run_action(s, w, .Fill_Window_Pane)
	testing.expect_value(t, layout.fill_floating(tree), floating)
	testing.expect(t, tree.zoomed)
	app.run_action(s, w, .Fill_Window_Pane)
	testing.expect_value(t, tree.fill, layout.Pane_Fill.None)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Zoom)
}

// A zoomed float gaining a pane shows it, and losing the pane it shows ends its zoom.
@(test)
float_views_float_zoom_ends_when_its_panes_change :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := split_float_fixture(t, &f, "float-zoom-ends")
	if !ok {return}
	tree := app.window_tree(w)
	focus := tree.focus
	app.run_action(s, w, .Zoom_Pane)
	app.pane_split(s, w, .Down)
	testing.expect(t, !layout.float_zoomed(tree, focus))
	testing.expect_value(t, len(app.floating_rects(w)), 3)
	app.run_action(s, w, .Zoom_Pane)
	app.pane_close(s, w)
	testing.expect(t, !layout.float_zoomed(tree, tree.focus))
	testing.expect_value(t, len(app.floating_rects(w)), 2)
}

// Ctrl held at a corner resizes the float about its centre; letting go of Ctrl mid-drag moves only the
// grabbed edges again.
@(test)
float_views_ctrl_resize_keeps_the_centre :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, frame, ok := float_fixture(t, &f, "float-ctrl-resize")
	if !ok {return}
	tree := app.window_tree(w)
	focus := tree.focus
	x, y := frame.x + frame.width - 1, frame.y + frame.height - 1
	app.handle_event(
		s,
		input.Mouse_Button_Event {
			window = w.id, button = .Left, pressed = true, x = i32(x), y = i32(y), modifiers = {.Control},
		},
	)
	_, resizing := w.float_press.(app.Float_Resize)
	if !testing.expect(t, resizing) {return}
	held := input.Mouse_Move_Event{window = w.id, x = i32(x + 20), y = i32(y + 10), buttons = {.Left}}
	ctrl := held
	ctrl.modifiers = {.Control}
	app.handle_event(s, ctrl)
	grown, _ := layout.float_rect(tree, focus, app.floating_area(w))
	testing.expect_value(t, grown, layout.Rect{frame.x - 20, frame.y - 10, frame.width + 40, frame.height + 20})
	app.handle_event(s, held)
	plain, _ := layout.float_rect(tree, focus, app.floating_area(w))
	testing.expect_value(t, plain, layout.Rect{frame.x, frame.y, frame.width + 20, frame.height + 10})
	app.handle_event(
		s,
		input.Mouse_Button_Event{window = w.id, button = .Left, pressed = false, x = i32(x + 20), y = i32(y + 10)},
	)
}

@(test)
float_views_centred_resize_stops_at_the_nearer_side_and_the_minimum :: proc(t: ^testing.T) {
	area := layout.Rect{0, 0, 1000, 800}
	original := layout.Rect{100, 300, 400, 200}
	left := app.floating_drag_rect(area, original, {-30, 0}, {.Left}, 1, centred = true)
	testing.expect_value(t, left, layout.Rect{70, 300, 460, 200})
	// The centre is 400 from the top and bottom, so the float can be at most 800 tall.
	tall := app.floating_drag_rect(area, original, {0, -500}, {.Top}, 1, centred = true)
	testing.expect_value(t, tall, layout.Rect{100, 0, 400, 800})
	// The centre is 300 from the left edge, so the float can be at most 600 wide.
	far := app.floating_drag_rect(area, original, {500, 0}, {.Right}, 1, centred = true)
	testing.expect_value(t, far, layout.Rect{0, 300, 600, 200})
	narrow := app.floating_drag_rect(area, original, {-500, 0}, {.Right}, 1, centred = true)
	testing.expect_value(t, narrow, layout.Rect{180, 300, 240, 200})
}
