package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"
import "core:time"
import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "aio:ui"

Action :: enum u32 {
	Command_Palette,
	Copy,
	Paste,
	Select_All,
	Find,
	Clear_Scrollback,
	Scroll_Page_Up,
	Scroll_Page_Down,
	Font_Size_Increase,
	Font_Size_Decrease,
	Font_Size_Reset,
	Open_Settings,
	Reload_Settings,
	Restart_Shell,
	Hide_To_Tray,
	Quit,
	New_Tab,
	Close_Pane,
	Next_Tab,
	Previous_Tab,
	Tab_1,
	Tab_2,
	Tab_3,
	Tab_4,
	Tab_5,
	Tab_6,
	Tab_7,
	Tab_8,
	Tab_9,
	Split_Right,
	Split_Down,
	Focus_Left,
	Focus_Right,
	Focus_Up,
	Focus_Down,
	Resize_Left,
	Resize_Right,
	Resize_Up,
	Resize_Down,
	Focus_Previous,
	Focus_Next,
	Last_Tab,
	Close_Tab,
	Settings_UI,
	Split,
	Split_Left,
	Split_Up,
	Zoom_Pane,
	Balance_Panes,
	Swap_Left,
	Swap_Right,
	Swap_Up,
	Swap_Down,
	Swap_Previous,
	Swap_Next,
	Resize_Left_Large,
	Resize_Right_Large,
	Resize_Up_Large,
	Resize_Down_Large,
	Keep_Pane_Open,
	Change_Shortcut,
	Follow_Theme_Colors,
	Rename_Tab,
	Rename_Pane,
	Duplicate_Tab,
	Move_Tab_Left,
	Move_Tab_Right,
	Move_Tab_Start,
	Move_Tab_End,
	Close_Other_Tabs,
	Close_Right_Tabs,
	Tab_Settings,
	New_Workspace,
	Change_Workspace,
	Rename_Workspace,
	New_Window,
}

@(private)
Action_Info :: struct {
	name, title: string,
	shortcuts: []commands.Shortcut,
}

