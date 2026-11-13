package app_test

import "core:fmt"
import "core:math"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:layout"
import "aio:render"
import "aio:ui"

// WORK-483 label turns run on the default 160 ms, made linear here so a sample lands at a known progress.
@(private = "file")
TURN :: 160 * time.Millisecond
@(private = "file")
PERIOD :: 16 * time.Millisecond

// A window whose one tab holds A on the left, B top right and C bottom right, focused on C, each pane's
// session named after its id so every pane gives the tab another title. Label turns are linear.
@(private = "file")
label_fixture :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (^app.App, ^app.Window, bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return nil, nil, false}
	s := &f.state
	s.animations = true
	w := s.windows[0]
	app.pane_split(s, w, .Right)
	app.pane_split(s, w, .Down)
	for &entry in s.sessions {
		delete(entry.name)
		entry.name = fmt.aprintf("pane %d", entry.id)
	}
	s.settings.motion.specs[.Tab_Label] = {curve = "linear"}
	label_settle(s, w)
	return s, w, testing.expect_value(t, len(w.panes), 3)
}

// Lets every motion finish, then draws, so each label rests and knows what its draw stacked.
@(private = "file")
label_settle :: proc(s: ^app.App, w: ^app.Window) {
	now := time.tick_now()
	app.window_motion_update(s, w, {display = now, period = PERIOD})
	app.window_motion_update(s, w, {display = time.tick_add(now, 4 * TURN), period = PERIOD})
	w.dirty = true
	app.window_render(s, w)
}

// Runs `action` and samples the motion that follows `after` into it; the frame sampled.
@(private = "file")
label_step :: proc(s: ^app.App, w: ^app.Window, action: app.Action, after: time.Duration) -> ui.Frame_Time {
	app.run_action(s, w, action)
	first := ui.Frame_Time{display = time.tick_now(), period = PERIOD}
	app.window_motion_update(s, w, first)
	// The motion started one refresh before the first frame.
	sample := ui.Frame_Time{display = time.tick_add(first.display, after - PERIOD), period = PERIOD}
	app.window_motion_update(s, w, sample)
	return sample
}

@(private = "file")
label_of :: proc(w: ^app.Window) -> ^app.Tab_Label {
	return app.tab_label_find(w, w.workspace.tabs[0].id)
}

@(private = "file")
focused :: proc(w: ^app.Window) -> layout.Content {
	content, _ := layout.focused_content(&w.workspace.tabs[0].tree)
	return content
}

// Moving focus turns the tab's label: halfway to edge on a quarter of the way in, the old title on its way out
// opposite the side focus moved to and the new one coming in from it, along the strip and the rail alike.
@(test)
tab_label_turns_the_way_focus_moves :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := label_fixture(t, &f, "tab-label-turns")
	if !ok {return}
	Step :: struct {
		action: app.Action,
		toward: [2]f32,
	}
	steps := [?]Step{{.Focus_Up, {0, -1}}, {.Focus_Down, {0, 1}}, {.Focus_Left, {-1, 0}}, {.Focus_Right, {1, 0}}}
	for horizontal in ([?]bool{true, false}) {
		w.tabs_horizontal = horizontal
		app.window_relayout(s, w)
		// Back to C at the bottom right, from wherever focus is.
		app.run_action(s, w, .Focus_Right)
		app.run_action(s, w, .Focus_Down)
		label_settle(s, w)
		for step in steps {
			before := focused(w)
			old_title := fmt.tprintf("pane %d", before.id)
			label_step(s, w, step.action, TURN / 4)
			label := label_of(w)
			if !testing.expectf(t, label != nil && focused(w) != before, "%v moves focus", step.action) {return}
			testing.expectf(t, ui.motion_active(label.turn), "%v: the label turns", step.action)
			testing.expect_value(t, label.from, before)
			testing.expect_value(t, label.toward, step.toward)
			testing.expectf(t, abs(label.turn.value - 0.25) < 0.01, "%v: progress %v", step.action, label.turn.value)
			testing.expect(t, app.window_animating(s, w))

			tile, built := app.tab_tile(s, w, 0)
			testing.expect_value(t, built, render.Build_Status.Ok)
			if !testing.expectf(t, tile.turn.turning, "%v: the tile shows the turn", step.action) {continue}
			testing.expect_value(t, tile.turn.title, old_title)
			testing.expect_value(t, tile.title, fmt.tprintf("pane %d", focused(w).id))
			testing.expect_value(t, tile.turn.toward, step.toward)
			testing.expect(t, abs(ui.tab_turn_width(tile.turn.progress) - math.cos(f32(math.PI) / 4)) < 0.02)
			leaving, entering := ui.tab_turn_offsets(tile.turn, {100, 30})
			testing.expect(t, leaving.x * step.toward.x + leaving.y * step.toward.y < 0)
			testing.expect(t, entering.x * step.toward.x + entering.y * step.toward.y > 0)
			// The rail and the strip draw the turn mid-way.
			w.dirty = true
			app.window_render(s, w)
			testing.expect(t, ui.motion_active(label_of(w).turn))

			label_settle(s, w)
			label = label_of(w)
			testing.expect(t, !ui.motion_active(label.turn))
			testing.expect_value(t, label.front, focused(w))
			testing.expect(t, !app.window_animating(s, w), "a label at rest draws no more frames")
		}
	}
}

