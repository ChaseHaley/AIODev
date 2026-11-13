package app_test

import "core:slice"
import "core:testing"
import app "../../src"
import "aio:platform"

@(private)
jumps_all_reachable :: proc(data: rawptr, session: u32) -> bool {return true}

@(private)
jumps_skip_two :: proc(data: rawptr, session: u32) -> bool {return session != 2}

@(test)
focus_jumps_walk_back_and_forward :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for session in ([]u32{1, 2, 2, 3}) {app.focus_jumps_note(&j, session)}
	testing.expect_value(t, len(j.entries), 3)
	session, ok := app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, ok && session == 2)
	session, ok = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, ok && session == 1)
	_, ok = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	testing.expect(t, !ok)
	// Landing on the pane the jump chose records nothing, so forward still works.
	app.focus_jumps_note(&j, 1)
	session, ok = app.focus_jumps_step(&j, 1, jumps_all_reachable, nil)
	testing.expect(t, ok && session == 2)
}

@(test)
focus_jumps_new_focus_drops_forward_path :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for session in ([]u32{1, 2, 3}) {app.focus_jumps_note(&j, session)}
	_, _ = app.focus_jumps_step(&j, -1, jumps_all_reachable, nil)
	app.focus_jumps_note(&j, 4)
	testing.expect_value(t, len(j.entries), 3)
	testing.expect_value(t, j.entries[2], 4)
	_, ok := app.focus_jumps_step(&j, 1, jumps_all_reachable, nil)
	testing.expect(t, !ok)
}

@(test)
focus_jumps_skip_closed_panes :: proc(t: ^testing.T) {
	j: app.Focus_Jumps
	defer app.focus_jumps_destroy(&j)
	for session in ([]u32{1, 2, 3}) {app.focus_jumps_note(&j, session)}
	session, ok := app.focus_jumps_step(&j, -1, jumps_skip_two, nil)
	testing.expect(t, ok && session == 1)
	testing.expect_value(t, len(j.entries), 2)
	session, ok = app.focus_jumps_step(&j, 1, jumps_skip_two, nil)
	testing.expect(t, ok && session == 3)
}

// What a tick does for the jump list after its events: linked windows follow their tabs, then the
// focused pane is recorded.
@(private = "file")
jumps_settle :: proc(s: ^app.App) {
	app.pane_links_sync(s)
	app.focus_jumps_track(s)
}

// The OS moving keyboard focus between windows; the tests run inactive, so they deliver it themselves.
@(private = "file")
jumps_focus_moves :: proc(s: ^app.App, from, to: ^app.Window) {
	app.handle_event(s, platform.Focus_Event{from.id, false})
	app.handle_event(s, platform.Focus_Event{to.id, true})
}

@(private = "file")
jumps_focused :: proc(s: ^app.App, w: ^app.Window) -> u32 {
	entry := app.focused_session(s, w)
	return entry != nil ? entry.id : 0
}

@(private = "file")
jumps_expect :: proc(t: ^testing.T, s: ^app.App, entries: []u32, index: int, loc := #caller_location) {
	testing.expectf(t, slice.equal(s.focus_jumps.entries[:], entries), "entries %v, want %v",
		s.focus_jumps.entries[:], entries, loc = loc)
	testing.expect_value(t, s.focus_jumps.index, index, loc = loc)
}

// A linked window hides as its tab is left and shows as the tab comes back. Neither is a navigation, so
// walking back into that tab and forward out of it again crosses both tabs, rather than looping between
// the panes of the tab with the linked window.
@(test)
focus_jumps_cross_a_tab_with_a_linked_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "jumps-linked", second_window = false) {return}
	s := &f.state
	host := s.windows[0]
	app.handle_event(s, platform.Focus_Event{host.id, true})
	jumps_settle(s)
	first := jumps_focused(s, host)

	// The first tab's second pane moves to a linked window, which the user then works in.
	app.pane_split(s, host, .Right)
	app.pane_link_toggle(s, host)
	if !testing.expect_value(t, len(s.windows), 2) {return}
	linked := s.windows[1]
	jumps_settle(s)
	if !testing.expect(t, linked.phase == .Shown) {return}
	jumps_focus_moves(s, host, linked)
	jumps_settle(s)
	second := jumps_focused(s, linked)

	// A second tab, chosen in the host, hides the linked window.
	if _, created := app.tab_create(s, host.workspace); !testing.expect(t, created) {return}
	jumps_focus_moves(s, linked, host)
	app.tab_select(s, host, 1)
	jumps_settle(s)
	testing.expect(t, linked.phase == .Hidden)
	third := jumps_focused(s, host)
	if !testing.expect(t, first != 0 && second != 0 && third != 0) {return}
	jumps_expect(t, s, {first, second, third}, 2)

	// Back lands in the linked window, shown again with its tab.
	app.focus_jump(s, host, -1)
	jumps_settle(s)
	testing.expect(t, linked.phase == .Shown)
	testing.expect_value(t, host.workspace.selected, 0)
	jumps_focus_moves(s, host, linked)
	jumps_settle(s)
	testing.expect_value(t, jumps_focused(s, linked), second)
	jumps_expect(t, s, {first, second, third}, 1)

	// Back again reaches the host's pane; the command runs in the host, which the linked window activates.
	jumps_focus_moves(s, linked, host)
	app.focus_jump(s, host, -1)
	jumps_settle(s)
	testing.expect_value(t, jumps_focused(s, host), first)
	jumps_expect(t, s, {first, second, third}, 0)

	// Forward walks out through the linked window to the second tab.
	app.focus_jump(s, host, 1)
	jumps_settle(s)
	jumps_focus_moves(s, host, linked)
	jumps_settle(s)
	jumps_expect(t, s, {first, second, third}, 1)
	jumps_focus_moves(s, linked, host)
	app.focus_jump(s, host, 1)
	jumps_settle(s)
	testing.expect_value(t, host.workspace.selected, 1)
	testing.expect(t, linked.phase == .Hidden)
	testing.expect_value(t, jumps_focused(s, host), third)
	jumps_expect(t, s, {first, second, third}, 2)
}
