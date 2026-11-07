package app_test

import "core:testing"
import app "../../src"
import "aio:layout"

@(test)
pane_view_fullscreen_pane_reaches_every_client_edge :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-screen-edges")
	if !ok {return}
	for scale in ([?]f32{1, 1.25, 1.75, 2}) {
		w.scale = scale
		for gap in ([?]int{0, 4, 24}) {
			s.settings.pane.gap = gap
			w.pane_fill = .Screen
			app.window_relayout(s, w)
			testing.expect_value(t, len(w.panes), 1)
			testing.expect_value(t, w.panes[0].rect, layout.Rect{0, 0, f32(w.width), f32(w.height)})
			w.pane_fill = .None
			app.window_relayout(s, w)
			testing.expect_value(t, len(w.panes), 2)
			testing.expect(t, w.panes[0].rect.y >= app.window_title_height(w))
		}
	}
}

// A fullscreen state is set by hand because leaving one the platform never entered does nothing, so
// these tests check every path out of it without covering the owner's monitor. tests/live enters it.
@(private = "file")
view_fixture :: proc(t: ^testing.T, f: ^Palette_Fixture, name: string) -> (^app.App, ^app.Window, bool) {
	if !palette_fixture_create(t, f, name, second_window = false) {return nil, nil, false}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	return s, w, testing.expect_value(t, len(w.panes), 2)
}

// What must hold in every view: one place decides the pane count, the dividers and the chrome.
@(private = "file")
view_expect_coherent :: proc(t: ^testing.T, s: ^app.App, w: ^app.Window, loc := #caller_location) {
	solo := app.pane_view_current(w) != .Split
	testing.expect_value(t, solo, app.pane_view_solo(w), loc = loc)
	if solo {
		testing.expect_value(t, len(w.panes), 1, loc = loc)
		testing.expect_value(t, w.panes[0].node, app.window_tree(w).focus, loc = loc)
		testing.expect_value(t, len(w.dividers), 0, loc = loc)
	} else {
		testing.expect_value(t, len(w.panes), app.tab_pane_count(app.selected_tab(w.workspace)), loc = loc)
	}
	testing.expect_value(t, app.window_title_height(w) == 0, w.pane_fill == .Screen, loc = loc)
	testing.expect_value(t, app.rail_visible(w) && w.pane_fill != .None, false, loc = loc)
}

@(test)
pane_view_split_ends_every_view :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-split")
	if !ok {return}
	for fill in layout.Pane_Fill {
		for zoomed in ([?]bool{false, true}) {
			w.pane_fill, app.window_tree(w).zoomed = fill, zoomed
			app.window_relayout(s, w)
			view_expect_coherent(t, s, w)
			app.pane_split(s, w, .Down)
			testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Split)
			testing.expect_value(t, len(w.panes), 3)
			view_expect_coherent(t, s, w)
			app.pane_close(s, w)
			testing.expect_value(t, len(w.panes), 2)
		}
	}
}

// The layout suite owns the exhaustive transition table. Here each action must also update chrome
// and pane geometry, including the regression where leaving Fill used to leave the tab zoomed.
@(test)
pane_view_leaving_fill_clears_the_tabs_zoom :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-actions")
	if !ok {return}
	cases := [?]struct {action: app.Action, expected: layout.Pane_View} {
		{.Fill_Window_Pane, .Fill},
		{.Zoom_Pane, .Zoom},
		{.Fill_Window_Pane, .Fill_Over_Zoom},
		{.Zoom_Pane, .Zoom},
		{.Zoom_Pane, .Split},
		{.Zoom_Pane, .Zoom},
		{.Fill_Window_Pane, .Fill_Over_Zoom},
		{.Fill_Window_Pane, .Split},
		{.Fill_Window_Pane, .Fill},
		{.Fill_Window_Pane, .Split},
	}
	for c in cases {
		app.run_action(s, w, c.action)
		testing.expect_value(t, app.pane_view_current(w), c.expected)
		view_expect_coherent(t, s, w)
		if c.expected == .Split {
			testing.expect(t, !app.window_tree(w).zoomed)
			testing.expect_value(t, len(w.panes), 2)
		}
	}
}

