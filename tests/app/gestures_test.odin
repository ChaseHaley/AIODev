package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:term"
import "aio:ui"

@(private)
gesture_button :: proc(s: ^app.App, w: ^app.Window, button: input.Mouse_Button,
	pressed: bool, x, y: f32) {
	app.handle_event(s, platform.Mouse_Button_Event{window = w.id, button = button,
		pressed = pressed, x = i32(x), y = i32(y), time_ns = 1_000_000_000})
}

// The buttons whose capture is not free.
@(private)
gesture_captured :: proc(w: ^app.Window) -> (buttons: input.Mouse_Buttons) {
	for capture, button in w.gesture.captures {
		if capture != nil {buttons += {button}}
	}
	return
}

@(private)
gesture_header :: proc(w: ^app.Window) -> ui.Header_Layout {
	r := w.panes[0].rect
	return ui.header_layout({r.x, r.y, r.width, r.height}, w.scale)
}

@(test)
gestures_header_multiple_buttons_release_outside_over_caption :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-header") {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	h := gesture_header(w)
	for button in ([?]input.Mouse_Button{.Left, .Right, .Middle}) {
		gesture_button(s, w, button, true, h.title.x+4, h.title.y+4)
	}
	testing.expect(t, app.gesture_buttons(w, app.Gesture_Swallowed) == {.Left, .Right, .Middle})
	gesture_button(s, w, .Left, false, f32(w.width)-20, 10)
	testing.expect(t, !w.pane_drag.pressed)
	gesture_button(s, w, .Right, false, -20, f32(w.height)+20)
	gesture_button(s, w, .Middle, false, -20, f32(w.height)+20)
	testing.expect(t, gesture_captured(w) == {})
	testing.expect(t, !ui.armed_down(w.caption_armed))
	testing.expect_value(t, len(w.panes), 2)
	testing.expect(t, app.window_find(s, w.id) == w && !w.tree.zoomed)
}

@(test)
gestures_opening_and_focus_capture_cancel_then_ignore_late_release :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-cancel") {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	ids := [?]u32{s.sessions[0].id, s.sessions[1].id, s.sessions[2].id}
	pids := [?]u32{term.process_id(s.sessions[0].session), term.process_id(s.sessions[1].session),
		term.process_id(s.sessions[2].session)}
	for scenario in 0 ..< 8 {
		testing.expect_value(t, len(w.panes), 2)
		h := gesture_header(w)
		close := h.buttons[int(ui.Header_Action.Fill_Window) - 1]
		gesture_button(s, w, .Left, true, close.x+4, close.y+4)
		gesture_button(s, w, .Middle, true, h.title.x+4, h.title.y+4)
		switch scenario {
		case 0: app.palette_open(s, w)
		case 1: app.workspace_picker_open(s, w)
		case 2: app.rename_open(s, w, true, w.workspace.selected)
		case 3: app.tab_menu_open(s, w, 0, 20, 20)
		case 4: app.workspace_delete_request(s, w, w.workspace)
		case 5: app.editor_open(s, w)
		case 6: app.handle_event(s, platform.Focus_Event{w.id, false})
		case 7: app.handle_event(s, platform.Capture_Lost_Event{w.id})
		}
		app.window_overlays_cancel(s, w)
		gesture_button(s, w, .Left, false, close.x+4, close.y+4)
		gesture_button(s, w, .Middle, false, close.x+4, close.y+4)
		testing.expect_value(t, len(s.sessions), 3)
		for entry, i in s.sessions {
			testing.expect_value(t, entry.id, ids[i])
			testing.expect_value(t, term.process_id(entry.session), pids[i])
			testing.expect_value(t, term.status(entry.session).kind, term.Status_Kind.Running)
		}
		testing.expect(t, !w.pane_drag.pressed && !w.tab_drag.pressed && gesture_captured(w) == {})
		testing.expect(t, !app.selection_active(w))
		if scenario == 5 {
			// Return to the same terminal tree after the Settings case, with every runtime intact.
			if !testing.expect(t, app.settings_active(w)) {return}
			app.tab_close(s, w, w.workspace.selected)
			testing.expect_value(t, len(w.workspace.tabs), 1)
		}
	}
}

