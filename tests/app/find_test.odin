package app_test

import "aio:input"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:font"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:term_view"
import "aio:ui"

@(private)
find_settle :: proc(t: ^testing.T, session: ^term.Session) {
	start := time.tick_now()
	for term.search_pending(session) && time.tick_since(start) < 10*time.Second { term.search_update(session) }
	testing.expect(t, !term.search_pending(session))
}

@(test)
find_headless_releases_finish_tab_and_divider_gestures :: proc(t: ^testing.T) {
	session, err := term.create({
		command_line = "cmd.exe /d /c echo MATCH138", working_directory = "C:\\Windows\\System32",
		geometry = {columns = 80, rows = 24, cell_width = 8, cell_height = 16,
			surface_width = 640, surface_height = 384},
	}, {})
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.destroy(session)
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	tabs := [2]app.Tab{{id = 138, marked = true}, {id = 139}}
	defer { for &tab in tabs { layout.destroy(&tab.tree) } }
	for &tab in tabs {
		if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, tab.id}), nil) { return }
	}
	workspace: app.Workspace
	append(&workspace.tabs, &tabs[0], &tabs[1])
	defer delete(workspace.tabs)
	w := app.Window{id = 138, workspace = &workspace,
		width = 1000, height = 600, scale = 1,
		rail_wide = true, rail = app.Rail_Docked{}}
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, nil, 14)) { return }
	w.metrics = term_view.compute_metrics(fonts, w.ui_text.family, 14, 1)
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	defer {
		delete(w.panes)
		delete(w.dividers)
		for &view in w.views {app.pane_view_destroy(&view)}
		delete(w.views)
	}
	state: app.App
	append(&state.windows, &w)
	defer delete(state.windows)
	append(&state.workspaces, &workspace)
	defer delete(state.workspaces)
	append(&state.sessions, app.Session_Entry{id = 138, session = session})
	defer delete(state.sessions)
	defer app.tab_drag_cancel(&state, &w)
	row := app.rail_row_rect_for_tab(&w, 0)
	app.tab_press(&state, &w, 0, row.x + 20, row.y + row.height / 2, false)
	if !testing.expect(t, app.tab_drag_held(&w)) { return }
	// Seed the gesture, the tabs' hold on it and the overlay together; moves and releases use the real
	// app dispatcher.
	w.gesture.captures[.Left] = app.Gesture_Held{app.Pointer_Target.Tabs}
	ui.find_open(&w.find)
	if !testing.expect(t, ui.find_is_open(&w.find)) { return }
	target := app.rail_row_rect_for_tab(&w, 1)
	x, y := i32(target.x + 20), i32(target.y + target.height / 2)
	app.handle_event(&state, input.Mouse_Move_Event{window = w.id, x = x, y = y, buttons = {.Left}})
	if !testing.expect(t, app.tab_drag_active(&w) && workspace.tabs[1] == &tabs[0]) { return }
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect(t, !app.drag_held(&w))
	app.handle_event(&state, input.Mouse_Move_Event{window = w.id, x = x, y = y})
	testing.expect(t, workspace.tabs[1] == &tabs[0])
	testing.expect_value(t, workspace.selected, 1)
	testing.expect(t, !ui.armed_down(w.find.armed))
	layout_state, _ := app.rail_current_layout(&w)
	close := ui.rail_close_rect(layout_state, workspace.selected, w.scale)
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(close.x+close.width/2), y = i32(close.y+close.height/2)})
	if !testing.expect_value(t, ui.armed_target(w.tab_close_armed), workspace.selected) { return }
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect(t, !ui.armed_down(w.tab_close_armed))
	testing.expect_value(t, len(workspace.tabs), 2)
	// Keep the divider regression independent when running against the known broken dispatcher.
	ui.armed_cancel(&w.tab_close_armed)
	shown := app.window_tree(&w)
	_, split_error := layout.split(shown, shown.focus, .Horizontal, 0.5, {.Terminal, 140})
	if !testing.expect_value(t, split_error, nil) { return }
	layout.dividers(shown, app.window_content_area(&state, &w), app.window_gap(&state, &w), &w.dividers)
	if !testing.expect_value(t, len(w.dividers), 1) { return }
	d := w.dividers[0].rect
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(d.x+d.width/2), y = 300, time_ns = 1_000_000_000})
	if !testing.expect_value(t, divider_count(&w), 1) { return }
	app.handle_event(&state, input.Mouse_Move_Event{window = w.id, x = x, y = y, buttons = {.Left}})
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect_value(t, divider_count(&w), 0)
	testing.expect(t, !ui.armed_down(w.find.armed) && ui.find_is_open(&w.find))
}

