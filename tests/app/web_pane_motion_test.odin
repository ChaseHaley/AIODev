package app_test

import "core:testing"
import "core:time"
import app "../../src"
import "cosmos:ui"

// A web page is a DirectComposition visual over the app's frame, so it takes part in a transition only by
// being placed each frame where its pane draws. These tests read that decision, which headless builds
// make too, though they have no WebView2 to apply it to.

@(private = "file")
page_frame :: proc(display: time.Tick) -> ui.Frame_Time {
	return {display = display, period = 16 * time.Millisecond}
}

// Draws the frame w shows at `display` and returns where it placed the page of web pane `id`.
@(private = "file")
page_at :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, id: u32, display: time.Tick) -> app.Web_Placement {
	app.window_motion_update(s, w, page_frame(display))
	testing.expect(t, app.window_build_frame(s, w))
	return app.web_find(s, id).placement
}

// Builds a frame with nothing moving, as the window shows between transitions.
@(private = "file")
page_settled :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, id: u32) -> app.Web_Placement {
	start := time.tick_now()
	_ = page_at(t, s, w, id, start)
	return page_at(t, s, w, id, time.tick_add(start, 2 * time.Second))
}

// A terminal beside a web page, the page focused and drawn at rest. Returns the page's pane id.
@(private = "file")
page_beside_terminal :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (id: u32, ok: bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return 0, false}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	if !testing.expect(t, app.web_open_focused(s, w, "https://example.com/page")) {return 0, false}
	if !testing.expect_value(t, len(s.web_panes), 1) {return 0, false}
	id = s.web_panes[0].id
	rest := page_settled(t, s, w, id)
	return id, testing.expect(t, rest.visible && rest.scale == 1, "the page shows in its pane at rest")
}

// Changing tabs slides the tab left out across the panes' area; its page slides out with its pane and
// hides only when the slide ends. Animations off, it hides at once.
@(test)
web_page_slides_out_with_its_tab :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	id, ok := page_beside_terminal(t, &f, "web-page-tabs")
	if !ok {return}
	s, w := &f.state, f.state.windows[0]
	rest := app.web_find(s, id).placement

	app.tab_new(s, w)
	if !testing.expect(t, app.pane_motion_animating(w)) {return}
	start := time.tick_now()
	sliding := page_at(t, s, w, id, time.tick_add(start, 60 * time.Millisecond))
	testing.expect(t, sliding.visible, "the page stays while its tab slides out")
	testing.expect(t, sliding.visual.x < rest.visual.x, "the page slides left with its pane, away from the new tab")
	stage, sliding_stage := w.pane_motion.slide.?
	left := f32(sliding.visual.x) + sliding.clip_l
	testing.expect(t, sliding_stage && left >= stage.x - 0.5, "clipped to the stage")
	testing.expect_value(t, sliding.bounds.x, sliding.visual.x)
	testing.expect_value(t, sliding.bounds.width, rest.bounds.width)
	gone := page_at(t, s, w, id, time.tick_add(start, 2 * time.Second))
	testing.expect(t, !app.pane_motion_animating(w))
	testing.expect(t, !gone.visible, "the page hides once the slide ends")

	// Back to its tab: it slides in from the left and shows throughout.
	app.tab_select(s, w, 0)
	start = time.tick_now()
	entering := page_at(t, s, w, id, time.tick_add(start, 60 * time.Millisecond))
	testing.expect(t, entering.visible && entering.visual.x < rest.visual.x, "the page slides in from the left")
	back := page_at(t, s, w, id, time.tick_add(start, 2 * time.Second))
	testing.expect(t, back.visible && back.visual == rest.visual)

	s.animations = false
	app.tab_select(s, w, 1)
	testing.expect(t, !app.pane_motion_animating(w))
	instant := page_at(t, s, w, id, time.tick_now())
	testing.expect(t, !instant.visible, "without animations the page hides with its tab at once")
}