@(test)
gestures_selection_and_editor_release_outside_their_surface :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-release") {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	r := w.panes[0].rect
	gesture_button(s, w, .Left, true, r.x+30, r.y+w.header_height+40)
	if !testing.expect(t, app.selection_active(w)) {return}
	focus := w.tree.focus
	ui.find_open(&w.find)
	app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = w.width+10, y = w.height+10,
		buttons = {.Left}})
	gesture_button(s, w, .Left, false, f32(w.width)-20, 10)
	testing.expect(t, !app.selection_active(w) && !ui.armed_down(w.find.armed))
	testing.expect_value(t, w.tree.focus, focus)
	app.editor_open(s, w)
	l := app.settings_layout(w)
	gesture_button(s, w, .Left, true, l.filter.x+20, l.filter.y+l.filter.height/2)
	if !testing.expect(t, w.editor.filter.dragging) {return}
	gesture_button(s, w, .Left, false, -20, -20)
	testing.expect(t, !w.editor.filter.dragging && !ui.editor_dragging(&w.editor))
	gesture_button(s, w, .Left, true, l.filter.x+20, l.filter.y+l.filter.height/2)
	app.handle_event(s, platform.Capture_Lost_Event{w.id})
	gesture_button(s, w, .Left, false, l.filter.x+20, l.filter.y+l.filter.height/2)
	testing.expect(t, !w.editor.filter.dragging && !ui.editor_dragging(&w.editor))
}

// A press on a disabled menu row leaves the menu open, and its release reaches the menu. Closing the
// menu from the keyboard must not leave the button swallowed: the pointer would keep the arrow over
// text and the next selection drag would never finish.
@(test)
gestures_menu_kept_open_releases_its_swallowed_button :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-menu-row") {return}
	s, w := &f.state, f.state.windows[0]
	if !testing.expect_value(t, len(w.workspace.tabs), 1) {return}
	app.tab_menu_open(s, w, 0, 20, 20)
	row := -1
	for i in 0 ..< w.tab_menu.count {
		if w.tab_menu.actions[i] == .Close_Other_Tabs {row = i}
	}
	if !testing.expect(t, row >= 0 && !app.tab_menu_enabled(w, row)) {return}
	r := app.tab_menu_row_rect(w, row)
	gesture_button(s, w, .Left, true, r.x + 20, r.y + r.height / 2)
	gesture_button(s, w, .Left, false, r.x + 20, r.y + r.height / 2)
	if !testing.expect(t, app.tab_menu_shown(w)) {return}
	app.handle_event(s, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	if !testing.expect(t, !app.tab_menu_shown(w)) {return}
	testing.expect(t, gesture_captured(w) == {})
	p := w.panes[0].rect
	x, y := p.x + 30, p.y + w.header_height + 40
	pointer_expect_move(t, s, w, x, y, .Text)
	gesture_button(s, w, .Left, true, x, y)
	if !testing.expect(t, app.selection_active(w)) {return}
	gesture_button(s, w, .Left, false, x + 30, y)
	testing.expect(t, !app.selection_active(w), "the release must finish the selection")
}

@(test)
gestures_cancel_preview_destruction_and_late_events_preserve_runtime :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-preview") {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	entry := app.focused_session(s, w)
	id, pid, session := entry.id, term.process_id(entry.session), entry.session
	source := app.selected_tab(w.workspace)
	preview := app.pane_window_preview_create(s, source, w.tree.focus)
	if !testing.expect(t, preview != nil) {return}
	preview_id := preview.id
	app.pane_drag_press(s, w, w.tree.focus, 30, 60)
	w.pane_drag.preview_window = preview_id
	app.handle_event(s, platform.Capture_Lost_Event{preview_id})
	testing.expect(t, app.window_find(s, preview_id) == nil)
	app.handle_event(s, platform.Focus_Event{preview_id, false})
	app.handle_event(s, platform.Mouse_Button_Event{window = preview_id, button = .Left})
	gesture_button(s, w, .Left, false, f32(w.width)-20, 10)
	testing.expect(t, !w.pane_drag.pressed && !w.pane_drag.active)
	testing.expect_value(t, len(s.windows), 2)
	testing.expect_value(t, len(w.panes), 2)
	entry = app.session_find(s, id)
	if !testing.expect(t, entry != nil && entry.session == session) {return}
	testing.expect_value(t, term.process_id(entry.session), pid)
	testing.expect_value(t, term.status(entry.session).kind, term.Status_Kind.Running)
}

