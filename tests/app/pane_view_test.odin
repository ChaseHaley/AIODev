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
			view_set(w, .Screen)
			app.window_relayout(s, w)
			testing.expect_value(t, len(w.panes), 1)
			testing.expect_value(t, w.panes[0].rect, layout.Rect{0, 0, f32(w.width), f32(w.height)})
			view_set(w, .Split)
			app.window_relayout(s, w)
			testing.expect_value(t, len(w.panes), 2)
			testing.expect(t, w.panes[0].rect.y >= app.window_title_height(w))
		}
	}
}

// A fullscreen state is set by hand because leaving one the platform never entered does nothing, so
// these tests check every path out of it without covering the owner's monitor. tests/live enters it.
@(private = "file")
view_set :: proc(w: ^app.Window, view: layout.Pane_View) {
	tree := app.window_tree(w)
	tree.fill, tree.zoomed = layout.pane_view_parts(view)
	w.pane_fill = tree.fill
}

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
	testing.expect_value(t, w.pane_fill, app.window_tree(w).fill, loc = loc)
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
			view_set(w, layout.pane_view_of(fill, zoomed))
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
		view_set(w, layout.pane_view_of(.Screen, c.zoomed))
		app.run_action(s, w, c.action)
		testing.expect_value(t, app.pane_view_current(w), c.expected)
		view_expect_coherent(t, s, w)
	}
}

// Each tab keeps its own view: a window showing a tab takes that tab's, and the tab it leaves keeps its.
@(test)
pane_view_each_tab_keeps_its_own_view :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-tabs")
	if !ok {return}
	first := app.window_tree(w)
	app.tab_new(s, w)
	app.pane_split(s, w, .Right)
	second := app.window_tree(w)
	testing.expect(t, first != second)

	for left in layout.Pane_View {
		for right in layout.Pane_View {
			app.tab_select(s, w, 0)
			view_set(w, left)
			app.tab_select(s, w, 1)
			view_set(w, right)
			app.window_relayout(s, w)
			app.tab_select(s, w, 0)
			testing.expect_value(t, app.pane_view_current(w), left)
			testing.expect_value(t, layout.pane_view_of(second.fill, second.zoomed), right)
			view_expect_coherent(t, s, w)
			app.tab_select(s, w, 1)
			testing.expect_value(t, app.pane_view_current(w), right)
			testing.expect_value(t, layout.pane_view_of(first.fill, first.zoomed), left)
			view_expect_coherent(t, s, w)
		}
	}
}

// Closing the shown tab shows the next one in the view that tab kept.
@(test)
pane_view_closing_the_shown_tab_shows_the_next_tabs_view :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-tab-close")
	if !ok {return}
	app.run_action(s, w, .Zoom_Pane)
	app.tab_new(s, w)
	app.run_action(s, w, .Fill_Window_Pane)
	app.tab_close(s, w, w.workspace.selected)
	testing.expect_value(t, len(w.workspace.tabs), 1)
	testing.expect_value(t, app.pane_view_current(w), layout.Pane_View.Zoom)
	view_expect_coherent(t, s, w)
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
pane_view_size_checks_use_the_area_panes_return_to :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	s, w, ok := view_fixture(t, &f, "view-trial")
	if !ok {return}
	before := app.pane_trial_split(s, w, .Right, 0.5)
	testing.expect_value(t, before.error, app.Pane_Trial_Error.None)
	view_set(w, .Screen)
	app.window_relayout(s, w)
	during := app.pane_trial_split(s, w, .Right, 0.5)
	testing.expect_value(t, during.error, app.Pane_Trial_Error.None)
	testing.expect_value(t, during.rect, before.rect)
	testing.expect_value(t, w.pane_fill, layout.Pane_Fill.Screen)
}
