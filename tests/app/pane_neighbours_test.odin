package app_test

import "core:slice"
import "core:testing"
import app "../../src"
import "aio:platform"

// A host window showing pane A beside pane B, with B then moved to a linked window placed by `place`
// relative to the host: the desktop arrangement directional focus crosses (WORK-479).
@(private = "file")
Cross_Fixture :: struct {
	palette:      Palette_Fixture,
	host, linked: ^app.Window,
	// Sessions of the host's pane and the linked pane.
	a, b:         u32,
}

@(private = "file")
Place :: enum {
	Left,
	Right,
	Above,
	// Over the host, a little down and right, as a new linked window opens.
	Over,
}

@(private = "file", require_results)
cross_fixture_create :: proc(t: ^testing.T, f: ^Cross_Fixture, name: string, place: Place) -> bool {
	if !palette_fixture_create(t, &f.palette, name, second_window = false) {return false}
	s := &f.palette.state
	f.host = s.windows[0]
	f.a = cross_focused(s, f.host)
	app.pane_split(s, f.host, .Right)
	f.b = cross_focused(s, f.host)
	app.pane_link_toggle(s, f.host)
	if !testing.expect_value(t, len(s.windows), 2) {return false}
	f.linked = s.windows[1]
	app.pane_links_sync(s)
	if !testing.expect(t, f.linked.phase == .Shown) {return false}
	hx, hy, host_error := platform.window_to_screen(&s.platform, f.host.id, 0, 0)
	if !testing.expect_value(t, host_error, platform.Error.None) {return false}
	x, y: i32
	switch place {
	case .Left:
		x, y = hx - i32(f.linked.width) - 40, hy + 100
	case .Right:
		x, y = hx + i32(f.host.width) + 40, hy - 100
	case .Above:
		x, y = hx + 50, hy - i32(f.linked.height) - 40
	case .Over:
		x, y = hx + 32, hy + 32
	}
	if !testing.expect_value(t, platform.window_set_position(&s.platform, f.linked.id, x, y), platform.Error.None) {
		return false
	}
	// The tests run inactive, so they deliver the host's focus themselves; the jump list starts on A.
	app.handle_event(s, platform.Focus_Event{f.host.id, true})
	app.focus_jumps_track(s)
	if !testing.expect(t, f.a != 0 && f.b != 0 && f.a != f.b) {return false}
	return testing.expect_value(t, cross_focused(s, f.host), f.a)
}

@(private = "file")
cross_focused :: proc(s: ^app.App, w: ^app.Window) -> u32 {
	entry := app.focused_session(s, w)
	return entry != nil ? entry.id : 0
}

// What a tick does after its events: linked windows follow their tabs, then the jump list records.
@(private = "file")
cross_settle :: proc(s: ^app.App) {
	app.pane_links_sync(s)
	app.focus_jumps_track(s)
}

// Focus Left from the host's only pane reaches the linked window on its left, Right comes back, and Right
// from the host, where nothing lies, leaves focus where it is.
@(test)
directional_focus_crosses_to_a_linked_window_on_the_left_and_back :: proc(t: ^testing.T) {
	f: Cross_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !cross_fixture_create(t, &f, "dirnav-left", .Left) {return}
	s := &f.palette.state

	target, _ := app.pane_neighbour_toward(s, f.host, .Left)
	testing.expect(t, target == f.linked)
	app.run_action(s, f.host, .Focus_Left)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.linked.id)
	testing.expect_value(t, cross_focused(s, f.linked), f.b)

	app.run_action(s, f.linked, .Focus_Right)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.host.id)
	testing.expect_value(t, cross_focused(s, f.host), f.a)

	// Nothing is right of the host, and nothing is left of the linked window.
	target, _ = app.pane_neighbour_toward(s, f.host, .Right)
	testing.expect(t, target == f.host)
	app.run_action(s, f.host, .Focus_Right)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.host.id)
	testing.expect_value(t, cross_focused(s, f.host), f.a)
	target, _ = app.pane_neighbour_toward(s, f.linked, .Left)
	testing.expect(t, target == f.linked)
}

