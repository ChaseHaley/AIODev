package app_test

import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:ghostty"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:term"

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
	track, thumb, before, visible := app.terminal_scrollbar_geometry(&state, &w, pane, &state.sessions[0])
	testing.expect(t, visible && thumb.height >= 24)
	testing.expect(t, app.terminal_scrollbar_button(&state, &w,
		platform.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + 3), y = i32(track.y + 2)}))
	after, _ := term.scrollbar(&s)
	testing.expect_value(t, before.offset - after.offset, before.len)
	_, thumb, _, _ = app.terminal_scrollbar_geometry(&state, &w, pane, &state.sessions[0])
	testing.expect(t, app.terminal_scrollbar_button(&state, &w,
		platform.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + 3), y = i32(thumb.y + 2)}))
	testing.expect(t, w.scroll_drag)
	app.terminal_scrollbar_move(&state, &w, -100)
	after, _ = term.scrollbar(&s)
	testing.expect_value(t, after.offset, 0)
	app.terminal_scrollbar_move(&state, &w, 2000)
	after, _ = term.scrollbar(&s)
	testing.expect_value(t, after.offset + after.len, after.total)
}