@(private)
ACTIONS :: [Action]Action_Info{
	.New_Workspace = {"workspace.new", "New Workspace", nil},
	.Change_Workspace = {"workspace.change", "Change Workspace…", nil},
	.Rename_Workspace = {"workspace.rename", "Rename Workspace…", nil},
	.New_Window = {"window.new", "New Window", {{.N, {.Control, .Shift}}}},
	.Command_Palette = {"app.command_palette", "Show Command Palette", {{.P, {.Control, .Shift}}}},
	.Copy = {"edit.copy", "Copy", {{.C, {.Control, .Shift}}, {.Insert, {.Control}}}},
	.Paste = {"edit.paste", "Paste", {{.V, {.Control, .Shift}}, {.Insert, {.Shift}}}},
	.Select_All = {"edit.select_all", "Select All", {{.A, {.Control, .Shift}}}},
	.Find = {"terminal.find", "Find in Scrollback", {{.F, {.Control, .Shift}}}},
	.Clear_Scrollback = {"terminal.clear_scrollback", "Clear Scrollback", {{.K, {.Control, .Shift}}}},
	.Scroll_Page_Up = {"terminal.scroll_page_up", "Scroll Up One Page", {{.Page_Up, {.Shift}}}},
	.Scroll_Page_Down = {"terminal.scroll_page_down", "Scroll Down One Page", {{.Page_Down, {.Shift}}}},
	.Font_Size_Increase = {
		"view.font_size_increase", "Increase Font Size", {{.Equal, {.Control}}, {.Numpad_Add, {.Control}}},
	},
	.Font_Size_Decrease = {
		"view.font_size_decrease", "Decrease Font Size", {{.Minus, {.Control}}, {.Numpad_Subtract, {.Control}}},
	},
	.Font_Size_Reset = {
		"view.font_size_reset", "Reset Font Size", {{.Digit_0, {.Control}}, {.Numpad_0, {.Control}}},
	},
	.Open_Settings = {"settings.open_file", "Open Settings File", nil},
	.Settings_UI = {"settings.open", "Settings", {{.Comma, {.Control}}}},
	.Rename_Tab = {"tab.rename", "Rename Tab", nil},
	.Rename_Pane = {"pane.rename", "Rename Pane", nil},
	.Duplicate_Tab = {"tab.duplicate", "Duplicate Tab", nil},
	.Move_Tab_Left = {"tab.move_left", "Move Tab Left", nil},
	.Move_Tab_Right = {"tab.move_right", "Move Tab Right", nil},
	.Move_Tab_Start = {"tab.move_start", "Move Selected Tabs to Start", nil},
	.Move_Tab_End = {"tab.move_end", "Move Selected Tabs to End", nil},
	.Close_Other_Tabs = {"tab.close_others", "Close Other Tabs", nil},
	.Close_Right_Tabs = {"tab.close_right", "Close Tabs to the Right", nil},
	.Tab_Settings = {"tab.settings", "Tab Settings", nil},
	.Reload_Settings = {"settings.reload", "Reload Settings", {{.Comma, {.Control, .Shift}}}},
	.Restart_Shell = {"terminal.restart_shell", "Restart Shell", nil},
	.Hide_To_Tray = {"app.hide_to_tray", "Hide to Tray", nil},
	.Quit = {"app.quit", "Quit AIODev", {{.Q, {.Control, .Shift}}}},
	.New_Tab = {"tab.new", "New Tab", {{.T, {.Control, .Shift}}}},
	.Close_Pane = {"pane.close", "Close Pane", nil},
	.Next_Tab = {"tab.next", "Next Tab",
		{{.Tab, {.Control}}, {.Arrow_Right, {.Control, .Shift}}, {.Page_Down, {.Control}}}},
	.Previous_Tab = {"tab.previous", "Previous Tab",
		{{.Tab, {.Control, .Shift}}, {.Arrow_Left, {.Control, .Shift}}, {.Page_Up, {.Control}}}},
	.Tab_1 = {"tab.select_1", "Select Tab 1", {{.Digit_1, {.Alt}}}},
	.Tab_2 = {"tab.select_2", "Select Tab 2", {{.Digit_2, {.Alt}}}},
	.Tab_3 = {"tab.select_3", "Select Tab 3", {{.Digit_3, {.Alt}}}},
	.Tab_4 = {"tab.select_4", "Select Tab 4", {{.Digit_4, {.Alt}}}},
	.Tab_5 = {"tab.select_5", "Select Tab 5", {{.Digit_5, {.Alt}}}},
	.Tab_6 = {"tab.select_6", "Select Tab 6", {{.Digit_6, {.Alt}}}},
	.Tab_7 = {"tab.select_7", "Select Tab 7", {{.Digit_7, {.Alt}}}},
	.Tab_8 = {"tab.select_8", "Select Tab 8", {{.Digit_8, {.Alt}}}},
	.Tab_9 = {"tab.select_9", "Select Tab 9", nil},
	.Split_Right = {"pane.split_right", "Split Right", {{.O, {.Control, .Shift}}}},
	.Split_Down = {"pane.split_down", "Split Down", {{.E, {.Control, .Shift}}}},
	.Focus_Left = {"pane.focus_left", "Focus Left", {{.Arrow_Left, {.Control, .Alt}}}},
	.Focus_Right = {"pane.focus_right", "Focus Right", {{.Arrow_Right, {.Control, .Alt}}}},
	.Focus_Up = {"pane.focus_up", "Focus Up", {{.Arrow_Up, {.Control, .Alt}}}},
	.Focus_Down = {"pane.focus_down", "Focus Down", {{.Arrow_Down, {.Control, .Alt}}}},
	.Resize_Left = {"pane.resize_left", "Resize Left", {{.Arrow_Left, {.Control, .Super, .Shift}}}},
	.Resize_Right = {"pane.resize_right", "Resize Right", {{.Arrow_Right, {.Control, .Super, .Shift}}}},
	.Resize_Up = {"pane.resize_up", "Resize Up", {{.Arrow_Up, {.Control, .Super, .Shift}}}},
	.Resize_Down = {"pane.resize_down", "Resize Down", {{.Arrow_Down, {.Control, .Super, .Shift}}}},
	.Focus_Previous = {"pane.focus_previous", "Focus Previous Pane", {{.Bracket_Left, {.Control, .Super}}}},
	.Focus_Next = {"pane.focus_next", "Focus Next Pane", {{.Bracket_Right, {.Control, .Super}}}},
	.Last_Tab = {"tab.last", "Select Last Tab", {{.Digit_9, {.Alt}}}},
	.Close_Tab = {"tab.close", "Close Selected Tabs", {{.W, {.Control, .Shift}}}},
	.Split = {"pane.split", "Split Pane", nil},
	.Split_Left = {"pane.split_left", "Split Left", nil},
	.Split_Up = {"pane.split_up", "Split Up", nil},
	.Zoom_Pane = {"pane.zoom", "Toggle Pane Zoom", nil},
	.Balance_Panes = {"pane.balance", "Balance All Splits", nil},
	.Swap_Left = {"pane.swap_left", "Swap Pane Left", nil},
	.Swap_Right = {"pane.swap_right", "Swap Pane Right", nil},
	.Swap_Up = {"pane.swap_up", "Swap Pane Up", nil},
	.Swap_Down = {"pane.swap_down", "Swap Pane Down", nil},
	.Swap_Previous = {"pane.swap_previous", "Swap With Previous Pane", nil},
	.Swap_Next = {"pane.swap_next", "Swap With Next Pane", nil},
	.Resize_Left_Large = {"pane.resize_left_large", "Resize Left by 50 Pixels", nil},
	.Resize_Right_Large = {"pane.resize_right_large", "Resize Right by 50 Pixels", nil},
	.Resize_Up_Large = {"pane.resize_up_large", "Resize Up by 50 Pixels", nil},
	.Resize_Down_Large = {"pane.resize_down_large", "Resize Down by 50 Pixels", nil},
	.Keep_Pane_Open = {"pane.keep_open", "Toggle Keep Pane Open After Exit", nil},
	.Change_Shortcut = {"settings.change_shortcut", "Change Shortcut…", nil},
	.Follow_Theme_Colors = {"settings.follow_theme_colors", "Use Theme for Shell Foreground and Background", nil},
}

