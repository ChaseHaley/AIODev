package app_test

import "core:testing"
import "core:time"
import app "../../src"
import "aio:ui"

@(private = "file")
overview_frame :: proc(display: time.Tick) -> ui.Frame_Time {
	return {display = display, period = 16 * time.Millisecond}
}

// Switching workspace flies the window out to the column of workspaces, along it to the one chosen and back
// into it: the camera starts at full size on the workspace left, zooms out to the column on the way, and
// lands at full size on the workspace shown, which ends the overview. Without animations it shows at once.
@(test)
switching_workspace_flies_through_the_overview :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "workspace-overview", second_window = false) {return}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	original := w.workspace
	w.dirty = true
	app.window_render(s, w)

	app.workspace_new(s, w, false, name_it = false)
	if !testing.expect(t, w.workspace != original) {return}
	camera, flying := app.workspace_overview_camera(w)
	testing.expect(t, flying)
	testing.expect_value(t, camera, app.Overview_Camera{1, 0})
	first := overview_frame(time.tick_now())
	lowest, last_card := f32(1), f32(0)
	for step in 0 ..< 80 {
		app.window_motion_update(s, w, overview_frame(time.tick_add(first.display, time.Duration(step) * 20 * time.Millisecond)))
		camera, flying = app.workspace_overview_camera(w)
		if !flying {break}
		lowest = min(lowest, camera.scale)
		testing.expect(t, camera.card >= last_card, "the camera travels one way, toward the new workspace")
		last_card = camera.card
		// The column draws: the new workspace live, the one left from its kept frame.
		if step == 25 {testing.expect(t, app.window_build_frame(s, w))}
	}
	testing.expect(t, !flying, "the overview ends")
	testing.expect(t, lowest < 0.31, "the window zooms out to the column on the way")
	testing.expect_value(t, last_card, f32(1))

	s.animations = false
	if !testing.expect(t, app.workspace_select(s, w, original)) {return}
	_, flying = app.workspace_overview_camera(w)
	testing.expect(t, !flying)
}

// Deleting the shown middle workspace flies on to the one after it, which the delete moves up the list. The
// column keeps the deleted workspace's card for the flight, so the camera leaves from it and lands on the
// card the shown workspace draws in, not on the empty place below it.
@(test)
deleting_a_middle_workspace_lands_on_the_card_it_shows :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "workspace-overview-delete", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.workspace_new(s, w, false, name_it = false)
	middle := w.workspace
	app.workspace_new(s, w, false, name_it = false)
	last := w.workspace
	if !testing.expect(t, app.workspace_select(s, w, middle)) {return}
	w.dirty = true
	app.window_render(s, w)

	s.animations = true
	app.workspace_delete_accept(s, w, app.workspace_delete_plan(s, middle))
	if !testing.expect(t, w.workspace == last) {return}
	testing.expect_value(t, len(s.workspaces), 2)
	camera, flying := app.workspace_overview_camera(w)
	testing.expect(t, flying)
	testing.expect_value(t, camera, app.Overview_Camera{1, 1})
	shown := app.workspace_overview_shown_card(w)
	testing.expect_value(t, shown, 2)
	first := overview_frame(time.tick_now())
	last_card := camera.card
	for step in 0 ..< 80 {
		app.window_motion_update(s, w, overview_frame(time.tick_add(first.display, time.Duration(step) * 20 * time.Millisecond)))
		camera, flying = app.workspace_overview_camera(w)
		if !flying {break}
		last_card = camera.card
		testing.expect_value(t, app.workspace_overview_shown_card(w), shown)
		// The column draws with the deleted workspace's card in its place.
		if step == 25 {testing.expect(t, app.window_build_frame(s, w))}
	}
	testing.expect(t, !flying, "the overview ends")
	testing.expect_value(t, last_card, f32(shown))
}
