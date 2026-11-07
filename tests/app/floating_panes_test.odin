package app_test

import "aio:input"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:ui"

@(test)
floating_capsules_fit_inside_the_available_row :: proc(t: ^testing.T) {
	widths := []f32{160, 160, 160, 160}
	start, gap := app.floating_capsule_row_fit(widths, 300, 8)
	testing.expect_value(t, start, f32(0))
	testing.expect_value(t, gap, f32(8))
	for width in widths {testing.expect_value(t, width, f32(69))}
	end := start + gap * f32(len(widths) - 1)
	for width in widths {end += width}
	testing.expect(t, end <= 300)

	roomy := []f32{80, 100}
	start, gap = app.floating_capsule_row_fit(roomy, 300, 8)
	testing.expect_value(t, start, f32(112))
	testing.expect_value(t, gap, f32(8))

	narrow := []f32{96, 96, 96, 96}
	start, gap = app.floating_capsule_row_fit(narrow, 3, 8)
	end = start + gap * f32(len(narrow) - 1)
	for width in narrow {
		testing.expect(t, width > 0)
		end += width
	}
	testing.expect(t, end <= 3)
}

@(test)
floating_drag_geometry_clamps_moves_edges_and_bounds :: proc(t: ^testing.T) {
	area := layout.Rect{10, 20, 800, 600}
	original := layout.Rect{210, 170, 400, 300}

	moved := app.floating_drag_rect(area, original, {-500, 700}, {}, 1)
	testing.expect_value(t, moved, layout.Rect{10, 320, 400, 300})

	left := app.floating_drag_rect(area, original, {500, 0}, {.Left}, 1)
	testing.expect_value(t, left, layout.Rect{370, 170, 240, 300})
	right := app.floating_drag_rect(area, original, {-500, 0}, {.Right}, 1)
	testing.expect_value(t, right, layout.Rect{210, 170, 240, 300})
	top := app.floating_drag_rect(area, original, {0, 500}, {.Top}, 1)
	testing.expect_value(t, top, layout.Rect{210, 350, 400, 120})
	bottom := app.floating_drag_rect(area, original, {0, -500}, {.Bottom}, 1)
	testing.expect_value(t, bottom, layout.Rect{210, 170, 400, 120})

	bounds := app.floating_bounds_for_rect(area, original)
	testing.expect_value(t, bounds, layout.Rect{0.25, 0.25, 0.5, 0.5})
}

// A window of two tiled panes with the focused one floated above them, and that float's frame.
@(private = "file")
float_fixture :: proc(
	t: ^testing.T,
	f: ^Palette_Fixture,
	name: string,
) -> (
	s: ^app.App,
	w: ^app.Window,
	frame: layout.Rect,
	ok: bool,
) {
	if !palette_fixture_create(t, f, name, second_window = false) {return}
	s, w = &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	app.floating_toggle(s, w)
	if !testing.expect_value(t, len(app.floating_rects(w)), 1) {return}
	frame, ok = layout.float_rect(w.tree, w.tree.focus, app.floating_area(w))
	ok = testing.expect(t, ok)
	return
}

@(private = "file")
float_frame :: proc(w: ^app.Window) -> layout.Rect {
	frame, _ := layout.float_rect(w.tree, app.floating_rects(w)[0].node, app.floating_area(w))
	return frame
}

@(private = "file")
float_button :: proc(s: ^app.App, w: ^app.Window, x, y: f32, pressed: bool) {
	app.handle_event(
		s,
		input.Mouse_Button_Event{window = w.id, button = .Left, pressed = pressed, x = i32(x), y = i32(y)},
	)
}

@(private = "file")
float_move :: proc(s: ^app.App, w: ^app.Window, x, y: f32, held := true) {
	e := input.Mouse_Move_Event{window = w.id, x = i32(x), y = i32(y)}
	if held {e.buttons = {.Left}}
	app.handle_event(s, e)
}

@(test)
floating_header_press_moves_the_float_only_past_the_threshold :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, frame, ok := float_fixture(t, &f, "float-header-move")
	if !ok {return}
	x, y := frame.x + 40, frame.y + 10
	float_move(s, w, x, y, held = false)
	spot := w.float_header_hover.? or_else app.Float_Header_Spot{}
	testing.expect_value(t, spot.action, app.Float_Header_Action.Move)
	float_button(s, w, x, y, true)
	_, held := w.float_press.(app.Float_Header_Press)
	testing.expect(t, held)
	float_move(s, w, x + 2, y + 1)
	testing.expect_value(t, float_frame(w), frame)
	testing.expect(t, !app.floating_dragging(w), "a short travel is still a click")
	float_move(s, w, x + 40, y + 30)
	testing.expect(t, app.floating_dragging(w))
	testing.expect_value(t, float_frame(w), layout.Rect{frame.x + 40, frame.y + 30, frame.width, frame.height})
	float_button(s, w, x + 50, y + 30, false)
	testing.expect_value(t, w.float_press, nil)
	testing.expect_value(t, float_frame(w), layout.Rect{frame.x + 50, frame.y + 30, frame.width, frame.height})
}