@(require_results)
register_actions :: proc(registry: ^commands.Registry) -> commands.Error {
	@(static, rodata) actions := ACTIONS
	for info, action in actions {
		command := commands.Command{
			id = commands.Command_Id(action),
			name = info.name,
			title = info.title,
			shortcuts = {info.shortcuts, len(info.shortcuts)},
		}
		if err := commands.register(registry, command); err != .None { return err }
	}
	return .None
}

shortcut_action :: proc(app: ^App, e: platform.Key_Event) -> (Action, bool) {
	if command := commands.find_by_key(&app.registry, e.key, e.modifiers, e.unshifted); command != nil {
		return Action(command.id), true
	}
	return {}, false
}

run_action :: proc(
	app: ^App, w: ^Window, action: Action,
	split_direction: layout.Direction = .Right, split_ratio: f32 = 0.5, split_focus := true,
) {
	if w.pane_drag.pressed || w.tab_drag.pressed { arrange_cancel(app, w) }
	entry := focused_session(app, w)
	w.dirty = true
	switch action {
	case .Command_Palette:
		leader_cancel(w)
		pane_header_cancel(w)
		if app.palette.open {
			ui.palette_close(&app.palette)
			return
		}
		has_selection := entry != nil && term.has_selection(entry.session)
		registered := commands.set_enabled(&app.registry, commands.Command_Id(Action.Copy), has_selection)
		assert(registered)
		ui.palette_open(&app.palette, &app.registry)
	case .Copy:
		if entry != nil {
			copy_selection(app, entry, true)
		}
	case .Paste:
		if entry != nil {
			paste_clipboard(app, w, entry)
		}
	case .Select_All:
		if entry != nil {
			term.select_all(entry.session)
		}
	case .Find:
		if entry == nil { return }
		leader_cancel(w)
		pane_header_cancel(w)
		if w.find.open {
			find_close(w, entry)
		} else {
			ui.find_open(&w.find)
		}
	case .Clear_Scrollback:
		if entry != nil {
			term.clear_scrollback(entry.session)
		}
	case .Scroll_Page_Up, .Scroll_Page_Down:
		if entry != nil {
			page := max(1, int(term.geometry(entry.session).rows) - 1)
			term.scroll_viewport(entry.session, action == .Scroll_Page_Up ? -page : page)
		}
	case .Font_Size_Increase:
		set_font_points(app, app.font_points + 1)
	case .Font_Size_Decrease:
		set_font_points(app, app.font_points - 1)
	case .Font_Size_Reset:
		set_font_points(app, f32(app.settings.font.size))
	case .Open_Settings:
		if !platform.open_path(app.settings_path) {
			notify(app, .Error, fmt.tprintf("Could not open %s.", app.settings_path))
		}
	case .Settings_UI:
		pane_header_cancel(w)
		editor_open(app, w)
	case .Change_Shortcut:
		editor_open(app, w)
		if w.editor.open {
			ui.field_set(&w.editor.filter, "keys.")
			ui.editor_filter(&w.editor)
		}
	case .Reload_Settings:
		reload_settings(app)
	case .Follow_Theme_Colors: editor_follow_theme(app, w)
	case .Rename_Tab: rename_open(app, w, true)
	case .Rename_Pane: rename_open(app, w, false)
	case .Duplicate_Tab: tab_duplicate(app, w)
	case .Move_Tab_Left: tab_move(app, w, w.workspace.selected, max(0, w.workspace.selected-1))
	case .Move_Tab_Right: tab_move(app, w, w.workspace.selected, min(len(w.workspace.tabs)-1, w.workspace.selected+1))
	case .Move_Tab_Start, .Move_Tab_End: tab_move_group(app, w, action == .Move_Tab_End)
	case .Close_Other_Tabs, .Close_Right_Tabs: tab_close_subset(app, w, action == .Close_Right_Tabs)
	case .Tab_Settings:
		editor_open(app, w)
		ui.field_set(&w.editor.filter, "")
		ui.editor_filter(&w.editor)
		ui.editor_select_key(&w.editor, "tab.confirm_close")
	case .Restart_Shell:
		if entry != nil {
			session_restart(app, entry)
		}
	case .Hide_To_Tray:
		hide_to_tray(app, w)
	case .Quit:
		app.running = false
	case .New_Tab: tab_new(app, w)
	case .New_Workspace: workspace_new(app, w, false)
	case .Change_Workspace: workspace_picker_open(app, w)
	case .Rename_Workspace: workspace_rename_open(app, w)
	case .New_Window: workspace_new(app, w, true)
	case .Close_Pane: pane_close(app, w)
	case .Next_Tab: tab_select(app, w, (w.workspace.selected+1)%len(w.workspace.tabs))
	case .Previous_Tab:
		tab_select(app, w, (w.workspace.selected+len(w.workspace.tabs)-1)%len(w.workspace.tabs))
	case .Tab_1, .Tab_2, .Tab_3, .Tab_4, .Tab_5, .Tab_6, .Tab_7, .Tab_8, .Tab_9:
		tab_select(app, w, int(action)-int(Action.Tab_1))
	case .Last_Tab: tab_select(app, w, len(w.workspace.tabs)-1)
	case .Close_Tab: tab_close_request(app, w, w.workspace.selected)
	case .Focus_Previous, .Focus_Next:
		pane_focus(app, w, layout.focus_cycle(pane_action_rects(app, w), w.tree.focus,
			action == .Focus_Next ? 1 : -1))
	case .Split: pane_split(app, w, split_direction, split_ratio, split_focus)
	case .Split_Right: pane_split(app, w, .Right)
	case .Split_Down: pane_split(app, w, .Down)
	case .Split_Left: pane_split(app, w, .Left)
	case .Split_Up: pane_split(app, w, .Up)
	case .Zoom_Pane: pane_zoom(app, w)
	case .Balance_Panes:
		layout.balance(w.tree)
		window_relayout(app, w)
	case .Keep_Pane_Open: pane_keep_open(app, w)
	case .Swap_Left, .Swap_Right, .Swap_Up, .Swap_Down, .Swap_Previous, .Swap_Next:
		rects := pane_action_rects(app, w)
		target: layout.Node_Id
		if action == .Swap_Previous || action == .Swap_Next {
			target = layout.focus_cycle(rects, w.tree.focus, action == .Swap_Next ? 1 : -1)
		} else {
			target = layout.focus_direction(rects, w.tree.focus, layout.Direction(int(action)-int(Action.Swap_Left)))
		}
		if target != w.tree.focus {
			w.selecting, w.autoscrolling = false, false
			w.dragging = {}
			w.wheel_remainder = 0
			if layout.swap(w.tree, w.tree.focus, target) { window_relayout(app, w) }
			reset_blink(w)
		}
	case .Focus_Left, .Focus_Right, .Focus_Up, .Focus_Down:
		direction := layout.Direction(int(action)-int(Action.Focus_Left))
		pane_focus(app, w, layout.focus_direction(pane_action_rects(app, w), w.tree.focus, direction))
	case .Resize_Left, .Resize_Right, .Resize_Up, .Resize_Down:
		axis: layout.Axis = action == .Resize_Left || action == .Resize_Right ? .Horizontal : .Vertical
		delta: f32 = action == .Resize_Left || action == .Resize_Up ? -10 : 10
		if layout.resize_pixels(w.tree, w.tree.focus, axis, delta, w.dividers[:]) { window_relayout(app, w) }
	case .Resize_Left_Large, .Resize_Right_Large, .Resize_Up_Large, .Resize_Down_Large:
		axis: layout.Axis = action == .Resize_Left_Large || action == .Resize_Right_Large ? .Horizontal : .Vertical
		delta: f32 = action == .Resize_Left_Large || action == .Resize_Up_Large ? -50 : 50
		if layout.resize_pixels(w.tree, w.tree.focus, axis, delta, w.dividers[:]) { window_relayout(app, w) }
	}
}

