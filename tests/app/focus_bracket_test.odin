package app_test

import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:term"
import "aio:ui"

// The window has entered exactly the pane it shows focused.
@(private)
focus_holds_shown :: proc(w: ^app.Window) -> bool {
	entered, ok := w.focus_bracket.(app.Focus_Entered)
	tree := app.window_tree(w)
	if !ok || tree == nil || tree.focus == layout.INVALID_NODE {return false}
	pane, is_pane := tree.nodes[tree.focus].(layout.Pane)
	return is_pane && entered.content == pane.content
}

@(test)
focus_bracket_holds_the_pane_each_change_shows :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "focus-bracket-changes", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	testing.expect(t, focus_holds_shown(w), "a window opens holding its pane")
	first := app.window_tree(w).focus
	app.pane_split(s, w, .Right)
	split := app.window_tree(w).focus != first
	testing.expect(t, split && focus_holds_shown(w), "a split enters the new pane")
	app.pane_focus(s, w, first)
	testing.expect(t, focus_holds_shown(w))
	app.tab_new(s, w)
	testing.expect(t, focus_holds_shown(w), "a new tab enters its pane")
	app.tab_select(s, w, 0)
	testing.expect(t, focus_holds_shown(w))
	app.pane_close(s, w)
	testing.expect(t, focus_holds_shown(w), "closing the focused pane enters the one that remains")

	app.focus_leave(s, w)
	testing.expect(t, w.focus_bracket == nil)
	ui.find_open(&w.find)
	app.focus_leave(s, w)
	testing.expect(t, ui.find_is_open(&w.find), "a window that has left already stays as it is")
	app.focus_enter(s, w)
	testing.expect(t, focus_holds_shown(w))
}

@(test)
focus_bracket_entering_another_pane_leaves_the_one_that_held_focus :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "focus-bracket-enter", second_window = false) {return}
	s := &f.state
	w := s.windows[0]
	first := app.window_tree(w).focus
	app.pane_split(s, w, .Right)
	ui.find_open(&w.find)
	previous := app.focused_session(s, w).session
	term.search_set_needle(previous, "focus")
	testing.expect(t, term.search_summary(previous).progress != .Off)
	w.selection = app.Selection_Selecting{}
	// A change of focus that skipped focus_leave: entering takes focus from the pane that still holds it.
	app.window_tree(w).focus = first
	app.focus_enter(s, w)
	testing.expect(t, focus_holds_shown(w))
	testing.expect(t, !ui.find_is_open(&w.find) && !app.selection_active(w))
	testing.expect(t, term.search_summary(previous).progress == .Off, "the departed pane's search closes")

	ui.find_open(&w.find)
	app.focus_enter(s, w)
	testing.expect(t, ui.find_is_open(&w.find), "entering the pane that holds focus leaves nothing")
	testing.expect(t, focus_holds_shown(w))
}
