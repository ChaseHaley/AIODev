package app_test

import "aio:input"
import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:ghostty"
import "aio:layout"
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
	state.settings.status.panel = false
	defer settings.destroy(&state.settings)
	state.sessions = make([dynamic]app.Session_Entry)
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 1, session = &s})
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 1}), nil) {return}
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{workspace = &workspace, scale = 1, width = 1000, height = 600}
	w.panes = make([dynamic]layout.Pane_Rect)
	defer delete(w.panes)
	// Keep the test pane below the window's title-bar pointer surfaces.
	append(&w.panes, layout.Pane_Rect{content = {.Terminal, 1}, rect = {0, 100, 800, 500}})
	pane := w.panes[0]
	bar, visible := app.pane_scrollbar_geometry(&state, &w, pane)
	track, thumb := bar.track, bar.thumb
	before, _ := term.scrollbar(&s)
	testing.expect(t, visible && thumb.height >= 24)
	testing.expect_value(t, app.pointer_target(&state, &w, track.x + 3, track.y + 2), app.Pointer_Target.Scrollbar)
	app.gesture_button(&state, &w,
		input.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + 3), y = i32(track.y + 2)})
	after, _ := term.scrollbar(&s)
	testing.expect_value(t, before.offset - after.offset, before.len)
	// A held track press is no thumb drag: moves must leave the paged viewport alone.
	testing.expect(t, !app.pane_scrollbar_dragging(&w))
	app.gesture_move(&state, &w,
		input.Mouse_Move_Event{x = 0, y = i32(track.y + track.height / 2), buttons = {.Left}})
	paged, _ := term.scrollbar(&s)
	testing.expect_value(t, paged.offset, after.offset)
	app.gesture_button(&state, &w,
		input.Mouse_Button_Event{button = .Left, pressed = false, x = 0, y = i32(track.y + track.height / 2)})
	testing.expect(t, app.gesture_buttons(&w, app.Gesture_Held) == {})
	bar, _ = app.pane_scrollbar_geometry(&state, &w, pane)
	thumb = bar.thumb
	testing.expect_value(t, app.pointer_target(&state, &w, track.x + 3, thumb.y + 2), app.Pointer_Target.Scrollbar)
	app.gesture_button(&state, &w,
		input.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + 3), y = i32(thumb.y + 2)})
	testing.expect(t, app.pane_scrollbar_dragging(&w))
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = 0, y = -100, buttons = {.Left}})
	after, _ = term.scrollbar(&s)
	testing.expect_value(t, after.offset, 0)
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = 0, y = 2000, buttons = {.Left}})
	after, _ = term.scrollbar(&s)
	testing.expect_value(t, after.offset + after.len, after.total)
	app.gesture_button(&state, &w,
		input.Mouse_Button_Event{button = .Left, pressed = false, x = 0, y = 2000})
	testing.expect(t, !app.pane_scrollbar_dragging(&w))
}

