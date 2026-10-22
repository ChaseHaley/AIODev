package app_test

import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:font"
import "aio:layout"
import "aio:platform"
import "aio:render"
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
	w := app.Window{id = 138, workspace = &workspace, tree = &tabs[0].tree,
		width = 1000, height = 600, scale = 1, caption_pressed = -1, tab_close_pressed = -1,
		divider_click_node = layout.INVALID_NODE}
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, nil, 14)) { return }
	w.metrics = term_view.compute_metrics(fonts, w.ui_text.family, 14, 1)
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	defer {
		delete(w.tab_positions)
		delete(w.tab_controls)
		delete(w.panes)
		delete(w.dividers)
		for &view in w.views {
			term_view.destroy(&view.view)
			render.draw_list_destroy(&view.cache)
		}
		delete(w.views)
	}
	state: app.App
	append(&state.windows, &w)
	defer delete(state.windows)
	append(&state.sessions, app.Session_Entry{id = 138, session = session})
	defer delete(state.sessions)
	defer app.tab_drag_cancel(&state, &w)
	bar := app.window_tab_bar(&state, &w)
	app.tab_press(&w, 0, bar.x+20, bar.tab_width, false)
	if !testing.expect(t, w.tab_drag.pressed) { return }
	// Seed the gesture and overlay together; moves and releases use the real app dispatcher.
	ui.find_open(&w.find)
	if !testing.expect(t, w.find.open) { return }
	l, _ := app.find_controls(&w, &state.sessions[0])
	x, y := i32(l.older.x+16), i32(l.older.y+16)
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = x, y = y, buttons = {.Left}})
	if !testing.expect(t, w.tab_drag.active && workspace.tabs[1] == &tabs[0]) { return }
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect(t, !w.tab_drag.pressed && !w.tab_drag.active)
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = x, y = y})
	testing.expect(t, workspace.tabs[1] == &tabs[0])
	testing.expect_value(t, workspace.selected, 1)
	testing.expect(t, !w.find.pointer_down)
	clear(&w.tab_positions)
	bar = app.window_tab_bar(&state, &w)
	close := ui.tab_close_rect(bar, workspace.selected, w.scale)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(close.x+close.width/2), y = i32(close.y+close.height/2)})
	if !testing.expect_value(t, w.tab_close_pressed, workspace.selected) { return }
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect_value(t, w.tab_close_pressed, -1)
	testing.expect_value(t, len(workspace.tabs), 2)
	// Keep the divider regression independent when running against the known broken dispatcher.
	w.tab_close_pressed = -1
	_, split_error := layout.split(w.tree, w.tree.focus, .Horizontal, 0.5, {.Terminal, 140})
	if !testing.expect_value(t, split_error, nil) { return }
	layout.dividers(w.tree, app.window_content_area(&state, &w), app.window_gap(&state, &w), &w.dividers)
	if !testing.expect_value(t, len(w.dividers), 1) { return }
	d := w.dividers[0].rect
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(d.x+d.width/2), y = 300, time_ns = 1_000_000_000})
	if !testing.expect_value(t, w.dragging.count, 1) { return }
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = x, y = y, buttons = {.Left}})
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
	testing.expect_value(t, w.dragging.count, 0)
	testing.expect(t, !w.find.pointer_down && w.find.open)
}