// Zooming the terminal grows it over the page, which stays put beneath it; the growing pane draws in an
// overlay above the page's level. Zooming back shrinks it off the page, shown again from the start.
// Zooming the page itself grows it above a second page.
@(test)
web_page_stays_beneath_a_pane_zooming_over_it :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	id, ok := page_beside_terminal(t, &f, "web-page-zoom")
	if !ok {return}
	s, w := &f.state, f.state.windows[0]
	rest := app.web_find(s, id).placement

	app.run_action(s, w, .Focus_Left)
	_ = page_settled(t, s, w, id)
	app.run_action(s, w, .Zoom_Pane)
	if !testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_raising(w)) {return}
	start := time.tick_now()
	covered := page_at(t, s, w, id, time.tick_add(start, 60 * time.Millisecond))
	testing.expect(t, covered.visible, "the page stays while the terminal grows over it")
	testing.expect_value(t, covered.visual, rest.visual)
	testing.expect_value(t, covered.level, rest.level)
	testing.expect(t, w.web.split_count >= 2, "the growing terminal draws in an overlay above the page")
	zoomed := page_at(t, s, w, id, time.tick_add(start, 2 * time.Second))
	testing.expect(t, !zoomed.visible, "the zoomed terminal hides the page once it has grown")

	app.run_action(s, w, .Zoom_Pane)
	if !testing.expect(t, app.pane_motion_animating(w) && app.pane_motion_raising(w)) {return}
	start = time.tick_now()
	uncovered := page_at(t, s, w, id, time.tick_add(start, 60 * time.Millisecond))
	testing.expect(t, uncovered.visible, "the page shows beneath the terminal shrinking off it")
	testing.expect_value(t, uncovered.visual, rest.visual)
	_ = page_at(t, s, w, id, time.tick_add(start, 2 * time.Second))

	// A second page below the first; zooming the first grows its page above the second's.
	app.run_action(s, w, .Focus_Right)
	if !testing.expect(t, app.web_open_focused(s, w, "https://example.com/second")) {return}
	if !testing.expect_value(t, len(s.web_panes), 2) {return}
	second := s.web_panes[1].id
	_ = page_settled(t, s, w, second)
	app.run_action(s, w, .Focus_Left)
	_ = page_settled(t, s, w, id)
	if !testing.expect(t, app.web_active(w)) {return}
	app.run_action(s, w, .Zoom_Pane)
	start = time.tick_now()
	growing := page_at(t, s, w, id, time.tick_add(start, 60 * time.Millisecond))
	beneath := app.web_find(s, second).placement
	testing.expect(t, growing.visible && beneath.visible, "both pages show while one grows over the other")
	testing.expect(t, growing.level > beneath.level, "the growing page sits above the one it covers")
	testing.expect(t, f32(growing.bounds.width) > growing.clip_r - growing.clip_l, "laid out at its zoomed size")
	_ = page_at(t, s, w, id, time.tick_add(start, 2 * time.Second))
	testing.expect(t, !app.web_find(s, second).placement.visible, "the covered page hides once covered")

	s.animations = false
	app.run_action(s, w, .Zoom_Pane)
	testing.expect(t, !app.pane_motion_animating(w))
	both := page_at(t, s, w, id, time.tick_now())
	testing.expect(t, both.visible && app.web_find(s, second).placement.visible, "without animations at once")
}

// Switching workspace shrinks the window into its card in the overview: the page of the workspace left
// shrinks with its card and stays there as the camera travels away, and a page of the workspace arrived
// at shrinks with the live card. Both show only while the overview plays.
@(test)
web_page_flies_with_its_workspace_card :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	id, ok := page_beside_terminal(t, &f, "web-page-workspace")
	if !ok {return}
	s, w := &f.state, f.state.windows[0]
	original := w.workspace
	rest := app.web_find(s, id).placement

	app.workspace_new(s, w, false, name_it = false)
	if !testing.expect(t, w.workspace != original) {return}
	start := time.tick_now()
	smallest := f32(1)
	shown_frames := 0
	for step in 0 ..< 80 {
		_, flying := app.workspace_overview_camera(w)
		if !flying {break}
		p := page_at(t, s, w, id, time.tick_add(start, time.Duration(step) * 20 * time.Millisecond))
		if !p.visible {continue}
		shown_frames += 1
		smallest = min(smallest, p.scale)
		testing.expect_value(t, p.bounds.width, rest.bounds.width)
	}
	testing.expect(t, shown_frames > 10, "the page stays in the card of the workspace left")
	testing.expect(t, smallest < 0.31, "the page shrinks with its card to the column's scale")
	gone := page_settled(t, s, w, id)
	testing.expect(t, !gone.visible, "the page hides when the overview ends")

	// Back to the page's workspace: its page shrinks with the live card and grows back to rest.
	if !testing.expect(t, app.workspace_select(s, w, original)) {return}
	start = time.tick_now()
	shown_frames, smallest = 0, 1
	for step in 0 ..< 80 {
		_, flying := app.workspace_overview_camera(w)
		if !flying {break}
		p := page_at(t, s, w, id, time.tick_add(start, time.Duration(step) * 20 * time.Millisecond))
		if p.visible {shown_frames += 1; smallest = min(smallest, p.scale)}
	}
	testing.expect(t, shown_frames > 10 && smallest < 0.31, "the arriving page flies in with its card")
	back := page_settled(t, s, w, id)
	testing.expect(t, back.visible && back.scale == 1 && back.visual == rest.visual)

	s.animations = false
	app.workspace_new(s, w, false, name_it = false)
	_, flying := app.workspace_overview_camera(w)
	testing.expect(t, !flying)
	instant := page_at(t, s, w, id, time.tick_now())
	testing.expect(t, !instant.visible, "without animations the page hides with its workspace at once")
}