// Pointer moves arrive faster than frames, so a drag reads the bar of a screen captured before its
// earlier moves scrolled. Each move must still put the thumb under the pointer, not add its offset
// to the stale one.
@(test)
scrollbar_drag_follows_pointer_between_captures :: proc(t: ^testing.T) {
	s: term.Session
	testing.expect_value(t, ghostty.terminal_new(nil, &s.terminal, 80, 24), ghostty.Result.Success)
	defer ghostty.terminal_free(s.terminal)
	text := "line\r\n"
	for _ in 0 ..< 200 {ghostty.terminal_vt_write(s.terminal, raw_data(text), len(text))}
	state: app.App
	state.settings, _, _ = settings.parse("")
	state.settings.status.panel = false
	defer settings.destroy(&state.settings)
	state.sessions = make([dynamic]app.Session_Entry)
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 1, session = &s})
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 1}), nil) {return}
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{workspace = &workspace, scale = 1, width = 1000, height = 600}
	w.panes = make([dynamic]layout.Pane_Rect)
	defer delete(w.panes)
	append(&w.panes, layout.Pane_Rect{content = {.Terminal, 1}, rect = {0, 100, 800, 500}})
	// The drawn screen's capture, taken at the bottom and never refreshed during the drag.
	captured, _ := term.scrollbar(&s)
	w.views = make([dynamic]app.Pane_View)
	defer delete(w.views)
	append(&w.views, app.Pane_View{content = {.Terminal, 1}})
	w.views[0].view.scrollbar = captured
	pane := w.panes[0]
	bar, _ := app.pane_scrollbar_geometry(&state, &w, pane)
	x := i32(bar.track.x + 3)
	grab_y := f32(i32(bar.thumb.y + 2))
	app.gesture_button(&state, &w, input.Mouse_Button_Event{button = .Left, pressed = true, x = x, y = i32(grab_y)})
	testing.expect(t, app.pane_scrollbar_dragging(&w))
	// Two moves before any frame: up 100 pixels, then 10 more.
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = x, y = i32(grab_y - 100), buttons = {.Left}})
	app.gesture_move(&state, &w, input.Mouse_Move_Event{x = x, y = i32(grab_y - 110), buttons = {.Left}})
	got, _ := term.scrollbar(&s)
	held := w.scrollbars.drag.?
	want := ui.scrollbar_drag(held.grab, bar, grab_y - 110)
	testing.expect_value(t, int(got.offset), want)
	app.gesture_button(&state, &w, input.Mouse_Button_Event{button = .Left, pressed = false, x = x, y = i32(grab_y - 110)})
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
	state.settings.status.panel = false
	defer settings.destroy(&state.settings)
	testing.expect(t, state.settings.terminal.scrollbar)
	state.sessions = make([dynamic]app.Session_Entry)
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 1, session = &s})
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 1}), nil) {return}
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{workspace = &workspace, scale = 1, width = 1000, height = 600}
	w.panes = make([dynamic]layout.Pane_Rect)
	defer delete(w.panes)
	// Keep the test pane below the window's title-bar pointer surfaces.
	append(&w.panes, layout.Pane_Rect{content = {.Terminal, 1}, rect = {0, 100, 800, 500}})
	pane := w.panes[0]

	bar, _ := app.pane_scrollbar_geometry(&state, &w, pane)
	track, thin := bar.track, bar.thumb
	testing.expect_value(t, app.pane_scrollbar_state(&w, {.Terminal, 1}), ui.Scrollbar_State.Collapsed)
	testing.expect(t, thin.width < track.width)
	// The zone is the expanded width, so its far edge from the thumb still expands it.
	app.gesture_move(&state, &w,
		input.Mouse_Move_Event{x = i32(track.x + 0.5), y = i32(track.y + track.height - 1)})
	testing.expect_value(t, app.pane_scrollbar_state(&w, {.Terminal, 1}), ui.Scrollbar_State.Hovered)
	bar, _ = app.pane_scrollbar_geometry(&state, &w, pane)
	wide := bar.thumb
	testing.expect(t, wide.width > thin.width && wide.x >= track.x)
	testing.expect_value(t, wide.x + wide.width, thin.x + thin.width)
	app.gesture_move(&state, &w,
		input.Mouse_Move_Event{x = i32(track.x - 1), y = i32(track.y + 10)})
	testing.expect_value(t, app.pane_scrollbar_state(&w, {.Terminal, 1}), ui.Scrollbar_State.Collapsed)

	bar, _ = app.pane_scrollbar_geometry(&state, &w, pane)
	thin = bar.thumb
	testing.expect_value(t, app.pointer_target(&state, &w, track.x + track.width - 2, thin.y + 2), app.Pointer_Target.Scrollbar)
	app.gesture_button(&state, &w,
		input.Mouse_Button_Event{button = .Left, pressed = true, x = i32(track.x + track.width - 2), y = i32(thin.y + 2)})
	testing.expect_value(t, app.pane_scrollbar_state(&w, {.Terminal, 1}), ui.Scrollbar_State.Active)
	app.gesture_button(&state, &w,
		input.Mouse_Button_Event{button = .Left, pressed = false, x = i32(track.x - 20), y = i32(track.y + 10)})
	testing.expect_value(t, app.pane_scrollbar_state(&w, {.Terminal, 1}), ui.Scrollbar_State.Collapsed)

	state.settings.terminal.scrollbar = false
	_, visible := app.pane_scrollbar_geometry(&state, &w, pane)
	testing.expect(t, !visible)
	app.gesture_move(&state, &w,
		input.Mouse_Move_Event{x = i32(track.x + 2), y = i32(track.y + 10)})
	testing.expect(t, app.pointer_target(&state, &w, track.x + 2, track.y + 10) != .Scrollbar)
	testing.expect_value(t, app.pane_scrollbar_state(&w, {.Terminal, 1}), ui.Scrollbar_State.Collapsed)
}
