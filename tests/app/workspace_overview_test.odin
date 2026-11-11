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