@(test)
floating_edge_press_resizes_at_once_and_a_move_without_the_button_ends_it :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, frame, ok := float_fixture(t, &f, "float-edge-resize")
	if !ok {return}
	x, y := frame.x + frame.width - 1, frame.y + frame.height / 2
	float_button(s, w, x, y, true)
	resize, resizing := w.float_press.(app.Float_Resize)
	testing.expect(t, resizing)
	testing.expect_value(t, resize.edges, app.Float_Edges{.Right})
	float_move(s, w, x + 2, y)
	testing.expect_value(t, float_frame(w).width, frame.width + 2)
	float_move(s, w, x + 30, y, held = false)
	testing.expect_value(t, w.float_press, nil)
	testing.expect_value(t, float_frame(w).width, frame.width + 2)
}

@(test)
floating_header_buttons_fire_only_on_release_over_themselves :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, frame, ok := float_fixture(t, &f, "float-header-buttons")
	if !ok {return}
	minimize := app.floating_header_buttons(w, frame)[0]
	mx, my := minimize.x + minimize.width / 2, minimize.y + minimize.height / 2
	float_button(s, w, mx, my, true)
	testing.expect(t, app.floating_button_pressed(w, .Minimize))
	testing.expect(t, !app.floating_button_pressed(w, .Close))
	float_move(s, w, frame.x + 40, frame.y + 10)
	float_button(s, w, frame.x + 40, frame.y + 10, false)
	testing.expect_value(t, w.float_press, nil)
	testing.expect_value(t, len(app.floating_capsules(w)), 0)
	float_button(s, w, mx, my, true)
	float_button(s, w, mx, my, false)
	if !testing.expect_value(t, len(app.floating_capsules(w)), 1) {return}

	// The capsule row moves as one from a press that travels, and only a click restores.
	group := w.float_capsule_group
	cx, cy := group.x + group.width / 2, group.y + group.height / 2
	// A notice in the same corner would take the press.
	for len(ui.notices_live(&s.notices)) > 0 {_ = ui.notices_dismiss(&s.notices, s.notices.items[0].id)}
	ui.notices_set_animations(&s.notices, false)
	testing.expect_value(t, app.pointer_target(s, w, cx, cy), app.Pointer_Target.Floating)
	float_button(s, w, cx, cy, true)
	press, pressed := w.float_press.(app.Float_Capsules_Press)
	testing.expect(t, pressed && press.capsule != nil)
	testing.expect_value(t, w.float_capsule_anchor, nil)
	float_move(s, w, cx - 60, cy - 40)
	_, moving := w.float_press.(app.Float_Capsules_Move)
	testing.expect(t, moving)
	testing.expect_value(t, w.float_capsule_group.x, group.x - 60)
	testing.expect_value(t, w.float_capsule_group.y, group.y - 40)
	float_button(s, w, cx - 60, cy - 40, false)
	testing.expect(t, w.float_capsule_anchor != nil)
	testing.expect_value(t, len(app.floating_capsules(w)), 1)
	group = w.float_capsule_group
	cx, cy = group.x + group.width / 2, group.y + group.height / 2
	float_button(s, w, cx, cy, true)
	float_button(s, w, cx, cy, false)
	testing.expect_value(t, len(app.floating_capsules(w)), 0)
	testing.expect_value(t, len(app.floating_rects(w)), 1)
}

// Defect: leaving the window cleared the capsule hover but kept the float header's, which stayed lit.
@(test)
floating_header_hover_ends_when_the_pointer_leaves_the_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, frame, ok := float_fixture(t, &f, "float-hover-leave")
	if !ok {return}
	float_move(s, w, frame.x + 40, frame.y + 10, held = false)
	app.update_motion(s)
	testing.expect_value(t, w.float_header_motion.hover.value, f32(1))
	app.handle_event(s, platform.Mouse_Leave_Event{window = w.id})
	app.update_motion(s)
	testing.expect_value(t, w.float_header_motion.hover.value, f32(0))
}

// Defect: a move cut short by capture loss left the float where it stood without scheduling the layout
// save a release schedules.
@(test)
floating_drag_cut_short_saves_where_the_float_stands :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, frame, ok := float_fixture(t, &f, "float-drag-cancel")
	if !ok {return}
	app.layout_state_enable(s, strings.clone("float-drag-cancel.json"))
	defer app.layout_state_disable(s)
	x, y := frame.x + 40, frame.y + 10
	float_button(s, w, x, y, true)
	float_move(s, w, x + 40, y + 30)
	moved := layout.Rect{frame.x + 40, frame.y + 30, frame.width, frame.height}
	testing.expect_value(t, float_frame(w), moved)
	// Re-enabling sets aside any save the press scheduled, so only the cut-short move can schedule one.
	app.layout_state_enable(s, strings.clone("float-drag-cancel.json"))
	app.handle_event(s, platform.Focus_Event{w.id, false})
	_, scheduled := app.layout_state_deadline(s)
	testing.expect(t, scheduled)
	float_move(s, w, x + 90, y + 60)
	testing.expect_value(t, float_frame(w), moved)
}
