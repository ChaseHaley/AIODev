package app_test

import "core:testing"
import "core:time"
import app "../../src"
import "aio:views"
import "cosmos:ui"

// Folding a group widens the tabs that stay. Every tab, and New tab, goes straight from where it drew to where
// it rests, all at one pace, from the first frame on: none starts elsewhere or bows off its path (WORK-454).
@(test)
a_fold_moves_every_tab_straight_from_where_it_drew :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "fold-motion", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	app.window_resize(s, w, 900, 300)
	for _ in 0 ..< 6 {_, _ = app.tab_create(s, w.workspace)}
	s.settings.tabs.orientation = .Horizontal
	app.window_apply_settings(s, w)
	app.workspace_tab_choose(w.workspace, 2)
	group := app.tab_group_create(s, w, 2, "Group")
	if !testing.expect(t, group != nil) {return}
	id := group.id
	app.tab_group_add(s, w, 3, id)
	app.tab_group_add(s, w, 4, id)
	app.workspace_tab_choose(w.workspace, 0)
	app.window_render(s, w)
	count := len(w.workspace.tabs)
	// Where each tab, then New tab, draws.
	places :: proc(s: ^app.App, w: ^app.Window, out: []f32) {
		bar := app.window_tab_bar(s, w)
		for i in 0 ..< len(out) - 1 {out[i] = app.tab_strip_x(w, bar, i)}
		out[len(out) - 1] = views.tab_new_rect(bar).x
	}
	before := make([]f32, count + 1, context.temp_allocator)
	places(s, w, before)
	s.animations = true
	testing.expect(t, app.tab_group_fold(s, w, id, true))
	now := make([]f32, count + 1, context.temp_allocator)
	places(s, w, now)
	for x, i in now {testing.expectf(t, abs(x - before[i]) < 0.01, "item %d draws at %v, not %v", i, x, before[i])}
	at := time.tick_now()
	frames := make([dynamic][]f32, context.temp_allocator)
	for step in 0 ..< 40 {
		frame := ui.Frame_Time{display = time.tick_add(at, time.Duration(step) * 4 * time.Millisecond)}
		frame.period = 4 * time.Millisecond
		app.window_motion_update(s, w, frame)
		sample := make([]f32, count + 1, context.temp_allocator)
		places(s, w, sample)
		append(&frames, sample)
	}
	after := frames[len(frames) - 1]
	widened := false
	last: f32
	for sample in frames {
		pace: f32 = -1
		for x, i in sample {
			span := after[i] - before[i]
			if abs(span) < 1 {continue}
			widened ||= i > 4
			share := (x - before[i]) / span
			if pace < 0 {pace = share; continue}
			testing.expectf(t, abs(share - pace) < 0.002, "item %d is %v of the way, others %v", i, share, pace)
		}
		testing.expectf(t, pace >= last - 0.0001 && pace <= 1.0001, "the pace runs on: %v after %v", pace, last)
		last = max(last, pace)
	}
	testing.expect(t, widened, "the tabs after the group move")
	testing.expectf(t, abs(last - 1) < 0.0001, "every item reaches its rest: %v", last)
}