@(test)
pane_view_leaving_fullscreen_by_any_toggle_lands_where_the_table_says :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-screen")
	if !ok {return}
	cases := [?]struct {
		action:   app.Action,
		zoomed:   bool,
		expected: layout.Pane_View,
	} {
		{.Zoom_Pane, false, .Zoom},
		{.Fill_Window_Pane, false, .Fill},
		{.Fullscreen_Pane, false, .Split},
		{.Zoom_Pane, true, .Zoom},
		{.Fill_Window_Pane, true, .Fill_Over_Zoom},
		{.Fullscreen_Pane, true, .Split},
	}
	for c in cases {
		w.pane_fill, app.window_tree(w).zoomed = .Screen, c.zoomed
		app.run_action(s, w, c.action)
		testing.expect_value(t, app.pane_view_current(w), c.expected)
		view_expect_coherent(t, s, w)
	}
}

@(test)
pane_view_fill_follows_the_window_across_tabs_and_leaves_their_zoom_alone :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-tabs")
	if !ok {return}
	first := app.window_tree(w)
	app.run_action(s, w, .Zoom_Pane)
	app.tab_new(s, w)
	app.pane_split(s, w, .Right)
	second := app.window_tree(w)
	testing.expect(t, first != second)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Split)

	app.run_action(s, w, .Fill_Window_Pane)
	view_expect_coherent(t, s, w)
	app.tab_select(s, w, 0)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Fill_Over_Zoom)
	view_expect_coherent(t, s, w)
	app.tab_select(s, w, 1)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Fill)
	view_expect_coherent(t, s, w)

	app.run_action(s, w, .Fill_Window_Pane)
	testing.expect_value(t, len(w.panes), 2)
	testing.expect(t, first.zoomed)
	testing.expect(t, !second.zoomed)
}

@(test)
pane_view_only_closing_the_focused_pane_ends_a_view :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-close")
	if !ok {return}
	app.pane_split(s, w, .Down)
	hidden := w.panes[0].node
	if hidden == app.window_tree(w).focus {hidden = w.panes[1].node}
	app.run_action(s, w, .Fill_Window_Pane)
	app.pane_close_at(s, w.workspace, w.workspace.selected, hidden)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.Content)
	view_expect_coherent(t, s, w)
	app.pane_close(s, w)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Split)
	view_expect_coherent(t, s, w)
}

@(test)
pane_view_moving_focus_keeps_the_view_and_shows_the_new_pane :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-focus")
	if !ok {return}
	app.run_action(s, w, .Fill_Window_Pane)
	before := app.window_tree(w).focus
	app.run_action(s, w, .Focus_Left)
	testing.expect(t, app.window_tree(w).focus != before)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.Content)
	view_expect_coherent(t, s, w)
}

@(test)
pane_view_a_split_on_a_hidden_tab_ends_the_view_when_that_tab_is_shown :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-hidden")
	if !ok {return}
	app.tab_new(s, w)
	app.run_action(s, w, .Fill_Window_Pane)
	hidden := &w.workspace.tabs[0].tree
	_, err := app.pane_split_at(s, w, w.workspace, 0, hidden.focus, .Down, 0.5, false, {}, false)
	testing.expect_value(t, err, app.Pane_Split_Error.None)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.Content)
	app.tab_select(s, w, 0)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Split)
	testing.expect_value(t, len(w.panes), 3)
}

@(test)
pane_view_size_checks_use_the_area_panes_return_to :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-trial")
	if !ok {return}
	before := app.pane_trial_split(s, w, .Right, 0.5)
	testing.expect_value(t, before.error, app.Pane_Trial_Error.None)
	w.pane_fill = .Screen
	app.window_relayout(s, w)
	during := app.pane_trial_split(s, w, .Right, 0.5)
	testing.expect_value(t, during.error, app.Pane_Trial_Error.None)
	testing.expect_value(t, during.rect, before.rect)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.Screen)
}
