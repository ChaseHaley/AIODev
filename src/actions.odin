package main

import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:term"
import "aio:ui"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

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
	Customize_Colors,
	Rename_Tab,
	Rename_Pane,
	Change_Pane_Shell,
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
	Delete_Workspace,
	Change_Workspace_Icon,
	Workspace_1,
	Workspace_2,
	Workspace_3,
	Workspace_4,
	Workspace_5,
	Workspace_6,
	Workspace_7,
	Workspace_8,
	Workspace_9,
	Show_Build_Info,
	Profile_1,
	Profile_2,
	Profile_3,
	Profile_4,
	Profile_5,
	Profile_6,
	Profile_7,
	Profile_8,
	Profile_9,
	Palette_Tabs,
	Palette_Workspaces,
	Palette_Settings,
	Palette_Commands,
	Toggle_Tabs_Rail,
	Toggle_Tabs_Orientation,
	Status_Next,
	Status_Inbox,
	Status_Panel,
	Status_Board,
	Status_Dismiss_Finished,
}

@(private)
Action_Info :: struct {
	name, title: string,
	shortcuts: []commands.Shortcut,
}

@(private)
ACTIONS :: [Action]Action_Info {
	.Show_Build_Info = {"app.build_info", "Show Build Info", nil},
	.New_Workspace = {"workspace.new", "New Workspace", nil},
	.Change_Workspace = {"workspace.change", "Change Workspace…", nil},
	.Rename_Workspace = {"workspace.rename", "Rename Workspace…", nil},
	.New_Window = {"window.new", "New Window", {{.N, {.Control, .Shift}}}},
	.Delete_Workspace = {"workspace.delete", "Delete Workspace…", nil},
	.Change_Workspace_Icon = {"workspace.change_icon", "Change Workspace Icon…", nil},
	.Workspace_1 = {"workspace.select_1", "Select Workspace 1", {{.Digit_1, {.Control, .Shift}}}},
	.Workspace_2 = {"workspace.select_2", "Select Workspace 2", {{.Digit_2, {.Control, .Shift}}}},
	.Workspace_3 = {"workspace.select_3", "Select Workspace 3", {{.Digit_3, {.Control, .Shift}}}},
	.Workspace_4 = {"workspace.select_4", "Select Workspace 4", {{.Digit_4, {.Control, .Shift}}}},
	.Workspace_5 = {"workspace.select_5", "Select Workspace 5", {{.Digit_5, {.Control, .Shift}}}},
	.Workspace_6 = {"workspace.select_6", "Select Workspace 6", {{.Digit_6, {.Control, .Shift}}}},
	.Workspace_7 = {"workspace.select_7", "Select Workspace 7", {{.Digit_7, {.Control, .Shift}}}},
	.Workspace_8 = {"workspace.select_8", "Select Workspace 8", {{.Digit_8, {.Control, .Shift}}}},
	.Workspace_9 = {"workspace.select_9", "Select Workspace 9", {{.Digit_9, {.Control, .Shift}}}},
	.Command_Palette       = {
		"app.command_palette",
		"Show Command Palette",
		{{.P, {.Control, .Shift}}},
	},
	.Copy                  = {
		"edit.copy",
		"Copy",
		{{.C, {.Control, .Shift}}, {.Insert, {.Control}}},
	},
	.Paste                 = {
		"edit.paste",
		"Paste",
		{{.V, {.Control, .Shift}}, {.Insert, {.Shift}}},
	},
	.Select_All = {"edit.select_all", "Select All", {{.A, {.Control, .Shift}}}},
	.Find = {"terminal.find", "Find in Scrollback", {{.F, {.Control, .Shift}}}},
	.Clear_Scrollback      = {
		"terminal.clear_scrollback",
		"Clear Scrollback",
		{{.K, {.Control, .Shift}}},
	},
	.Scroll_Page_Up        = {
		"terminal.scroll_page_up",
		"Scroll Up One Page",
		{{.Page_Up, {.Shift}}},
	},
	.Scroll_Page_Down      = {
		"terminal.scroll_page_down",
		"Scroll Down One Page",
		{{.Page_Down, {.Shift}}},
	},
	.Font_Size_Increase = {
		"view.font_size_increase",
		"Increase Font Size",
		{{.Equal, {.Control}}, {.Numpad_Add, {.Control}}},
	},
	.Font_Size_Decrease = {
		"view.font_size_decrease",
		"Decrease Font Size",
		{{.Minus, {.Control}}, {.Numpad_Subtract, {.Control}}},
	},
	.Font_Size_Reset = {
		"view.font_size_reset",
		"Reset Font Size",
		{{.Digit_0, {.Control}}, {.Numpad_0, {.Control}}},
	},
	.Open_Settings = {"settings.open_file", "Open Settings File", nil},
	.Settings_UI = {"settings.open", "Settings", {{.Comma, {.Control}}}},
	.Rename_Tab = {"tab.rename", "Rename Tab", nil},
	.Rename_Pane = {"pane.rename", "Rename Pane", nil},
	.Change_Pane_Shell = {"pane.change_shell", "Change Pane Shell…", nil},
	.Duplicate_Tab = {"tab.duplicate", "Duplicate Tab", nil},
	.Move_Tab_Left = {"tab.move_left", "Move Tab Left", nil},
	.Move_Tab_Right = {"tab.move_right", "Move Tab Right", nil},
	.Move_Tab_Start = {"tab.move_start", "Move Selected Tabs to Start", nil},
	.Move_Tab_End = {"tab.move_end", "Move Selected Tabs to End", nil},
	.Close_Other_Tabs = {"tab.close_others", "Close Other Tabs", nil},
	.Close_Right_Tabs = {"tab.close_right", "Close Tabs to the Right", nil},
	.Tab_Settings = {"tab.settings", "Tab Settings", nil},
	.Reload_Settings       = {
		"settings.reload",
		"Reload Settings",
		{{.Comma, {.Control, .Shift}}},
	},
	.Restart_Shell = {"terminal.restart_shell", "Restart Shell", nil},
	.Hide_To_Tray = {"app.hide_to_tray", "Hide to Tray", nil},
	.Quit = {"app.quit", "Quit AIODev", {{.Q, {.Control, .Shift}}}},
	.New_Tab = {"tab.new", "New Tab", {{.T, {.Control, .Shift}}}},
	.Close_Pane = {"pane.close", "Close Pane", nil},
	.Next_Tab              = {
		"tab.next",
		"Next Tab",
		{{.Tab, {.Control}}, {.Arrow_Right, {.Control, .Shift}}, {.Page_Down, {.Control}}},
	},
	.Previous_Tab          = {
		"tab.previous",
		"Previous Tab",
		{{.Tab, {.Control, .Shift}}, {.Arrow_Left, {.Control, .Shift}}, {.Page_Up, {.Control}}},
	},
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
	.Focus_Right           = {
		"pane.focus_right",
		"Focus Right",
		{{.Arrow_Right, {.Control, .Alt}}},
	},
	.Focus_Up = {"pane.focus_up", "Focus Up", {{.Arrow_Up, {.Control, .Alt}}}},
	.Focus_Down = {"pane.focus_down", "Focus Down", {{.Arrow_Down, {.Control, .Alt}}}},
	.Resize_Left           = {
		"pane.resize_left",
		"Resize Left",
		{{.Arrow_Left, {.Control, .Super, .Shift}}},
	},
	.Resize_Right          = {
		"pane.resize_right",
		"Resize Right",
		{{.Arrow_Right, {.Control, .Super, .Shift}}},
	},
	.Resize_Up             = {
		"pane.resize_up",
		"Resize Up",
		{{.Arrow_Up, {.Control, .Super, .Shift}}},
	},
	.Resize_Down           = {
		"pane.resize_down",
		"Resize Down",
		{{.Arrow_Down, {.Control, .Super, .Shift}}},
	},
	.Focus_Previous        = {
		"pane.focus_previous",
		"Focus Previous Pane",
		{{.Bracket_Left, {.Control, .Super}}},
	},
	.Focus_Next            = {
		"pane.focus_next",
		"Focus Next Pane",
		{{.Bracket_Right, {.Control, .Super}}},
	},
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
	.Customize_Colors = {"settings.customize_colors", "Customize Colors…", nil},
	.Profile_1 = {
		"profile.open_1",
		"New Tab with Profile 1",
		nil,
	},
	.Profile_2 = {
		"profile.open_2",
		"New Tab with Profile 2",
		nil,
	},
	.Profile_3 = {
		"profile.open_3",
		"New Tab with Profile 3",
		nil,
	},
	.Profile_4 = {
		"profile.open_4",
		"New Tab with Profile 4",
		nil,
	},
	.Profile_5 = {
		"profile.open_5",
		"New Tab with Profile 5",
		nil,
	},
	.Profile_6 = {
		"profile.open_6",
		"New Tab with Profile 6",
		nil,
	},
	.Profile_7 = {
		"profile.open_7",
		"New Tab with Profile 7",
		nil,
	},
	.Profile_8 = {
		"profile.open_8",
		"New Tab with Profile 8",
		nil,
	},
	.Profile_9 = {
		"profile.open_9",
		"New Tab with Profile 9",
		nil,
	},
	.Palette_Tabs = {"app.palette_tabs", "Show Palette: Tabs", nil},
	.Palette_Workspaces = {"app.palette_workspaces", "Show Palette: Workspaces", nil},
	.Palette_Settings = {"app.palette_settings", "Show Palette: Settings", nil},
	.Palette_Commands = {"app.palette_commands", "Show Palette: Commands", nil},
	.Toggle_Tabs_Rail = {
		"view.tabs_rail",
		"Show or Hide the Tab Rail",
		{{.B, {.Control, .Shift}}},
	},
	.Toggle_Tabs_Orientation = {
		"view.tabs_orientation",
		"Switch Between Vertical and Horizontal Tabs",
		{{.L, {.Control, .Shift}}},
	},
	.Status_Next = {"status.next", "Go to the Next Program That Needs You", {{.J, {.Control, .Shift}}}},
	.Status_Inbox = {"status.inbox", "Show the Program Status Inbox", {{.I, {.Control, .Shift}}}},
	.Status_Panel = {"status.panel", "Show or Hide the Activity Panel", {{.Y, {.Control, .Shift}}}},
	.Status_Board = {"status.board", "Show the Program Status Board", {{.G, {.Control, .Shift}}}},
	.Status_Dismiss_Finished = {"status.dismiss_finished", "Dismiss Finished Program Status", nil},
}