// Uses real ConPTY output and the app event dispatcher, without creating or showing a native window.
@(test)
find_headless_events_keep_counts_scope_keyboard_wrap_and_close :: proc(t: ^testing.T) {
	session, err := term.create({
		command_line = "cmd.exe /d /c \"echo MATCH138 &echo MATCH138 &echo MATCH138\"",
		working_directory = "C:\\Windows\\System32", options = {scrollback_lines = 1000},
		geometry = {columns = 80, rows = 24, cell_width = 8, cell_height = 16,
			surface_width = 640, surface_height = 384},
	}, {})
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.destroy(session)
	other, other_error := term.create({
		command_line = "cmd.exe /d /c echo OTHER138", working_directory = "C:\\Windows\\System32",
		geometry = {columns = 80, rows = 24, cell_width = 8, cell_height = 16,
			surface_width = 640, surface_height = 384},
	}, {})
	if !testing.expect_value(t, other_error, term.Error.None) { return }
	defer term.destroy(other)
	start := time.tick_now()
	for term.status(session).kind == .Running && time.tick_since(start) < 10*time.Second {
		time.sleep(time.Millisecond)
	}
	if !testing.expect_value(t, term.status(session).kind, term.Status_Kind.Exited) { return }
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 138}), nil) { return }
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{id = 138, workspace = &workspace, width = 1000, height = 600, scale = 1}
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, nil, 14)) { return }
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	state: app.App
	append(&state.windows, &w)
	defer delete(state.windows)
	append(&state.sessions, app.Session_Entry{id = 138, session = session})
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 139, session = other})
	other_tab: app.Tab
	if !testing.expect_value(t, layout.init(&other_tab.tree, {.Terminal, 139}), nil) { return }
	defer layout.destroy(&other_tab.tree)
	other_workspace: app.Workspace
	append(&other_workspace.tabs, &other_tab)
	defer delete(other_workspace.tabs)
	other_window := app.Window{id = 139, workspace = &other_workspace}
	ui.find_init(&other_window.find)
	defer ui.find_destroy(&other_window.find)
	ui.find_open(&other_window.find)
	append(&state.windows, &other_window)
	app.handle_event(&state, input.Text_Event{other_window.id, "OTHER138"})
	find_settle(t, other)
	testing.expect(t, term.search_summary(other).progress != .Off)
	ui.find_open(&w.find)
	label, enabled := app.find_presentation(&w, &state.sessions[0])
	testing.expect_value(t, label, "0 of 0")
	testing.expect(t, !enabled)
	app.handle_event(&state, input.Text_Event{w.id, "MATCH138"})
	label, _ = app.find_presentation(&w, &state.sessions[0])
	testing.expect(t, strings.contains(label, "Searching"))
	find_settle(t, session)
	label, enabled = app.find_presentation(&w, &state.sessions[0])
	testing.expect_value(t, label, "0 of 3")
	testing.expect(t, enabled)
	for expected in 0 ..< 4 {
		l, _ := app.find_controls(&w, &state.sessions[0])
		x, y := i32(l.up.x+16), i32(l.up.y+16)
		app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y,
			button = .Left, pressed = true})
		app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
		testing.expect_value(t, term.search_summary(session).selected, expected%3)
		testing.expect_value(t, term.search_summary(other).selected, -1)
	}
	l, _ := app.find_controls(&w, &state.sessions[0])
	for down in ([2]bool{true, false}) {
		app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.down.x+16),
			y = i32(l.down.y+16), button = .Left, pressed = down})
	}
	testing.expect_value(t, term.search_summary(session).selected, 2)
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, term.search_summary(session).selected, 0)
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Enter, modifiers = {.Shift}, pressed = true})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	label, _ = app.find_presentation(&w, &state.sessions[0])
	testing.expect_value(t, label, "3 of 3")
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
		y = i32(l.up.y+16), button = .Left, pressed = true})
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = w.width-20, y = 20, button = .Left})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	testing.expect(t, !ui.armed_down(w.find.armed))
	testing.expect(t, !ui.armed_down(w.caption_armed))
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
		y = i32(l.up.y+16), button = .Left, pressed = true})
	w.dirty = false
	app.handle_event(&state, platform.Capture_Lost_Event{w.id})
	testing.expect(t, !ui.armed_down(w.find.armed) &&
		ui.armed_target(w.find.armed) == .None && w.dirty)
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
		y = i32(l.up.y+16), button = .Left})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
		y = i32(l.up.y+16), button = .Left, pressed = true})
	app.handle_event(&state, platform.Focus_Event{window = w.id, focused = false})
	testing.expect(t, !ui.armed_down(w.find.armed) &&
		ui.armed_target(w.find.armed) == .None && ui.find_is_open(&w.find))
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
		y = i32(l.up.y+16), button = .Left})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	app.handle_event(&state, input.Text_Event{w.id, "absent"})
	find_settle(t, session)
	label, enabled = app.find_presentation(&w, &state.sessions[0])
		testing.expect_value(t, label, "0 of 0")
	testing.expect(t, !enabled)
	l, _ = app.find_controls(&w, &state.sessions[0])
	for down in ([2]bool{true, false}) {
		app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
			y = i32(l.up.y+16), button = .Left, pressed = down})
	}
	testing.expect_value(t, term.search_summary(session).selected, -1)
	testing.expect_value(t, term.search_summary(other).selected, -1)
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = i32(l.up.x+16),
		y = i32(l.up.y+16), button = .Left, pressed = true})
	testing.expect(t, ui.armed_down(w.find.armed) && ui.armed_target(w.find.armed) == .None)
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = 5, y = 5, button = .Left})
	testing.expect(t, !ui.armed_down(w.find.armed))
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !ui.find_is_open(&w.find) && term.search_summary(session).progress == .Off)
	bar, _ := term.scrollbar(session)
	testing.expect_value(t, bar.offset+bar.len, bar.total)
}