@(private)
pane_action_rects :: proc(app: ^App, w: ^Window) -> []layout.Pane_Rect {
	if !w.tree.zoomed { return w.panes[:] }
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(w.tree, window_content_area(app, w), window_gap(app, w), &rects, false)
	return rects[:]
}

copy_selection :: proc(app: ^App, entry: ^Session_Entry, explicit: bool) {
	text, selected := term.selection_text(entry.session, context.temp_allocator)
	if !selected {
		return
	}
	if !platform.clipboard_set_text(&app.platform, text) {
		notify(app, .Error, "Could not copy to the clipboard.")
	} else {
		ui.notices_put(&app.notices, u32(Notice_Key.Copy), .Info, "Copied to clipboard", COPY_NOTICE_DURATION)
		mark_all_dirty(app)
		if explicit { term.clear_selection(entry.session) }
	}
}

// Pastes into the find bar when it is open, otherwise into the shell. Text the shell would run line by line
// waits for a second paste within PASTE_CONFIRM_DURATION.
paste_clipboard :: proc(app: ^App, w: ^Window, entry: ^Session_Entry) {
	text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
	if !ok || len(text) == 0 {
		return
	}
	if w.find.open {
		line := text
		if end := strings.index_any(text, "\r\n"); end >= 0 {
			line = text[:end]
		}
		on_find_outcome(w, entry, ui.find_text(&w.find, line))
		return
	}
	if entry.status != .Running {
		notify(app, .Error, "Could not paste: the shell is not running.")
		return
	}
	confirmed := !app.settings.terminal.confirm_multiline_paste ||
		time.tick_diff(time.tick_now(), w.paste_confirm_until) > 0
	switch term.paste(entry.session, text, confirmed) {
	case .Sent:
		paste_confirm_cancel(app, w)
	case .Unsafe:
		w.paste_confirm_until = time.tick_add(time.tick_now(), PASTE_CONFIRM_DURATION)
		ui.notices_put(&app.notices, u32(Notice_Key.Paste), .Info, PASTE_CONFIRM_TEXT, PASTE_CONFIRM_DURATION)
		mark_all_dirty(app)
	case .Failed:
		notify(app, .Error, "Could not paste: the shell is not accepting input.")
	}
}