@(require_results)
register_actions :: proc(registry: ^commands.Registry) -> commands.Error {
	@(static, rodata)
	actions := ACTIONS
	for info, action in actions {
		command := commands.Command {
			id = commands.Command_Id(action),
			name = info.name,
			title = info.title,
			shortcuts = {info.shortcuts, len(info.shortcuts)},
		}
		if err := commands.register(registry, command); err != .None {return err}
	}
	return .None
}

// The mode a direct-open action selects; only the four palette actions have one.
palette_action_mode :: proc(action: Action) -> ui.Palette_Mode {
	#partial switch action {
	case .Palette_Tabs:
		return .Tabs
	case .Palette_Workspaces:
		return .Workspaces
	case .Palette_Settings:
		return .Settings
	case .Palette_Commands:
		return .Commands
	case:
		return .All
	}
}

shortcut_action :: proc(app: ^App, e: platform.Key_Event) -> (Action, bool) {
	if command := commands.find_by_key(&app.registry, e.key, e.modifiers, e.unshifted);
	   command != nil {
		return Action(command.id), true
	}
	return {}, false
}

run_action :: proc(
	app: ^App,
	w: ^Window,
	action: Action,
	split_direction: layout.Direction = .Right,
	split_ratio: f32 = 0.5,
	split_focus := true,
) {
	if (w.pane_drag.pressed || w.tab_drag.pressed) && !gesture_cancel(app, w) {return}
	entry := focused_session(app, w)
	w.dirty = true
	switch action {
	case .Show_Build_Info:
		show_build_info(app)
	case .Command_Palette:
		if palette_active(app, w) {
			palette_close(app, w)
			return
		}
		palette_open(app, w)
	case .Palette_Tabs, .Palette_Workspaces, .Palette_Settings, .Palette_Commands:
		mode := palette_action_mode(action)
		if palette_active(app, w) {
			ui.palette_set_mode(&app.palette, &app.registry, mode)
			return
		}
		palette_open_mode(app, w, mode)
	case .Copy:
		if w.find.open {
			clipboard_copy(app, ui.field_selected_text(&w.find.query))
		} else if entry != nil {
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
		if entry == nil {return}
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
		settings_reveal(app, w, {query = "keys.", search = .Scope})
	case .Reload_Settings:
		reload_settings(app)
	case .Customize_Colors:
		settings_reveal(app, w, {query = "colors.", search = .Scope})
	case .Rename_Tab:
		rename_open(app, w, true)
	case .Rename_Pane:
		rename_open(app, w, false)
	case .Change_Pane_Shell:
		for pane in w.panes {
			if pane.node != w.tree.focus || pane.content.kind != .Terminal {continue}
			profile_menu_open_pane(
				app,
				w,
				pane.node,
				pane.rect.x + 8 * w.scale,
				pane.rect.y + ui.HEADER_HEIGHT * w.scale,
			)
			break
		}
	case .Duplicate_Tab:
		tab_duplicate(app, w)
	case .Move_Tab_Left:
		tab_move(app, w, w.workspace.selected, max(0, w.workspace.selected - 1))
	case .Move_Tab_Right:
		tab_move(
			app,
			w,
			w.workspace.selected,
			min(len(w.workspace.tabs) - 1, w.workspace.selected + 1),
		)
	case .Move_Tab_Start, .Move_Tab_End:
		tab_move_group(app, w, action == .Move_Tab_End)
	case .Close_Other_Tabs, .Close_Right_Tabs:
		tab_close_subset(app, w, action == .Close_Right_Tabs)
	case .Tab_Settings:
		settings_reveal(app, w, {key = "tab.confirm_close", search = .Clear})
	case .Restart_Shell:
		if entry != nil {
			session_restart(app, entry)
		}
	case .Hide_To_Tray:
		hide_to_tray(app, w)
	case .Quit:
		app.running = false
	case .New_Tab:
		tab_new(app, w)
	case .Profile_1,
	     .Profile_2,
	     .Profile_3,
	     .Profile_4,
	     .Profile_5,
	     .Profile_6,
	     .Profile_7,
	     .Profile_8,
	     .Profile_9:
		tab_new_profile(app, w, int(action) - int(Action.Profile_1))
	case .New_Workspace:
		workspace_new(app, w, false)
	case .Change_Workspace:
		workspace_picker_open(app, w)
	case .Rename_Workspace:
		workspace_rename_open(app, w)
	case .Delete_Workspace:
		workspace_delete_request(app, w, w.workspace)
	case .Change_Workspace_Icon:
		workspace_icon_open(app, w)
	case .Workspace_1,
	     .Workspace_2,
	     .Workspace_3,
	     .Workspace_4,
	     .Workspace_5,
	     .Workspace_6,
	     .Workspace_7,
	     .Workspace_8,
	     .Workspace_9:
		workspace_select_index(app, w, int(action) - int(Action.Workspace_1))
	case .New_Window:
		workspace_new(app, w, true)
	case .Close_Pane:
		pane_close(app, w)
	case .Next_Tab:
		tab_select(app, w, (w.workspace.selected + 1) % len(w.workspace.tabs))
		rail_overlay_dismiss(app, w)
	case .Previous_Tab:
		tab_select(
			app,
			w,
			(w.workspace.selected + len(w.workspace.tabs) - 1) % len(w.workspace.tabs),
		)
		rail_overlay_dismiss(app, w)
	case .Tab_1, .Tab_2, .Tab_3, .Tab_4, .Tab_5, .Tab_6, .Tab_7, .Tab_8, .Tab_9:
		index := int(action) - int(Action.Tab_1)
		if index >= 0 && index < len(w.workspace.tabs) {
			tab_select(app, w, index)
			rail_overlay_dismiss(app, w)
		}
	case .Last_Tab:
		if len(w.workspace.tabs) > 0 {
			tab_select(app, w, len(w.workspace.tabs) - 1)
			rail_overlay_dismiss(app, w)
		}
	case .Close_Tab:
		tab_close_request(app, w, w.workspace.selected)
	case .Focus_Previous, .Focus_Next:
		pane_focus(
			app,
			w,
			layout.focus_cycle(
				pane_action_rects(app, w),
				w.tree.focus,
				action == .Focus_Next ? 1 : -1,
			),
		)
	case .Split:
		pane_split(app, w, split_direction, split_ratio, split_focus)
	case .Split_Right:
		pane_split(app, w, .Right)
	case .Split_Down:
		pane_split(app, w, .Down)
	case .Split_Left:
		pane_split(app, w, .Left)
	case .Split_Up:
		pane_split(app, w, .Up)
	case .Zoom_Pane:
		pane_zoom(app, w)
	case .Balance_Panes:
		layout.balance(w.tree)
		window_relayout(app, w)
	case .Keep_Pane_Open:
		pane_keep_open(app, w)
	case .Swap_Left, .Swap_Right, .Swap_Up, .Swap_Down, .Swap_Previous, .Swap_Next:
		rects := pane_action_rects(app, w)
		target: layout.Node_Id
		if action == .Swap_Previous || action == .Swap_Next {
			target = layout.focus_cycle(rects, w.tree.focus, action == .Swap_Next ? 1 : -1)
		} else {
			target = layout.focus_direction(
				rects,
				w.tree.focus,
				layout.Direction(int(action) - int(Action.Swap_Left)),
			)
		}
		if target != w.tree.focus {
			w.selecting, w.autoscrolling = false, false
			w.dragging = {}
			w.wheel_remainder = 0
			if layout.swap(w.tree, w.tree.focus, target) {window_relayout(app, w)}
			reset_blink(w)
		}
	case .Focus_Left, .Focus_Right, .Focus_Up, .Focus_Down:
		direction := layout.Direction(int(action) - int(Action.Focus_Left))
		pane_focus(
			app,
			w,
			layout.focus_direction(pane_action_rects(app, w), w.tree.focus, direction),
		)
	case .Resize_Left, .Resize_Right, .Resize_Up, .Resize_Down:
		resize_pane(app, w, action, 10)
	case .Resize_Left_Large, .Resize_Right_Large, .Resize_Up_Large, .Resize_Down_Large:
		resize_pane(app, w, action, 50)
	case .Toggle_Tabs_Rail:
		if !w.tabs_horizontal {rail_toggle(app, w)}
	case .Toggle_Tabs_Orientation:
		toggle_tab_orientation(app)
	case .Status_Next:
		status_next_attention(app, w)
	case .Status_Inbox:
		status_inbox_toggle(app, w)
	case .Status_Panel:
		settings_toggle_bool(app, "status.panel", &app.settings.status.panel)
	case .Status_Board:
		status_board_toggle(app, w)
	case .Status_Dismiss_Finished:
		status_dismiss_finished(app, w)
	}
}

// Moves the divider on the pressed arrow's axis by `amount` pixels toward the pressed side.
@(private)
resize_pane :: proc(app: ^App, w: ^Window, action: Action, amount: f32) {
	axis: layout.Axis
	delta: f32
	#partial switch action {
	case .Resize_Left, .Resize_Left_Large:
		axis, delta = .Horizontal, -amount
	case .Resize_Right, .Resize_Right_Large:
		axis, delta = .Horizontal, amount
	case .Resize_Up, .Resize_Up_Large:
		axis, delta = .Vertical, -amount
	case .Resize_Down, .Resize_Down_Large:
		axis, delta = .Vertical, amount
	case:
	}
	if layout.resize_pixels(w.tree, w.tree.focus, axis, delta, w.dividers[:]) {
		window_relayout(app, w)
	}
}