// The linked window on the right, offset upward, still overlaps the host across the move and is reached;
// Left from it returns to the host.
@(test)
directional_focus_crosses_to_a_linked_window_on_the_right :: proc(t: ^testing.T) {
	f: Cross_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !cross_fixture_create(t, &f, "dirnav-right", .Right) {return}
	s := &f.palette.state

	app.run_action(s, f.host, .Focus_Right)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.linked.id)
	app.run_action(s, f.linked, .Focus_Left)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.host.id)
	testing.expect_value(t, cross_focused(s, f.host), f.a)
}

// A linked window above the host is reached with Up, and Down comes back; Left and Right do not reach it.
@(test)
directional_focus_crosses_to_a_linked_window_above :: proc(t: ^testing.T) {
	f: Cross_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !cross_fixture_create(t, &f, "dirnav-above", .Above) {return}
	s := &f.palette.state

	for direction in ([]app.Action{.Focus_Left, .Focus_Right, .Focus_Down}) {
		app.run_action(s, f.host, direction)
		cross_settle(s)
		testing.expect_value(t, s.focus_jumps.window, f.host.id)
	}
	app.run_action(s, f.host, .Focus_Up)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.linked.id)
	testing.expect_value(t, cross_focused(s, f.linked), f.b)
	app.run_action(s, f.linked, .Focus_Down)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.host.id)
}

// A linked window hidden with its tab is no candidate: from another tab, Left stays put. Selecting the tab
// again shows the window and Left reaches it.
@(test)
directional_focus_ignores_a_hidden_linked_window :: proc(t: ^testing.T) {
	f: Cross_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !cross_fixture_create(t, &f, "dirnav-hidden", .Left) {return}
	s := &f.palette.state

	if _, created := app.tab_create(s, f.host.workspace); !testing.expect(t, created) {return}
	app.tab_select(s, f.host, 1)
	cross_settle(s)
	if !testing.expect(t, f.linked.phase == .Hidden) {return}
	other := cross_focused(s, f.host)
	target, _ := app.pane_neighbour_toward(s, f.host, .Left)
	testing.expect(t, target == f.host)
	app.run_action(s, f.host, .Focus_Left)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.window, f.host.id)
	testing.expect_value(t, cross_focused(s, f.host), other)

	app.tab_select(s, f.host, 0)
	cross_settle(s)
	if !testing.expect(t, f.linked.phase == .Shown) {return}
	target, _ = app.pane_neighbour_toward(s, f.host, .Left)
	testing.expect(t, target == f.linked)
}

// Crossing records the pane it lands on in pane history, without waiting for the window focus event the
// activation brings, so Back returns across the windows.
@(test)
directional_focus_across_windows_records_pane_history :: proc(t: ^testing.T) {
	f: Cross_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !cross_fixture_create(t, &f, "dirnav-history", .Left) {return}
	s := &f.palette.state

	app.run_action(s, f.host, .Focus_Left)
	cross_settle(s)
	testing.expectf(t, slice.equal(s.focus_jumps.entries[:], []u32{f.a, f.b}), "entries %v, want %v",
		s.focus_jumps.entries[:], []u32{f.a, f.b})
	app.run_action(s, f.linked, .Focus_Right)
	cross_settle(s)
	testing.expectf(t, slice.equal(s.focus_jumps.entries[:], []u32{f.a, f.b, f.a}), "entries %v",
		s.focus_jumps.entries[:])
	app.focus_jump(s, f.host, -1)
	cross_settle(s)
	testing.expect_value(t, s.focus_jumps.index, 1)
	testing.expect_value(t, s.focus_jumps.window, f.linked.id)
}

// A linked window over its host: a pane beside the focused one in the same window wins, though a host pane
// behind the window lies nearer that way.
@(test)
directional_focus_stays_in_a_linked_window_over_its_host :: proc(t: ^testing.T) {
	f: Cross_Fixture
	defer palette_fixture_destroy(t, &f.palette)
	if !cross_fixture_create(t, &f, "dirnav-over", .Over) {return}
	s := &f.palette.state

	app.pane_split(s, f.linked, .Right)
	c := cross_focused(s, f.linked)
	if !testing.expect(t, c != 0 && c != f.b) {return}
	target, _ := app.pane_neighbour_toward(s, f.linked, .Left)
	testing.expect(t, target == f.linked)
	app.run_action(s, f.linked, .Focus_Left)
	testing.expect_value(t, cross_focused(s, f.linked), f.b)
	testing.expect_value(t, cross_focused(s, f.host), f.a)
}
