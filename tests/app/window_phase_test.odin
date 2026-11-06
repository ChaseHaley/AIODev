package app_test

import app "../../src"
import "aio:platform"
import "core:testing"

@(private = "file")
activation_pending :: proc(w: ^app.Window) -> bool {
	link, linked := w.link.?
	return linked && link.activate
}

// A tear-off preview is hidden and may still be discarded, so it must never stand in for the app's window:
// reopening from the tray would otherwise show the half-made preview instead of a workspace.
@(test)
tray_only_ignores_a_tear_off_preview :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "tray-preview", second_window = false) {return}
	s := &f.state
	host := s.windows[0]
	source := s.workspaces[0].tabs[0]
	if !testing.expect(t, app.tab_create(s, s.workspaces[0])) {return}
	preview := app.pane_window_preview_create(s, source, source.tree.root)
	if !testing.expect(t, preview != nil) {return}
	testing.expect(t, app.window_primary(s) == host)
	s.tray_hint_shown = true // Keeps the test from raising a real tray balloon.
	app.hide_to_tray(s, host)
	testing.expect(t, app.app_tray_only(s), "only a preview is left")
	app.show_window(s)
	primary := app.window_primary(s)
	testing.expect(t, primary != nil && primary != preview && primary.workspace == s.workspaces[0])
	testing.expect(t, preview.phase == .Preparing)
	app.pane_window_preview_discard(s, preview.id)
}

@(test)
linked_window_activation_waits_until_it_is_shown :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "link-activation", second_window = false) {return}
	s := &f.state
	host := s.windows[0]
	app.pane_split(s, host, .Right)
	app.pane_link_toggle(s, host)
	if !testing.expect_value(t, len(s.windows), 2) {return}
	w := s.windows[1]
	testing.expect(t, activation_pending(w))
	if !testing.expect(t, app.tab_create(s, host.workspace)) {return}
	app.tab_select(s, host, 1)
	app.pane_links_sync(s)
	testing.expect(t, w.phase == .Hidden)
	testing.expect(t, activation_pending(w), "a hidden window keeps the request")
	app.tab_select(s, host, 0)
	app.pane_links_sync(s)
	testing.expect(t, w.phase == .Shown)
	testing.expect(t, !activation_pending(w), "the show carries it out")
}

// A destroyed window never reports losing focus, so the jump list must not keep following it.
@(test)
closing_the_focused_window_hands_focus_tracking_on :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "focus-close") {return}
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	app.handle_event(s, platform.Focus_Event{second.id, true})
	testing.expect_value(t, s.focus_jumps.window, second.id)
	app.window_close(s, second)
	testing.expect_value(t, s.focus_jumps.window, first.id)
	app.focus_jumps_track(s)
	entry := app.focused_session(s, first)
	if !testing.expect(t, entry != nil) {return}
	testing.expect(t, len(s.focus_jumps.entries) > 0 && s.focus_jumps.entries[len(s.focus_jumps.entries) - 1] == entry.id)
}
