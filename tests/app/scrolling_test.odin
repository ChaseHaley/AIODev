package app_test

import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:ghostty"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "aio:ui"

@(test)
scrolling_defaults_preserve_only_tab_cycle_shortcuts :: proc(t: ^testing.T) {
	r := commands.create()
	defer commands.destroy(&r)
	testing.expect_value(t, app.register_actions(&r), commands.Error.None)
	for name in ([?]string{"tab.next", "tab.previous"}) {
		command := commands.find(&r, name)
		testing.expect_value(t, len(commands.active_shortcuts(command)), 1)
	}
	for name in ([?]string{"tab.select_1", "tab.select_8", "tab.last"}) {
		testing.expect_value(t, len(commands.active_shortcuts(commands.find(&r, name))), 0)
	}
	for name in ([?]string{"terminal.scroll_page_up", "terminal.scroll_partial_up",
		"terminal.scroll_page_down", "terminal.scroll_partial_down"}) {
		testing.expect_value(t, len(commands.active_shortcuts(commands.find(&r, name))), 1)
	}
	s, diagnostics, err := settings.parse("")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, s.terminal.scroll_page_length, 0.5)
}

@(test)
scrollbar_drag_clamps_and_track_click_pages :: proc(t: ^testing.T) {
	s: term.Session
	testing.expect_value(t, ghostty.terminal_new(nil, &s.terminal, 80, 24), ghostty.Result.Success)
	defer ghostty.terminal_free(s.terminal)
	text := "line\r\n"
	for _ in 0 ..< 200 {ghostty.terminal_vt_write(s.terminal, raw_data(text), len(text))}
	state: app.App
	state.settings, _, _ = settings.parse("")
	defer settings.destroy(&state.settings)
	state.sessions = make([dynamic]app.Session_Entry)
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 1, session = &s})
	w := app.Window{scale = 1}
	w.panes = make([dynamic]layout.Pane_Rect)
	defer delete(w.panes)
	append(&w.panes, layout.Pane_Rect{content = {id = 1}, rect = {0, 0, 800, 500}})
	pane := w.panes[0]
	bar, visible := app.terminal_scrollbar_geometry(&state, &w, pane, &state.sessions[0])
	track, thumb := bar.track, bar.thumb
	before, _ := term.scrollbar(&s)
	testing.expect(t, visible && thumb.height >= 24)
	testing.expect(t, app.terminal_scrollbar_button(&state, &w,
		platform.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + 3), y = i32(track.y + 2)}))
	after, _ := term.scrollbar(&s)
	testing.expect_value(t, before.offset - after.offset, before.len)
	bar, _ = app.terminal_scrollbar_geometry(&state, &w, pane, &state.sessions[0])
	thumb = bar.thumb
	testing.expect(t, app.terminal_scrollbar_button(&state, &w,
		platform.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + 3), y = i32(thumb.y + 2)}))
	testing.expect(t, app.terminal_scrollbar_dragging(&w))
	app.terminal_scrollbar_move(&state, &w, -100)
	after, _ = term.scrollbar(&s)
	testing.expect_value(t, after.offset, 0)
	app.terminal_scrollbar_move(&state, &w, 2000)
	after, _ = term.scrollbar(&s)
	testing.expect_value(t, after.offset + after.len, after.total)
}

@(test)
scrollbar_expands_under_pointer_and_can_be_hidden :: proc(t: ^testing.T) {
	s: term.Session
	testing.expect_value(t, ghostty.terminal_new(nil, &s.terminal, 80, 24), ghostty.Result.Success)
	defer ghostty.terminal_free(s.terminal)
	text := "line\r\n"
	for _ in 0 ..< 200 {ghostty.terminal_vt_write(s.terminal, raw_data(text), len(text))}
	state: app.App
	state.settings, _, _ = settings.parse("")
	defer settings.destroy(&state.settings)
	testing.expect(t, state.settings.terminal.scrollbar)
	state.sessions = make([dynamic]app.Session_Entry)
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 1, session = &s})
	w := app.Window{scale = 1}
	w.panes = make([dynamic]layout.Pane_Rect)
	defer delete(w.panes)
	append(&w.panes, layout.Pane_Rect{content = {id = 1}, rect = {0, 0, 800, 500}})
	pane, entry := w.panes[0], &state.sessions[0]

	bar, _ := app.terminal_scrollbar_geometry(&state, &w, pane, entry)
	track, thin := bar.track, bar.thumb
	testing.expect_value(t, app.terminal_scrollbar_state(&w, 1), ui.Scrollbar_State.Collapsed)
	testing.expect(t, thin.width < track.width)
	// The zone is the expanded width, so its far edge from the thumb still expands it.
	testing.expect(t, app.terminal_scrollbar_hover(&state, &w, track.x + 0.5, track.y + track.height - 1))
	testing.expect_value(t, app.terminal_scrollbar_state(&w, 1), ui.Scrollbar_State.Hovered)
	bar, _ = app.terminal_scrollbar_geometry(&state, &w, pane, entry)
	wide := bar.thumb
	testing.expect(t, wide.width > thin.width && wide.x >= track.x)
	testing.expect_value(t, wide.x + wide.width, thin.x + thin.width)
	testing.expect(t, !app.terminal_scrollbar_hover(&state, &w, track.x - 1, track.y + 10))
	testing.expect_value(t, app.terminal_scrollbar_state(&w, 1), ui.Scrollbar_State.Collapsed)

	bar, _ = app.terminal_scrollbar_geometry(&state, &w, pane, entry)
	thin = bar.thumb
	testing.expect(t, app.terminal_scrollbar_button(&state, &w,
		platform.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + track.width - 2), y = i32(thin.y + 2)}))
	testing.expect_value(t, app.terminal_scrollbar_state(&w, 1), ui.Scrollbar_State.Active)
	app.terminal_scrollbar_release(&state, &w, track.x - 20, track.y + 10)
	testing.expect_value(t, app.terminal_scrollbar_state(&w, 1), ui.Scrollbar_State.Collapsed)

	state.settings.terminal.scrollbar = false
	_, visible := app.terminal_scrollbar_geometry(&state, &w, pane, entry)
	testing.expect(t, !visible)
	testing.expect(t, !app.terminal_scrollbar_hover(&state, &w, track.x + 2, track.y + 10))
}