paste_confirm_cancel :: proc(app: ^App, w: ^Window) {
	if w.paste_confirm_until == {} {
		return
	}
	w.paste_confirm_until = {}
	ui.notices_clear(&app.notices, u32(Notice_Key.Paste))
	mark_all_dirty(app)
}

// Ends the search and returns the session to its live screen.
find_close :: proc(w: ^Window, entry: ^Session_Entry) {
	ui.find_close(&w.find)
	w.dirty = true
	if entry != nil {
		term.search_set_needle(entry.session, "")
		term.scroll_to_bottom(entry.session)
	}
}

on_find_outcome :: proc(w: ^Window, entry: ^Session_Entry, outcome: ui.Find_Outcome) {
	if outcome == .None {
		return
	}
	w.dirty = true
	if entry == nil {
		return
	}
	switch outcome {
	case .None, .Moved:
	case .Changed:
		term.search_set_needle(entry.session, ui.field_string(&w.find.query))
	case .Older, .Newer:
		term.search_select(entry.session, outcome == .Older)
	case .Closed:
		find_close(w, entry)
	}
}

// The find bar's match count: "3 of 17" once a match is selected.
find_status :: proc(w: ^Window, entry: ^Session_Entry) -> string {
	if entry == nil || len(w.find.query.bytes) == 0 {
		return ""
	}
	s := term.search_summary(entry.session)
	switch {
	case s.selected >= 0:
		return fmt.tprintf("%d of %d", s.selected + 1, s.total)
	case s.total == 1:
		return "1 match"
	case s.total > 0:
		return fmt.tprintf("%d matches", s.total)
	case !s.complete:
		return "Searching…"
	}
	return "No matches"
}