// Focus moving on mid-turn keeps the face drawn at the width it has and its title where it is: before
// halfway the label goes on turning away from the pane it was leaving, after halfway it turns away from the
// pane focus just left, and focus going back unwinds the turn.
@(test)
tab_label_retargets_from_what_it_draws :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := label_fixture(t, &f, "tab-label-retarget")
	if !ok {return}
	size := [2]f32{100, 30}
	Case :: struct {
		into:   time.Duration,
		then:   app.Action,
		// What the label turns from afterwards: the pane it was leaving, or the one focus just left.
		keeps:  bool,
		toward: [2]f32,
	}
	cases := [?]Case {
		{TURN / 4, .Focus_Left, true, {-1, 0}},
		{TURN * 3 / 4, .Focus_Left, false, {-1, 0}},
		{TURN / 4, .Focus_Down, false, {0, 1}},
	}
	for c in cases {
		// Back to C at the bottom right, from wherever focus is, then up to B.
		app.run_action(s, w, .Focus_Right)
		app.run_action(s, w, .Focus_Down)
		label_settle(s, w)
		lower := focused(w)
		sample := label_step(s, w, .Focus_Up, c.into)
		upper := focused(w)
		if !testing.expect(t, upper != lower) {return}
		before, built := app.tab_tile(s, w, 0)
		testing.expect_value(t, built, render.Build_Status.Ok)
		p := label_of(w).turn.value
		testing.expect(t, before.turn.turning)
		leaving, entering := ui.tab_turn_offsets(before.turn, size)

		app.run_action(s, w, c.then)
		// A resuming frame retargets without starting the motion, so it shows what the retarget left.
		app.window_motion_update(s, w, {display = sample.display, period = PERIOD, resuming = true})
		label := label_of(w)
		testing.expect_value(t, label.from, c.keeps ? lower : upper)
		testing.expect_value(t, label.toward, c.toward)
		testing.expect(t, abs(label.turn.value - (c.keeps ? p : 1 - p)) < 0.001)
		testing.expect(t, abs(ui.tab_turn_width(label.turn.value) - ui.tab_turn_width(p)) < 0.001)
		after, after_built := app.tab_tile(s, w, 0)
		testing.expect_value(t, after_built, render.Build_Status.Ok)
		if !testing.expect(t, after.turn.turning) {continue}
		now_leaving, _ := ui.tab_turn_offsets(after.turn, size)
		// The title turning away goes on from where it drew: the one leaving, or the one that was coming in.
		was := c.keeps ? leaving : entering
		testing.expectf(t, abs(now_leaving.x - was.x) < 0.01 && abs(now_leaving.y - was.y) < 0.01,
			"%v at %v: the leaving title jumped from %v to %v", c.then, c.into, was, now_leaving)
		if c.then == .Focus_Down {
			testing.expect_value(t, focused(w), lower)
			testing.expect(t, abs(after.turn.start.x) < 0.001 && abs(after.turn.start.y) < 0.001)
		}
		label_settle(s, w)
	}
}

// A label rests when nothing about it changes: animations off, its motion off, a pane that looks the same,
// a tab seen for the first time and a switch of tab. Its timing comes from the Tab Label motion settings,
// inheriting Panes.
@(test)
tab_label_rests_when_nothing_turns :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := label_fixture(t, &f, "tab-label-rests")
	if !ok {return}

	s.animations = false
	label_step(s, w, .Focus_Up, TURN / 4)
	testing.expect(t, !ui.motion_active(label_of(w).turn), "animations off")
	testing.expect_value(t, label_of(w).front, focused(w))
	s.animations = true
	label_settle(s, w)

	s.settings.motion.specs[.Tab_Label] = {on = false}
	label_step(s, w, .Focus_Down, TURN / 4)
	testing.expect(t, !ui.motion_active(label_of(w).turn), "Tab Label motion off")
	label_settle(s, w)

	s.settings.motion.specs[.Tab_Label] = {}
	s.settings.motion.specs[.Panes] = {duration = 400}
	label_step(s, w, .Focus_Up, TURN / 4)
	testing.expect_value(t, label_of(w).turn.duration, 400 * time.Millisecond)
	s.settings.motion.specs[.Panes] = {}
	label_settle(s, w)

	// Every pane named alike: focus moves, the label looks the same, and its first draw ends the turn.
	for &entry in s.sessions {
		delete(entry.name)
		entry.name = strings.clone("Same")
	}
	label_step(s, w, .Focus_Down, 0)
	w.dirty = true
	app.window_render(s, w)
	testing.expect(t, !ui.motion_active(label_of(w).turn), "a label that looks the same")
	label_settle(s, w)

	app.tab_new(s, w)
	app.window_motion_update(s, w, {display = time.tick_now(), period = PERIOD})
	for tab in w.workspace.tabs {
		label := app.tab_label_find(w, tab.id)
		if testing.expect(t, label != nil) {testing.expect(t, !ui.motion_active(label.turn), "a new tab")}
	}
	label_settle(s, w)
	app.tab_select(s, w, 0)
	app.window_motion_update(s, w, {display = time.tick_now(), period = PERIOD})
	testing.expect(t, !app.tab_labels_turning(w), "switching tabs")
}