@(test)
gestures_completion_removes_source_window_and_preserves_both_runtimes :: proc(t: ^testing.T) {
	for to_tab in ([?]bool{false, true}) {
		f: Palette_Fixture
		defer palette_fixture_destroy(t, &f)
		if !palette_fixture_create(t, &f, "gesture-transfer") {return}
		s := &f.state
		w, target := s.windows[0], s.windows[1]
		source, destination := app.selected_tab(w.workspace), app.selected_tab(target.workspace)
		window_id, workspace_id := w.id, w.workspace.id
		ids := [?]u32{s.sessions[0].id, s.sessions[1].id}
		sessions := [?]^term.Session{s.sessions[0].session, s.sessions[1].session}
		pids := [?]u32{term.process_id(sessions[0]), term.process_id(sessions[1])}
		w.pane_drag = {pressed = true, active = true, shown = true, new_tab = to_tab,
			source = source, destination = destination, node = source.tree.root,
			target = destination.tree.root, destination_window = target.id, direction = .Right}
		app.handle_event(s, platform.Mouse_Button_Event{window = window_id, button = .Left})
		testing.expect(t, app.window_find(s, window_id) == nil)
		testing.expect(t, app.workspace_find(s, workspace_id) == nil)
		app.handle_event(s, platform.Mouse_Move_Event{window = window_id, x = 100, y = 100})
		app.handle_event(s, platform.Mouse_Button_Event{window = window_id, button = .Right})
		testing.expect_value(t, len(s.windows), 1)
		testing.expect_value(t, len(s.sessions), 2)
		testing.expect_value(t, len(target.workspace.tabs), to_tab ? 2 : 1)
		testing.expect_value(t, len(target.panes), to_tab ? 1 : 2)
		for entry, i in s.sessions {
			testing.expect_value(t, entry.id, ids[i])
			testing.expect(t, entry.session == sessions[i])
			testing.expect_value(t, term.process_id(entry.session), pids[i])
			testing.expect_value(t, term.status(entry.session).kind, term.Status_Kind.Running)
		}
	}
}

@(private)
gesture_screen :: proc(session: ^term.Session) -> string {
	term.select_all(session)
	text, _ := term.selection_text(session, context.temp_allocator)
	term.clear_selection(session)
	return text
}

@(private)
gesture_terminal_packets :: proc(t: ^testing.T, report: bool) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, report ? "gesture-packets-report" : "gesture-packets-ui") {return}
	s, w := &f.state, f.state.windows[0]
	cwd, cwd_error := os.get_working_directory(context.temp_allocator)
	if !testing.expect_value(t, cwd_error, nil) {return}
	command := fmt.tprintf("pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"%s/tests/live/header_mouse_fixture.ps1\"", cwd)
	entry := app.focused_session(s, w)
	session, err := term.create({command_line = command, working_directory = cwd,
		geometry = term.geometry(entry.session)}, {})
	if !testing.expect_value(t, err, term.Error.None) {return}
	defer term.destroy(session)
	original := entry.session
	entry.session = session
	entry_id := entry.id
	defer app.session_find(s, entry_id).session = original
	start := time.tick_now()
	for !term.mouse_tracking(session) && time.tick_since(start) < 10*time.Second {
		time.sleep(time.Millisecond)
	}
	if !testing.expect(t, term.mouse_tracking(session)) {return}
	if report {
		pane := w.panes[0].rect
		px, py := pane.x + 30, pane.y + 30
		gesture_button(s, w, .Left, true, px, py)
		app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = i32(px + 10), y = i32(py), buttons = {.Left}})
		gesture_button(s, w, .Left, false, px + 10, py)
	} else {
		layout, _ := app.rail_current_layout(w)
		row := app.rail_row_index_for_tab(w.rail_rows[:], w.workspace, 0)
		close := ui.rail_close_rect(layout, row, w.scale)
		gesture_button(s, w, .Left, true, close.x+4, close.y+4)
		app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = 100, y = 200, buttons = {.Left}})
		app.handle_event(s, platform.Capture_Lost_Event{w.id})
		app.handle_event(s, platform.Mouse_Move_Event{window = w.id, x = 110, y = 200, buttons = {.Left}})
		gesture_button(s, w, .Left, false, 110, 200)
		app.pane_split(s, w, .Right)
		h := gesture_header(w)
		for button in ([?]input.Mouse_Button{.Left, .Right, .Middle}) {
			gesture_button(s, w, button, true, h.title.x+4, h.title.y+4)
		}
		app.palette_open(s, w)
		app.window_overlays_cancel(s, w)
		for button in ([?]input.Mouse_Button{.Left, .Right, .Middle}) {
			gesture_button(s, w, button, false, 100, 200)
		}
	}
	term.send_text(session, "q")
	start = time.tick_now()
	for term.status(session).kind == .Running && time.tick_since(start) < 10*time.Second {
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Exited)
	text := gesture_screen(session)
	if report {
		testing.expectf(t, strings.contains(text, "MOUSE_BYTES=1B5B3C30") &&
			strings.contains(text, "1B5B3C3332") && strings.contains(text, "6D"),
			"missing press/motion/release reports: %s", text)
	} else {
		testing.expectf(t, strings.contains(text, "MOUSE_BYTES=none"), "unexpected mouse packets: %s", text)
	}
}