@(private)
pane_action_rects :: proc(app: ^App, w: ^Window) -> []layout.Pane_Rect {
	if !w.tree.zoomed {return w.panes[:]}
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
		ui.notices_put(
			&app.notices,
			u32(Notice_Key.Copy),
			.Success,
			"Copied to clipboard",
			COPY_NOTICE_DURATION,
		)
		mark_all_dirty(app)
		if explicit {term.clear_selection(entry.session)}
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
	confirmed :=
		!app.settings.terminal.confirm_multiline_paste ||
		time.tick_diff(time.tick_now(), w.paste_confirm_until) > 0
	switch term.paste(entry.session, text, confirmed) {
	case .Sent:
		paste_confirm_cancel(app, w)
	case .Unsafe:
		w.paste_confirm_until = time.tick_add(time.tick_now(), PASTE_CONFIRM_DURATION)
		ui.notices_put(
			&app.notices,
			u32(Notice_Key.Paste),
			.Warning,
			PASTE_CONFIRM_TEXT,
			PASTE_CONFIRM_DURATION,
		)
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
find_presentation :: proc(w: ^Window, entry: ^Session_Entry) -> (label: string, enabled: bool) {
	if entry == nil || len(w.find.query.bytes) == 0 { return "0 of 0", false }
	s := term.search_summary(entry.session)
	if !s.complete { return fmt.tprintf("%d of %d · Searching…", s.selected + 1, s.total), s.total > 0 }
	if s.total == 0 { return "0 of 0 · No matches", false }
	return fmt.tprintf("%d of %d", s.selected + 1, s.total), true
}

find_controls :: proc(w: ^Window, entry: ^Session_Entry) -> (l: ui.Find_Layout, enabled: bool) {
	label, available := find_presentation(w, entry)
	text := ui.text_styled(&w.ui_text, .Input)
	return ui.find_layout(f32(w.width), w.scale, ui.text_width(&text, label)), available
}

@(private)
binding_comment :: proc(info: Action_Info) -> string {
	if len(info.shortcuts) == 0 {return fmt.tprintf("keys.%s =", info.name)}
	set := commands.Shortcut_Set{info.shortcuts, len(info.shortcuts)}
	value := commands.shortcut_set_text(set, context.temp_allocator)
	return fmt.tprintf("keys.%s = %s", info.name, value)
}

@(private)
binding_comments :: proc() -> [len(Action) + 1]string {
	lines: [len(Action) + 1]string
	lines[0] =
		"Shortcuts: uncomment a line to change it. Separate several with commas; " +
		"leave the value empty to remove them."
	@(static, rodata)
	actions := ACTIONS
	for info, action in actions {
		lines[int(action) + 1] = binding_comment(info)
	}
	return lines
}

@(private)
settings_diagnostic :: proc(
	app: ^App,
	diagnostics: ^[dynamic]settings.Diagnostic,
	line: int,
	key, message: string,
	kind: settings.Diagnostic_Kind = .Invalid_Value,
) {
	if err := settings.diagnostic_append(diagnostics, line, key, message, kind); err != nil {
		log.errorf("recording shortcut diagnostic failed: %v", err)
		notify(app, .Error, message)
	}
}

@(private)
apply_bindings :: proc(app: ^App, diagnostics: ^[dynamic]settings.Diagnostic) {
	report, report_error := binding_report(&app.registry, &app.settings)
	for issue in report.issues {
		message := binding_issue_text(issue, app.settings_path)
		settings_diagnostic(app, diagnostics, issue.line, issue.key, message, issue.severity)
	}
	if report_error != nil {
		notify(app, .Error, "Could not allocate shortcut bindings.")
		return
	}
	app.leader = report.leader
}