// Clicking the terminal hands it the keyboard while matches stay; closing keeps the scrolled viewport.
@(test)
find_headless_blur_keeps_matches_and_close_keeps_viewport :: proc(t: ^testing.T) {
	session, err := term.create({
		command_line = "cmd.exe /d /c \"for /l %i in (1,1,200) do @echo LINE_%i\"",
		working_directory = `C:\Windows\System32`, options = {scrollback_lines = 1000},
		geometry = {columns = 80, rows = 24, cell_width = 8, cell_height = 16,
			surface_width = 640, surface_height = 384},
	}, {})
	if !testing.expect_value(t, err, term.Error.None) { return }
	defer term.destroy(session)
	start := time.tick_now()
	for term.status(session).kind == .Running && time.tick_since(start) < 10*time.Second {
		time.sleep(time.Millisecond)
	}
	fonts, font_error := font.system_create()
	if !testing.expect_value(t, font_error, font.Error.None) { return }
	defer font.system_destroy(fonts)
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Terminal, 140}), nil) { return }
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{id = 140, workspace = &workspace, width = 1000, height = 600, scale = 1}
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, nil, 14)) { return }
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	state: app.App
	defer ui.find_history_destroy(&state.find_history)
	append(&state.windows, &w)
	defer delete(state.windows)
	append(&state.sessions, app.Session_Entry{id = 140, session = session})
	defer delete(state.sessions)
	entry := &state.sessions[0]
	up := proc(s: ^term.Session) -> u64 { bar, _ := term.scrollbar(s); return bar.total - (bar.offset + bar.len) }

	app.find_toggle(&state, &w, entry)
	testing.expect(t, ui.find_has_keyboard(&w.find))
	app.handle_event(&state, input.Text_Event{w.id, "line_7$"})
	testing.expect(t, !w.find.options.regex)
	app.handle_event(&state, input.Key_Event{window = w.id, key = .R, modifiers = {.Alt}, pressed = true,
		text = "r"})
	testing.expect(t, w.find.options.regex)
	testing.expect_value(t, ui.field_string(&w.find.query), "line_7$")
	find_settle(t, session)
	testing.expect_value(t, term.search_summary(session).total, 1)
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	scrolled := up(session)
	testing.expect(t, scrolled > 0)

	// A press on the terminal blurs the bar; it stays open and Escape is no longer its key.
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = 200, y = 400, button = .Left,
		pressed = true})
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = 200, y = 400, button = .Left})
	testing.expect(t, ui.find_is_open(&w.find) && !ui.find_has_keyboard(&w.find))
	testing.expect(t, term.search_summary(session).progress != .Off)
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, ui.find_is_open(&w.find))
	app.find_toggle(&state, &w, entry)
	testing.expect(t, ui.find_has_keyboard(&w.find))
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !ui.find_is_open(&w.find) && term.search_summary(session).progress == .Off)
	testing.expect_value(t, up(session), scrolled)

	// The kept search reopens and runs; the close button closes without resetting the view either.
	state.settings.terminal.find_reopen = .Last
	app.find_toggle(&state, &w, entry)
	testing.expect_value(t, ui.field_string(&w.find.query), "line_7$")
	testing.expect(t, term.search_summary(session).progress != .Off)
	l, _ := app.find_controls(&w, entry)
	x, y := i32(l.close.x+16), i32(l.close.y+16)
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left, pressed = true})
	app.handle_event(&state, input.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect(t, !ui.find_is_open(&w.find))
	testing.expect_value(t, up(session), scrolled)
}