@(test)
gestures_ui_motion_and_cancelled_buttons_send_no_terminal_packets :: proc(t: ^testing.T) {
	gesture_terminal_packets(t, false)
}

@(test)
gestures_terminal_press_motion_release_keep_reporting :: proc(t: ^testing.T) {
	gesture_terminal_packets(t, true)
}

@(private)
gesture_settings_header :: proc(w: ^app.Window) -> (ui.Header_Layout, bool) {
	for pane in w.panes {
		if pane.content.kind != .Settings {continue}
		r := pane.rect
		return ui.header_layout({r.x, r.y, r.width, r.height}, w.scale),
			true
	}
	return {}, false
}

@(private)
gesture_click_header :: proc(
	s: ^app.App,
	w: ^app.Window,
	button: int,
	h: ui.Header_Layout,
) {
	r := h.buttons[button]
	gesture_button(s, w, .Left, true, r.x + r.width / 2, r.y + r.height / 2)
	gesture_button(s, w, .Left, false, r.x + r.width / 2, r.y + r.height / 2)
}

// Settings is ordinary pane content, so its header controls run the same commands as a terminal.
@(test)
gestures_settings_header_split_buttons_create_terminal_panes :: proc(t: ^testing.T) {
	for action in ([?]ui.Header_Action{.Split_Right, .Split_Down}) {
		f: Palette_Fixture
		defer palette_fixture_destroy(t, &f)
		if !palette_fixture_create(t, &f, "gesture-settings-split") {return}
		s, w := &f.state, f.state.windows[0]
		app.editor_open(s, w)
		if !testing.expect(t, app.settings_active(w)) {return}
		sessions, tabs := len(s.sessions), len(w.workspace.tabs)
		h, found := gesture_settings_header(w)
		if !testing.expect(t, found) {return}
		gesture_click_header(s, w, int(action) - 1, h)
		testing.expect_value(t, len(w.panes), 2)
		testing.expect_value(t, len(w.workspace.tabs), tabs)
		testing.expect_value(t, len(s.sessions), sessions + 1)
	}
}

@(test)
gestures_settings_header_zoom_and_close_drive_the_settings_pane :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "gesture-settings-zoom-close") {return}
	s, w := &f.state, f.state.windows[0]
	app.editor_open(s, w)
	if !testing.expect(t, app.settings_active(w)) {return}
	h, found := gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	gesture_click_header(s, w, int(ui.Header_Action.Zoom) - 1, h)
	if !testing.expect(t, w.tree.zoomed) {return}
	h, found = gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	gesture_click_header(s, w, int(ui.Header_Action.Zoom) - 1, h)
	testing.expect(t, !w.tree.zoomed)
	sessions, tabs := len(s.sessions), len(w.workspace.tabs)
	h, found = gesture_settings_header(w)
	if !testing.expect(t, found) {return}
	gesture_click_header(s, w, int(ui.Header_Action.Close) - 1, h)
	testing.expect(t, !ui.editor_loaded(&w.editor))
	testing.expect(t, !app.settings_active(w))
	testing.expect_value(t, len(w.workspace.tabs), tabs - 1)
	testing.expect_value(t, len(s.sessions), sessions)
}