@(private)
binding_comment :: proc(info: Action_Info) -> string {
	labels := make([]string, len(info.shortcuts), context.temp_allocator)
	for shortcut, i in info.shortcuts {
		buffer: [128]u8
		label, err := commands.shortcut_label(shortcut, buffer[:])
		assert(err == .None)
		labels[i] = fmt.tprintf("%s", label)
	}
	if len(info.shortcuts) == 0 { return fmt.tprintf("keys.%s =", info.name) }
	joined := strings.join(labels[:len(info.shortcuts)], ", ", context.temp_allocator)
	return fmt.tprintf("keys.%s = %s", info.name, joined)
}

@(private)
binding_comments :: proc() -> [len(Action)+1]string {
	lines: [len(Action)+1]string
	lines[0] = "Shortcuts: uncomment a line to change it. Separate several with commas; " +
		"leave the value empty to remove them."
	@(static, rodata) actions := ACTIONS
	for info, action in actions {
		lines[int(action)+1] = binding_comment(info)
	}
	return lines
}

@(private)
binding_diagnostic :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic,
	binding: settings.Key_Binding, message: string) {
	key := fmt.tprintf("%s%s", settings.KEY_BINDING_PREFIX, binding.name)
	settings_diagnostic(app, diagnostics, binding.line, key, message)
}

@(private)
settings_diagnostic :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic,
	line: int, key, message: string, kind: settings.Diagnostic_Kind = .Invalid_Value) {
	if err := settings.diagnostic_append(diagnostics, line, key, message, kind); err != nil {
		log.errorf("recording shortcut diagnostic failed: %v", err)
		notify(app, .Error, message)
	}
}

