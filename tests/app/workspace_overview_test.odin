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
		_, _, deleting := app.workspace_overview_deletion(w)
		testing.expect(t, !deleting, "a plain switch plays no deletion")
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

// Three workspaces, the deleted one shown and its frame drawn, with animations on for the deletion.
@(private = "file")
delete_fixture :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string, shown: int) -> (deleted, next: ^app.Workspace, ok: bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.workspace_new(s, w, false, name_it = false)
	app.workspace_new(s, w, false, name_it = false)
	if !testing.expect_value(t, len(s.workspaces), 3) {return}
	deleted = s.workspaces[shown]
	next = s.workspaces[(shown + 1) % 3]
	if !testing.expect(t, app.workspace_select(s, w, deleted)) {return}
	w.dirty = true
	app.window_render(s, w)
	s.animations = true
	app.workspace_delete_accept(s, w, app.workspace_delete_plan(s, deleted))
	return deleted, next, testing.expect(t, w.workspace == next) && testing.expect_value(t, len(s.workspaces), 2)
}

// Deleting the shown middle workspace plays its deletion: the window zooms out onto its card and holds there
// while it crumbles to dust; the card below slides up into its place, and the window zooms into it there.
// The dust draws from a texture of the card made on its first frame.
@(test)
deleting_a_middle_workspace_crumbles_it_and_slides_the_next_into_its_place :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	_, _, ok := delete_fixture(t, &f, "workspace-overview-delete", 1)
	if !ok {return}
	s := &f.state
	w := s.windows[0]
	camera, flying := app.workspace_overview_camera(w)
	testing.expect(t, flying)
	testing.expect_value(t, camera, app.Overview_Camera{1, 1})
	testing.expect_value(t, app.workspace_overview_shown_card(w), 2)
	first := overview_frame(time.tick_now())
	last_dust, last_slide, lowest := f32(0), f32(0), f32(1)
	captured := false
	for step in 0 ..< 200 {
		app.window_motion_update(s, w, overview_frame(time.tick_add(first.display, time.Duration(step) * 20 * time.Millisecond)))
		camera, flying = app.workspace_overview_camera(w)
		if !flying {break}
		dust, slide, deleting := app.workspace_overview_deletion(w)
		if !testing.expect(t, deleting) {return}
		testing.expect(t, dust >= last_dust && slide >= last_slide, "the dust and the slide only go forward")
		testing.expect(t, slide == 0 || dust > 0.5, "the cards below slide once the dust is well under way")
		testing.expect_value(t, camera.card, f32(1))
		lowest = min(lowest, camera.scale)
		last_dust, last_slide = dust, slide
		if dust > 0.2 && !captured {
			testing.expect(t, app.window_build_frame(s, w))
			testing.expect(t, w.overview.deletion.key != 0, "the card crumbles from a texture of itself")
			testing.expect(t, !w.overview.deletion.failed)
			captured = true
		}
	}
	testing.expect(t, !flying, "the overview ends")
	testing.expect(t, captured)
	testing.expect(t, lowest < 0.31, "the window zooms out to the column")
	testing.expect_value(t, last_dust, f32(1))
	testing.expect_value(t, last_slide, f32(1))
	_, _, deleting := app.workspace_overview_deletion(w)
	testing.expect(t, !deleting, "the deletion ends with the flight")
}

// Deleting the last workspace replaces it with the first, so nothing slides up: the window travels up the
// column to the first card while the deleted one crumbles.
@(test)
deleting_the_last_workspace_travels_to_the_first :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	_, _, ok := delete_fixture(t, &f, "workspace-overview-delete-last", 2)
	if !ok {return}
	s := &f.state
	w := s.windows[0]
	camera, flying := app.workspace_overview_camera(w)
	testing.expect_value(t, camera, app.Overview_Camera{1, 2})
	first := overview_frame(time.tick_now())
	last_card := camera.card
	for step in 0 ..< 200 {
		app.window_motion_update(s, w, overview_frame(time.tick_add(first.display, time.Duration(step) * 20 * time.Millisecond)))
		camera, flying = app.workspace_overview_camera(w)
		if !flying {break}
		testing.expect(t, camera.card <= last_card, "the camera travels one way, up to the first card")
		last_card = camera.card
	}
	testing.expect(t, !flying, "the overview ends")
	testing.expect_value(t, last_card, f32(0))
}