// Uses real ConPTY output and the app event dispatcher, without creating or showing a native window.
@(test)
find_headless_events_keep_counts_scope_keyboard_wrap_and_close :: proc(t: ^testing.T) {
	session, err := term.create({
		command_line = "cmd.exe /d /c \"echo MATCH138 &echo MATCH138 &echo MATCH138\"",
		working_directory = "C:\\Windows\\System32", scrollback_lines = 1000,
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
	workspace: app.Workspace
	tree: layout.Layout
	if !testing.expect_value(t, layout.init(&tree, {.Terminal, 138}), nil) { return }
	defer layout.destroy(&tree)
	w := app.Window{id = 138, workspace = &workspace, tree = &tree, width = 1000, height = 600,
		scale = 1, caption_pressed = -1, tab_close_pressed = -1}
	if !testing.expect(t, ui.text_init(&w.ui_text, fonts, nil, 14)) { return }
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	state: app.App
	append(&state.windows, &w)
	defer delete(state.windows)
	append(&state.sessions, app.Session_Entry{id = 138, session = session})
	defer delete(state.sessions)
	append(&state.sessions, app.Session_Entry{id = 139, session = other})
	other_tree: layout.Layout
	if !testing.expect_value(t, layout.init(&other_tree, {.Terminal, 139}), nil) { return }
	defer layout.destroy(&other_tree)
	other_window := app.Window{id = 139, workspace = &workspace, tree = &other_tree}
	ui.find_init(&other_window.find)
	defer ui.find_destroy(&other_window.find)
	ui.find_open(&other_window.find)
	append(&state.windows, &other_window)
	app.handle_event(&state, platform.Text_Event{other_window.id, "OTHER138"})
	find_settle(t, other)
	testing.expect(t, term.search_summary(other).active)
	ui.find_open(&w.find)
	label, enabled := app.find_presentation(&w, &state.sessions[0])
	testing.expect_value(t, label, "0 of 0")
	testing.expect(t, !enabled)
	app.handle_event(&state, platform.Text_Event{w.id, "MATCH138"})
	label, _ = app.find_presentation(&w, &state.sessions[0])
	testing.expect(t, strings.contains(label, "Searching"))
	find_settle(t, session)
	label, enabled = app.find_presentation(&w, &state.sessions[0])
	testing.expect_value(t, label, "0 of 3")
	testing.expect(t, enabled)
	for expected in 0 ..< 4 {
		l, _ := app.find_controls(&w, &state.sessions[0])
		x, y := i32(l.older.x+16), i32(l.older.y+16)
		app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = x, y = y,
			button = .Left, pressed = true})
		app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = x, y = y, button = .Left})
		testing.expect_value(t, term.search_summary(session).selected, expected%3)
		testing.expect_value(t, term.search_summary(other).selected, -1)
	}
	l, _ := app.find_controls(&w, &state.sessions[0])
	for down in ([2]bool{true, false}) {
		app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.newer.x+16),
			y = i32(l.newer.y+16), button = .Left, pressed = down})
	}
	testing.expect_value(t, term.search_summary(session).selected, 2)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, term.search_summary(session).selected, 0)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Enter, modifiers = {.Shift}, pressed = true})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	label, _ = app.find_presentation(&w, &state.sessions[0])
	testing.expect_value(t, label, "3 of 3")
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
		y = i32(l.older.y+16), button = .Left, pressed = true})
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = w.width-20, y = 20, button = .Left})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	testing.expect(t, !w.find.pointer_down)
	testing.expect_value(t, w.caption_pressed, -1)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
		y = i32(l.older.y+16), button = .Left, pressed = true})
	w.dirty = false
	app.handle_event(&state, platform.Capture_Lost_Event{w.id})
	testing.expect(t, !w.find.pointer_down && w.find.pressed == .None && w.dirty)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
		y = i32(l.older.y+16), button = .Left})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
		y = i32(l.older.y+16), button = .Left, pressed = true})
	app.handle_event(&state, platform.Focus_Event{window = w.id, focused = false})
	testing.expect(t, !w.find.pointer_down && w.find.pressed == .None && w.find.open)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
		y = i32(l.older.y+16), button = .Left})
	testing.expect_value(t, term.search_summary(session).selected, 2)
	app.handle_event(&state, platform.Text_Event{w.id, "absent"})
	find_settle(t, session)
	label, enabled = app.find_presentation(&w, &state.sessions[0])
	testing.expect(t, strings.contains(label, "No matches") && strings.contains(label, "0 of 0"))
	testing.expect(t, !enabled)
	l, _ = app.find_controls(&w, &state.sessions[0])
	for down in ([2]bool{true, false}) {
		app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
			y = i32(l.older.y+16), button = .Left, pressed = down})
	}
	testing.expect_value(t, term.search_summary(session).selected, -1)
	testing.expect_value(t, term.search_summary(other).selected, -1)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = i32(l.older.x+16),
		y = i32(l.older.y+16), button = .Left, pressed = true})
	testing.expect(t, w.find.pointer_down && w.find.pressed == .None)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, x = 5, y = 5, button = .Left})
	testing.expect(t, !w.find.pointer_down)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !w.find.open && !term.search_summary(session).active)
	bar, _ := term.scrollbar(session)
	testing.expect_value(t, bar.offset+bar.len, bar.total)
}