@(private)
apply_bindings :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic) {
	overrides: [len(Action)]commands.Override
	lines: [len(Action)]int
	count := 0
	for binding, i in app.settings.keys {
		command := commands.find(&app.registry, binding.name)
		if command == nil {
			binding_diagnostic(app, diagnostics, binding, fmt.tprintf("unknown command \"%s\"", binding.name))
			continue
		}
		storage := make([]commands.Shortcut, len(binding.value)+1, context.temp_allocator)
		n, err := commands.parse_shortcuts(binding.value, storage)
		if err != .None {
			message := fmt.tprintf("cannot parse shortcut \"%s\"", binding.value)
			binding_diagnostic(app, diagnostics, binding, message)
			continue
		}
		unsupported := false
		for shortcut in storage[:n] {
			if .Leader in shortcut.modifiers &&
			   (shortcut.key == .Unidentified || is_modifier_key(shortcut.key)) {
				unsupported = true
			}
		}
		if unsupported {
			binding_diagnostic(app, diagnostics, binding, "Leader shortcuts require a nonmodifier key.")
			continue
		}
		overrides[count] = {command.id, storage[:n]}
		lines[count] = i
		count += 1
	}
	errors: [len(Action)]commands.Error
	if commands.rebind(&app.registry, overrides[:count], errors[:count]) != .None {
		notify(app, .Error, "Could not allocate shortcut bindings.")
		return
	}
	applied_lines: [len(Action)]int
	for error, i in errors[:count] {
		if error == .None { applied_lines[int(overrides[i].id)] = app.settings.keys[lines[i]].line }
	}
	for error, i in errors[:count] {
		if error == .None { continue }
		binding := app.settings.keys[lines[i]]
		message := fmt.tprintf("cannot apply shortcuts for \"%s\": %v", binding.name, error)
		if error == .Duplicate_Shortcut {
			for shortcut in overrides[i].shortcuts {
				other := commands.find_by_shortcut(&app.registry, shortcut)
				if other != nil && other.id != overrides[i].id {
					buffer: [128]u8
					label, label_error := commands.shortcut_label(shortcut, buffer[:])
					assert(label_error == .None)
					message = fmt.tprintf("shortcut \"%s\" for %s (%s at %s) already used by %s (%s at %s)",
						label, commands.find(&app.registry, binding.name).title, binding.name,
						binding_origin(app, binding.line), other.title, other.name,
						binding_origin(app, applied_lines[int(other.id)]))
					break
				}
			}
		}
		binding_diagnostic(app, diagnostics, binding, message)
	}
	app.leader = nil
	if app.settings.input.leader != "" {
		leader, valid := commands.parse_shortcut(app.settings.input.leader)
		if !valid || .Leader in leader.modifiers || leader.key == .Unidentified || is_modifier_key(leader.key) {
			settings_diagnostic(app, diagnostics, app.settings.leader_line,
				"input.leader", "Use one ordinary shortcut.")
		} else {
			app.leader = leader
			// Decide once across every matching identity mode before removing any
			// chord, so a later direct binding cannot leave partial removals behind.
			winner: ^commands.Command
			for &other in app.registry.items {
				for shortcut in commands.active_shortcuts(&other) {
					if commands.prefix_conflicts(leader, shortcut) &&
						applied_lines[int(other.id)] >= app.settings.leader_line &&
						(winner == nil || applied_lines[int(other.id)] > applied_lines[int(winner.id)]) {
						winner = &other
					}
				}
			}
			leader_wins := winner == nil
			if !leader_wins { app.leader = nil }
			for &other in app.registry.items {
				// Copy because unbind compacts the active shortcut array.
				shortcuts := slice.clone(commands.active_shortcuts(&other), context.temp_allocator)
				for shortcut in shortcuts {
					if !commands.prefix_conflicts(leader, shortcut) { continue }
					if leader_wins { _ = commands.unbind(&app.registry, other.id, shortcut) }
					message := fmt.tprintf("input.leader vs %s (%s); %s wins [%s:%d; %s]",
						other.title, other.name, leader_wins ? "input.leader" : winner.name,
						binding_file(app), app.settings.leader_line, binding_origin(app, applied_lines[int(other.id)]))
					settings_diagnostic(app, diagnostics, app.settings.leader_line,
						"input.leader", message, .Shortcut_Warning)
				}
			}
		}
	}
}

@(private)
binding_origin :: proc(app: ^App, line: int) -> string {
	if line > 0 { return fmt.tprintf("%s:%d", binding_file(app), line) }
	return "defaults"
}

@(private)
binding_file :: proc(app: ^App) -> string {
	i := max(strings.last_index_byte(app.settings_path, '/'), strings.last_index_byte(app.settings_path, '\\'))
	return app.settings_path[i+1:]
}
