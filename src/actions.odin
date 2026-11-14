package main

import "aio:cli_protocol"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"
import "core:fmt"

Action :: enum u32 {
	Command_Palette,
	Copy,
	Paste,
	Select_All,
	Find,
	Clear_Scrollback,
	Scroll_Page_Up,
	Scroll_Page_Down,
	Scroll_Partial_Up,
	Scroll_Partial_Down,
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
	Fill_Window_Pane,
	Fullscreen_Pane,
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
	Open_Markdown,
	Edit_Markdown,
	Open_Markdown_Default_App,
	Duplicate_Tab,
	Move_Tab_Left,
	Move_Tab_Right,
	Move_Tab_Start,
	Move_Tab_End,
	Close_Other_Tabs,
	Close_Right_Tabs,
	Tab_Settings,
	New_Tab_Group,
	Add_Tab_To_Group,
	Remove_Tab_From_Group,
	Rename_Tab_Group,
	Tab_Group_Color,
	Fold_Tab_Group,
	Ungroup_Tabs,
	Close_Tab_Group,
	New_Tab_In_Group,
	Move_Tab_Group_Workspace,
	New_Workspace,
	Change_Workspace,
	Next_Workspace,
	Previous_Workspace,
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
	Focus_Back,
	Focus_Forward,
	Status_Inbox,
	Status_Panel,
	Status_Dismiss_Finished,
	Status_Panel_Next,
	Status_Panel_Previous,
	Move_Pane_Workspace,
	Move_Pane_New_Workspace,
	Move_Tab_Workspace,
	Move_Tab_New_Workspace,
	Pane_List,
	Pane_Status,
	Pane_Read,
	Pane_Send,
	Pane_Focus,
	App_Commands,
	Reopen_Closed,
	Linked_Window,
	Show_Links,
	Show_Commands,
	New_Floating,
	Float_Pane,
	Minimize_Floating,
	Minimize_All_Floating,
	Tab_Context_Menu,
	Restart_Pane,
	Layout_Apply,
	Tab_List,
	Workspace_List,
	App_Version,
	Install_Agent_Hooks,
	Update,
	Pane_Send_Keys,
	Pane_Process,
	App_Notify,
	Clipboard_Read,
	Clipboard_Write,
	Settings_Get,
	Settings_Set,
}

// Everything one command is: its name and title, default shortcuts, what it does when a linked window
// runs it, and how the CLI reaches it. Entries are positional, so none can be left out.
@(private)
Command_Descriptor :: struct {
	name, title: string,
	shortcuts:   []commands.Shortcut,
	route:       Pane_Link_Route,
	spec:        Command_Spec,
}

// What a command takes beyond its descriptor's identity. The zero value is an ordinary command.
@(private)
Command_Spec :: struct {
	// The arguments a control request may give, and those it must.
	accepted, required: commands.Arguments,
	// Serves the CLI and scripts only: it stays out of the palette and shortcut lists, and a key bound
	// to it does nothing.
	hidden:             bool,
	control:            Control_Form,
	param:              Action_Param,
}

// How a control request reaches a command.
@(private)
Control_Form :: enum u8 {
	// The named pane is shown and focused in its window first, and the command runs there.
	Focus,
	// The command acts on the named pane where it is, without moving focus.
	Pane,
	// The command names no pane, or resolves its own.
	Unnamed,
}

// The member of a command family a command is; its field of Action_Param holds the value.
@(private)
Action_Family :: enum u8 {
	None,
	// `direction`: Focus, Swap and Split toward a side.
	Toward,
	// `index`, from 0: Select Tab N.
	Tab,
	// `index`, from 0: Select Workspace N.
	Workspace,
	// `index`, from 0: New Tab with the Nth visible profile.
	Profile,
	// `resize`.
	Resize,
	// `mode`: the palette domain a direct-open command shows.
	Palette,
}

@(private)
Action_Param :: struct {
	family:    Action_Family,
	direction: layout.Direction,
	index:     int,
	resize:    Resize_Step,
	mode:      ui.Palette_Mode,
}

// A divider move along `axis`, by `pixels`; negative moves toward the left or the top.
@(private)
Resize_Step :: struct {
	axis:   layout.Axis,
	pixels: f32,
}

// The resize commands' steps. The large step's titles state RESIZE_LARGE_LABEL.
@(private)
RESIZE_PIXELS :: 10
@(private)
RESIZE_LARGE_PIXELS :: 50
@(private)
RESIZE_LARGE_LABEL :: "50"

@(private)
ACTIONS :: [Action]Command_Descriptor {
	.Command_Palette = {
		"app.command_palette", "Show everything palette", {{.P, {.Control, .Shift}}}, .Local, {},
	},
	.Copy = {"edit.copy", "Copy", {{.C, {.Control, .Shift}}, {.Insert, {.Control}}}, .Local, {}},
	.Paste = {"edit.paste", "Paste", {{.V, {.Control, .Shift}}, {.Insert, {.Shift}}}, .Local, {}},
	.Select_All = {"edit.select_all", "Select all", {{.A, {.Control, .Shift}}}, .Local, {}},
	.Find = {"terminal.find", "Find", {{.F, {.Control, .Shift}}}, .Local, {}},
	.Clear_Scrollback = {
		"terminal.clear_scrollback", "Clear scrollback", {{.K, {.Control, .Shift}}}, .Local, {},
	},
	.Scroll_Page_Up = {
		"terminal.scroll_page_up", "Scroll up one page", {{.Page_Up, {.Shift}}}, .Local, {},
	},
	.Scroll_Page_Down = {
		"terminal.scroll_page_down", "Scroll down one page", {{.Page_Down, {.Shift}}}, .Local, {},
	},
	.Scroll_Partial_Up = {
		"terminal.scroll_partial_up", "Scroll up configured page length", {{.Page_Up, {.Control}}},
		.Local, {},
	},
	.Scroll_Partial_Down = {
		"terminal.scroll_partial_down", "Scroll down configured page length",
		{{.Page_Down, {.Control}}}, .Local, {},
	},
	.Font_Size_Increase = {
		"view.font_size_increase", "Increase font size",
		{{.Equal, {.Control}}, {.Numpad_Add, {.Control}}}, .Local, {},
	},
	.Font_Size_Decrease = {
		"view.font_size_decrease", "Decrease font size",
		{{.Minus, {.Control}}, {.Numpad_Subtract, {.Control}}}, .Local, {},
	},
	.Font_Size_Reset = {
		"view.font_size_reset", "Reset font size",
		{{.Digit_0, {.Control}}, {.Numpad_0, {.Control}}}, .Local, {},
	},
	.Open_Settings = {"settings.open_file", "Open settings file", nil, .Local, {}},
	.Reload_Settings = {
		"settings.reload", "Reload settings", {{.Comma, {.Control, .Shift}}}, .Local, {},
	},
	.Restart_Shell = {"terminal.restart_shell", "Restart shell", nil, .Local, {}},
	.Hide_To_Tray = {"app.hide_to_tray", "Hide to tray", nil, .Host, {}},
	.Quit = {"app.quit", "Quit AIODev", {{.Q, {.Control, .Shift}}}, .Local, {}},
	.New_Tab = {
		"tab.new", "New tab", {{.T, {.Control, .Shift}}}, .Host,
		{
			accepted = {.Focus, .Directory, .Name, .Profile, .Program, .Command_File, .Tab_Name},
			control = .Pane,
		},
	},
	.Close_Pane = {"pane.close", "Close pane", nil, .Local, {control = .Pane}},
	.Next_Tab = {"tab.next", "Next tab", {{.Tab, {.Control}}}, .Host, {}},
	.Previous_Tab = {"tab.previous", "Previous tab", {{.Tab, {.Control, .Shift}}}, .Host, {}},
	.Tab_1 = {"tab.select_1", "Select tab 1", nil, .Host, {param = {family = .Tab, index = 0}}},
	.Tab_2 = {"tab.select_2", "Select tab 2", nil, .Host, {param = {family = .Tab, index = 1}}},
	.Tab_3 = {"tab.select_3", "Select tab 3", nil, .Host, {param = {family = .Tab, index = 2}}},
	.Tab_4 = {"tab.select_4", "Select tab 4", nil, .Host, {param = {family = .Tab, index = 3}}},
	.Tab_5 = {"tab.select_5", "Select tab 5", nil, .Host, {param = {family = .Tab, index = 4}}},
	.Tab_6 = {"tab.select_6", "Select tab 6", nil, .Host, {param = {family = .Tab, index = 5}}},
	.Tab_7 = {"tab.select_7", "Select tab 7", nil, .Host, {param = {family = .Tab, index = 6}}},
	.Tab_8 = {"tab.select_8", "Select tab 8", nil, .Host, {param = {family = .Tab, index = 7}}},
	.Tab_9 = {"tab.select_9", "Select tab 9", nil, .Host, {param = {family = .Tab, index = 8}}},
	.Split_Right = {
		"pane.split_right", "Split right", {{.O, {.Control, .Shift}}}, .Local,
		{param = {family = .Toward, direction = .Right}},
	},
	.Split_Down = {
		"pane.split_down", "Split down", {{.E, {.Control, .Shift}}}, .Local,
		{param = {family = .Toward, direction = .Down}},
	},
	.Focus_Left = {
		"pane.focus_left", "Focus left", {{.Arrow_Left, {.Control, .Alt}}}, .Local,
		{param = {family = .Toward, direction = .Left}},
	},
	.Focus_Right = {
		"pane.focus_right", "Focus right", {{.Arrow_Right, {.Control, .Alt}}}, .Local,
		{param = {family = .Toward, direction = .Right}},
	},
	.Focus_Up = {
		"pane.focus_up", "Focus up", {{.Arrow_Up, {.Control, .Alt}}}, .Local,
		{param = {family = .Toward, direction = .Up}},
	},
	.Focus_Down = {
		"pane.focus_down", "Focus down", {{.Arrow_Down, {.Control, .Alt}}}, .Local,
		{param = {family = .Toward, direction = .Down}},
	},
	.Resize_Left = {
		"pane.resize_left", "Resize left", {{.Arrow_Left, {.Control, .Super, .Shift}}}, .Local,
		{param = {family = .Resize, resize = {.Horizontal, -RESIZE_PIXELS}}},
	},
	.Resize_Right = {
		"pane.resize_right", "Resize right", {{.Arrow_Right, {.Control, .Super, .Shift}}}, .Local,
		{param = {family = .Resize, resize = {.Horizontal, RESIZE_PIXELS}}},
	},
	.Resize_Up = {
		"pane.resize_up", "Resize up", {{.Arrow_Up, {.Control, .Super, .Shift}}}, .Local,
		{param = {family = .Resize, resize = {.Vertical, -RESIZE_PIXELS}}},
	},
	.Resize_Down = {
		"pane.resize_down", "Resize down", {{.Arrow_Down, {.Control, .Super, .Shift}}}, .Local,
		{param = {family = .Resize, resize = {.Vertical, RESIZE_PIXELS}}},
	},
	.Focus_Previous = {
		"pane.focus_previous", "Previous pane", {{.Bracket_Left, {.Control, .Super}}}, .Local, {},
	},
	.Focus_Next = {
		"pane.focus_next", "Next pane", {{.Bracket_Right, {.Control, .Super}}}, .Local, {},
	},
	.Last_Tab = {"tab.last", "Select last tab", nil, .Host, {}},
	.Close_Tab = {"tab.close", "Close selected tabs", {{.W, {.Control, .Shift}}}, .Host, {}},
	.Settings_UI = {"settings.open", "Settings", {{.Comma, {.Control}}}, .Host, {}},
	.Split = {
		"pane.split", "Split pane", nil, .Local,
		{
			accepted = {.Direction, .Ratio, .Focus, .Directory, .Name, .Profile, .Program, .Command_File},
			control = .Pane,
		},
	},
	.Split_Left = {
		"pane.split_left", "Split left", nil, .Local, {param = {family = .Toward, direction = .Left}},
	},
	.Split_Up = {"pane.split_up", "Split up", nil, .Local, {param = {family = .Toward, direction = .Up}}},
	.Zoom_Pane = {"pane.zoom", "Zoom pane", nil, .Local, {}},
	.Fill_Window_Pane = {"pane.fill_window", "Fill window", {{.Enter, {.Control, .Shift}}}, .Local, {}},
	.Fullscreen_Pane = {"pane.fullscreen", "Fullscreen", {{.F11, {}}}, .Local, {}},
	.Balance_Panes = {"pane.balance", "Balance all splits", nil, .Local, {}},
	.Swap_Left = {
		"pane.swap_left", "Swap pane left", nil, .Local, {param = {family = .Toward, direction = .Left}},
	},
	.Swap_Right = {
		"pane.swap_right", "Swap pane right", nil, .Local,
		{param = {family = .Toward, direction = .Right}},
	},
	.Swap_Up = {"pane.swap_up", "Swap pane up", nil, .Local, {param = {family = .Toward, direction = .Up}}},
	.Swap_Down = {
		"pane.swap_down", "Swap pane down", nil, .Local, {param = {family = .Toward, direction = .Down}},
	},
	.Swap_Previous = {"pane.swap_previous", "Swap with previous pane", nil, .Local, {}},
	.Swap_Next = {"pane.swap_next", "Swap with next pane", nil, .Local, {}},
	.Resize_Left_Large = {
		"pane.resize_left_large", "Resize left by " + RESIZE_LARGE_LABEL + " pixels", nil, .Local,
		{param = {family = .Resize, resize = {.Horizontal, -RESIZE_LARGE_PIXELS}}},
	},
	.Resize_Right_Large = {
		"pane.resize_right_large", "Resize right by " + RESIZE_LARGE_LABEL + " pixels", nil, .Local,
		{param = {family = .Resize, resize = {.Horizontal, RESIZE_LARGE_PIXELS}}},
	},
	.Resize_Up_Large = {
		"pane.resize_up_large", "Resize up by " + RESIZE_LARGE_LABEL + " pixels", nil, .Local,
		{param = {family = .Resize, resize = {.Vertical, -RESIZE_LARGE_PIXELS}}},
	},
	.Resize_Down_Large = {
		"pane.resize_down_large", "Resize down by " + RESIZE_LARGE_LABEL + " pixels", nil, .Local,
		{param = {family = .Resize, resize = {.Vertical, RESIZE_LARGE_PIXELS}}},
	},
	.Keep_Pane_Open = {"pane.keep_open", "Toggle keep pane open after exit", nil, .Local, {}},
	.Change_Shortcut = {"settings.change_shortcut", "Change shortcut…", nil, .Host, {}},
	.Customize_Colors = {"settings.customize_colors", "Customize colors…", nil, .Host, {}},
	.Rename_Tab = {"tab.rename", "Rename tab…", nil, .Host, {accepted = {.Text}, control = .Pane}},
	.Rename_Pane = {"pane.rename", "Rename pane…", nil, .Local, {accepted = {.Text}, control = .Pane}},
	.Change_Pane_Shell = {"pane.change_shell", "Change pane shell…", nil, .Local, {}},
	.Open_Markdown = {
		"pane.open_markdown", "Open Markdown file…", nil, .Host,
		{accepted = {.File, .Direction, .Ratio, .Focus}, control = .Pane},
	},
	.Edit_Markdown = {"pane.edit_markdown", "Toggle Markdown editing", nil, .Local, {}},
	.Open_Markdown_Default_App = {
		"pane.open_markdown_default_app", "Open Markdown in default app", nil, .Local, {},
	},
	.Duplicate_Tab = {"tab.duplicate", "Duplicate tab", nil, .Host, {}},
	.Move_Tab_Left = {"tab.move_left", "Move tab left", nil, .Host, {}},
	.Move_Tab_Right = {"tab.move_right", "Move tab right", nil, .Host, {}},
	.Move_Tab_Start = {"tab.move_start", "Move selected tabs to start", nil, .Host, {}},
	.Move_Tab_End = {"tab.move_end", "Move selected tabs to end", nil, .Host, {}},
	.Close_Other_Tabs = {"tab.close_others", "Close other tabs", nil, .Host, {}},
	.Close_Right_Tabs = {"tab.close_right", "Close tabs to the right", nil, .Host, {}},
	.Tab_Settings = {"tab.settings", "Tab settings", nil, .Host, {}},
	.New_Tab_Group = {"tab.group_new", "Add tab to new group", nil, .Host, {accepted = {.Text}}},
	.Add_Tab_To_Group = {
		"tab.group_add", "Add tab to group", nil, .Host, {accepted = {.Text}, required = {.Text}, hidden = true},
	},
	.Remove_Tab_From_Group = {"tab.group_remove", "Remove tab from group", nil, .Host, {}},
	.Rename_Tab_Group = {"tab.group_rename", "Rename tab group…", nil, .Host, {accepted = {.Text}}},
	.Tab_Group_Color = {
		"tab.group_color", "Change tab group color", nil, .Host,
		{accepted = {.Text}, required = {.Text}, hidden = true},
	},
	.Fold_Tab_Group = {"tab.group_fold", "Fold or unfold tab group", nil, .Host, {}},
	.Ungroup_Tabs = {"tab.group_ungroup", "Ungroup tabs", nil, .Host, {}},
	.Close_Tab_Group = {"tab.group_close", "Close tab group", nil, .Host, {}},
	.New_Tab_In_Group = {"tab.group_new_tab", "New tab in group", nil, .Host, {}},
	.Move_Tab_Group_Workspace = {
		"tab.group_move_workspace", "Move tab group to workspace…", nil, .Host, {accepted = {.Workspace}},
	},
	.New_Workspace = {
		"workspace.new", "New workspace", nil, .Host,
		{accepted = {.Focus, .Directory, .Name, .Profile, .Program, .Command_File}, control = .Pane},
	},
	.Change_Workspace = {"workspace.change", "Change workspace…", nil, .Host, {accepted = {.Workspace}}},
	.Next_Workspace = {"workspace.next", "Next workspace", nil, .Host, {}},
	.Previous_Workspace = {"workspace.previous", "Previous workspace", nil, .Host, {}},
	.Rename_Workspace = {
		"workspace.rename", "Rename workspace…", nil, .Host, {accepted = {.Text, .Workspace}, control = .Pane},
	},
	.New_Window = {"window.new", "New window", {{.N, {.Control, .Shift}}}, .Host, {}},
	.Delete_Workspace = {"workspace.delete", "Delete workspace…", nil, .Host, {}},
	.Change_Workspace_Icon = {"workspace.change_icon", "Change workspace icon…", nil, .Host, {}},
	.Workspace_1 = {
		"workspace.select_1", "Select workspace 1", {{.Digit_1, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 0}},
	},
	.Workspace_2 = {
		"workspace.select_2", "Select workspace 2", {{.Digit_2, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 1}},
	},
	.Workspace_3 = {
		"workspace.select_3", "Select workspace 3", {{.Digit_3, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 2}},
	},
	.Workspace_4 = {
		"workspace.select_4", "Select workspace 4", {{.Digit_4, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 3}},
	},
	.Workspace_5 = {
		"workspace.select_5", "Select workspace 5", {{.Digit_5, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 4}},
	},
	.Workspace_6 = {
		"workspace.select_6", "Select workspace 6", {{.Digit_6, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 5}},
	},
	.Workspace_7 = {
		"workspace.select_7", "Select workspace 7", {{.Digit_7, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 6}},
	},
	.Workspace_8 = {
		"workspace.select_8", "Select workspace 8", {{.Digit_8, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 7}},
	},
	.Workspace_9 = {
		"workspace.select_9", "Select workspace 9", {{.Digit_9, {.Control, .Shift}}}, .Host,
		{param = {family = .Workspace, index = 8}},
	},
	.Show_Build_Info = {"app.build_info", "Show build info", nil, .Local, {}},
	.Profile_1 = {
		"profile.open_1", "New tab with profile 1", nil, .Host, {param = {family = .Profile, index = 0}},
	},
	.Profile_2 = {
		"profile.open_2", "New tab with profile 2", nil, .Host, {param = {family = .Profile, index = 1}},
	},
	.Profile_3 = {
		"profile.open_3", "New tab with profile 3", nil, .Host, {param = {family = .Profile, index = 2}},
	},
	.Profile_4 = {
		"profile.open_4", "New tab with profile 4", nil, .Host, {param = {family = .Profile, index = 3}},
	},
	.Profile_5 = {
		"profile.open_5", "New tab with profile 5", nil, .Host, {param = {family = .Profile, index = 4}},
	},
	.Profile_6 = {
		"profile.open_6", "New tab with profile 6", nil, .Host, {param = {family = .Profile, index = 5}},
	},
	.Profile_7 = {
		"profile.open_7", "New tab with profile 7", nil, .Host, {param = {family = .Profile, index = 6}},
	},
	.Profile_8 = {
		"profile.open_8", "New tab with profile 8", nil, .Host, {param = {family = .Profile, index = 7}},
	},
	.Profile_9 = {
		"profile.open_9", "New tab with profile 9", nil, .Host, {param = {family = .Profile, index = 8}},
	},
	.Palette_Tabs = {
		"app.palette_tabs", "Show palette: tabs", nil, .Local, {param = {family = .Palette, mode = .Tabs}},
	},
	.Palette_Workspaces = {
		"app.palette_workspaces", "Show palette: workspaces", nil, .Local,
		{param = {family = .Palette, mode = .Workspaces}},
	},
	.Palette_Settings = {
		"app.palette_settings", "Show palette: settings", nil, .Local,
		{param = {family = .Palette, mode = .Settings}},
	},
	.Palette_Commands = {
		"app.palette_commands", "Show palette: commands", nil, .Local,
		{param = {family = .Palette, mode = .Commands}},
	},
	.Toggle_Tabs_Rail = {
		"view.tabs_rail", "Show or hide the tab rail", {{.B, {.Control, .Shift}}}, .Host, {},
	},
	.Toggle_Tabs_Orientation = {
		"view.tabs_orientation", "Switch between vertical and horizontal tabs",
		{{.L, {.Control, .Shift}}}, .Host, {},
	},
	.Status_Next = {
		"status.next", "Next program that needs you", {{.J, {.Control, .Shift}}}, .Host, {},
	},
	.Focus_Back = {
		"pane.focus_back", "Back in pane history", {{.Bracket_Left, {.Control, .Shift}}},
		.Host, {},
	},
	.Focus_Forward = {
		"pane.focus_forward", "Forward in pane history", {{.Bracket_Right, {.Control, .Shift}}},
		.Host, {},
	},
	.Status_Inbox = {
		"status.inbox", "Show the Activity inbox", {{.I, {.Control, .Shift}}}, .Host, {},
	},
	.Status_Panel = {
		"status.panel", "Show or hide the Activity panel", {{.Y, {.Control, .Shift}}}, .Host, {},
	},
	.Status_Dismiss_Finished = {
		"status.dismiss_finished", "Dismiss finished Activity items", nil, .Host, {},
	},
	.Status_Panel_Next = {
		"status.panel_next", "Next Activity item", nil, .Host, {},
	},
	.Status_Panel_Previous = {
		"status.panel_previous", "Previous Activity item", nil, .Host, {},
	},
	.Move_Pane_Workspace = {
		"pane.move_workspace", "Move pane to workspace…", nil, .Refuse, {accepted = {.Workspace}},
	},
	.Move_Pane_New_Workspace = {
		"pane.move_new_workspace", "Move pane to new workspace", nil, .Refuse, {},
	},
	.Move_Tab_Workspace = {
		"tab.move_workspace", "Move tab to workspace…", nil, .Host, {accepted = {.Workspace}},
	},
	.Move_Tab_New_Workspace = {"tab.move_new_workspace", "Move tab to new workspace", nil, .Host, {}},
	.Pane_List = {"pane.list", "List panes", nil, .Host, {hidden = true, control = .Unnamed}},
	.Pane_Status = {
		cli_protocol.PANE_STATUS_COMMAND, "Show pane status", nil, .Host, {hidden = true, control = .Unnamed},
	},
	.Pane_Read = {
		cli_protocol.PANE_READ_COMMAND, "Read pane screen", nil, .Host,
		{accepted = {.Lines, .Scrollback, .Unwrap}, hidden = true, control = .Pane},
	},
	.Pane_Send = {
		"pane.send", "Send text to pane", nil, .Host,
		{accepted = {.Text, .Enter, .Text_File}, required = {.Text}, hidden = true, control = .Pane},
	},
	.Pane_Focus = {"pane.focus", "Focus pane", nil, .Host, {hidden = true, control = .Pane}},
	.App_Commands = {
		cli_protocol.CATALOGUE_COMMAND, "List commands", nil, .Host,
		{accepted = {.Text}, hidden = true, control = .Unnamed},
	},
	.Reopen_Closed = {
		"pane.reopen_closed", "Reopen closed pane or tab", {{.R, {.Control, .Shift}}}, .Host, {},
	},
	.Linked_Window = {"pane.linked_window", "Toggle pane in linked window", nil, .Local, {}},
	.Show_Links = {"pane.links", "Show links", nil, .Local, {}},
	.Show_Commands = {"pane.commands", "Show saved commands", nil, .Local, {}},
	.New_Floating = {
		"pane.new_floating", "New shell float", {{.Backquote, {.Control, .Shift}}}, .Host,
		{accepted = {.Focus, .Directory, .Name, .Profile, .Program, .Command_File}, control = .Pane},
	},
	.Float_Pane = {"pane.float", "Float or dock pane", {{.Enter, {.Control, .Alt}}}, .Refuse, {}},
	.Minimize_Floating = {
		"pane.minimize_floating", "Minimize or restore float", {{.M, {.Control, .Shift}}}, .Host,
		{control = .Pane},
	},
	.Minimize_All_Floating = {
		"pane.minimize_all_floating", "Minimize or restore all floats", nil, .Host, {},
	},
	.Tab_Context_Menu = {
		"tab.context_menu", "Show tab menu", {{.Context_Menu, {}}, {.F10, {.Shift}}}, .Host, {},
	},
	.Restart_Pane = {
		"pane.restart", "Restart stopped pane", {{.Enter, {}}, {.Numpad_Enter, {}}}, .Local, {},
	},
	.Layout_Apply = {
		"layout.apply", "Apply layout file", nil, .Host,
		{accepted = {.File, .Focus}, required = {.File}, hidden = true, control = .Pane},
	},
	.Tab_List = {"tab.list", "List tabs", nil, .Host, {hidden = true, control = .Unnamed}},
	.Workspace_List = {"workspace.list", "List workspaces", nil, .Host, {hidden = true, control = .Unnamed}},
	.App_Version = {
		cli_protocol.VERSION_COMMAND, "Show AIODev's build", nil, .Host, {hidden = true, control = .Unnamed},
	},
	.Install_Agent_Hooks = {"app.install_agent_hooks", "Install agent session hooks", nil, .Local, {}},
	.Update = {"app.update", "Update AIODev", nil, .Local, {}},
	.Pane_Send_Keys = {
		"pane.send_keys", "Send keys to pane", nil, .Host,
		{accepted = {.Keys}, required = {.Keys}, hidden = true, control = .Pane},
	},
	.Pane_Process = {
		"pane.process", "Show pane process", nil, .Host, {hidden = true, control = .Pane},
	},
	.App_Notify = {
		"app.notify", "Show notification", nil, .Host,
		{accepted = {.Title, .Text}, required = {.Text}, hidden = true, control = .Unnamed},
	},
	.Clipboard_Read = {
		"edit.clipboard_read", "Read clipboard", nil, .Host, {hidden = true, control = .Unnamed},
	},
	.Clipboard_Write = {
		"edit.clipboard_write", "Write clipboard", nil, .Host,
		{accepted = {.Text}, required = {.Text}, hidden = true, control = .Unnamed},
	},
	.Settings_Get = {
		"settings.get", "Read setting", nil, .Host,
		{accepted = {.Name}, required = {.Name}, hidden = true, control = .Unnamed},
	},
	.Settings_Set = {
		"settings.set", "Write setting", nil, .Host,
		{accepted = {.Name, .Text}, required = {.Name, .Text}, hidden = true, control = .Unnamed},
	},
}

// What help says about a command beyond its usage and title: a summary, and the command's own help for
// arguments whose shared wording does not fit it.
@(private)
Command_Help :: struct {
	summary: string,
	notes:   []commands.Argument_Note,
}

@(private)
COMMAND_HELP :: #partial [Action]Command_Help {
	.New_Tab = {
		"Opens a tab in the pane's workspace running the profile's shell or a program and prints the new " +
		"pane's id; focus stays where it is unless --focus.",
		nil,
	},
	.Split = {
		"Splits the pane, runs the profile's shell or a program in the new pane and prints its id; focus " +
		"stays where it is unless --focus.",
		nil,
	},
	.New_Floating = {
		"Opens a shell or program floating above the pane's tab and prints its id; focus stays where it " +
		"is unless --focus.",
		nil,
	},
	.New_Workspace = {
		"Creates a workspace in the background whose tab runs the profile's shell or a program and prints " +
		"the new pane's id; --focus shows it in the pane's window.",
		{
			{.Name, {"names the new workspace", "a generated name", "--name Agents"}},
			{.Focus, {"shows the new workspace in the pane's window", "off (it stays in the background)", ""}},
		},
	},
	.Layout_Apply = {
		"Opens a tab of named panes from a JSON layout file in the pane's workspace and prints their ids " +
		"column by column, top to bottom; nothing opens when the file is wrong.",
		{
			{
				.File,
				{
					"the JSON layout: tab, cwd and columns of panes with name, command (an argument " +
					"array), cwd and profile; at most 1 MiB and 16 panes; a relative path is from aio's " +
					"working directory",
					"none (required)",
					"review.json",
				},
			},
			{.Focus, {description = "shows the new tab and focuses its first pane"}},
		},
	},
	.Open_Markdown = {
		"Shows a Markdown file beside the pane and updates it when the file changes.",
		{{.Direction, {default = "right, or a float when pane.markdown_floating is on"}}},
	},
	.Edit_Markdown = {
		"Edits the focused Markdown pane's file in place, every line but the caret's shown rendered; edits " +
		"save a moment after typing stops. Run again to read it.",
		nil,
	},
	.Open_Markdown_Default_App = {
		"Opens the focused Markdown pane's file in the program Windows opens Markdown files with.",
		nil,
	},
	.Pane_Send = {
		"Types text into the pane's program as a person at the keyboard would.",
		{{.Text, {description = "the text to type", example = `"git status"`}}},
	},
	.Pane_Send_Keys = {
		"Sends each chord through the pane's negotiated keyboard protocol. Invalid chords send nothing.",
		nil,
	},
	.Pane_Process = {
		"Reports the pane's current program, its executable path and directory when available, and its " +
		"ancestors from nearest parent back to the pane's shell.",
		nil,
	},
	.App_Notify = {
		"Shows an Info notice; with no visible window, also uses the notification preferences for done programs.",
		nil,
	},
	.Clipboard_Read = {"Returns the clipboard's text.", nil},
	.Clipboard_Write = {"Replaces the clipboard's text; empty text clears it.", nil},
	.Settings_Get = {
		"Returns a current schema setting in its settings.ini form, including quotes around strings.",
		{{.Name, {"the schema setting's key", "none (required)", "--name font.size"}}},
	},
	.Settings_Set = {
		"Validates, saves and applies a setting exactly as the Settings page does. String values are " +
		"given without settings.ini's surrounding quotes.",
		{{.Name, {"the schema setting's key", "none (required)", "--name font.size"}}},
	},
	.Pane_Read = {
		"Prints the pane's visible text; --scrollback adds the history above it and --unwrap joins rows the " +
		"terminal wrapped.",
		nil,
	},
	.Pane_List = {
		"Prints a header row, then a tab-separated line per pane: id, focused, workspace, tab, status, " +
		"process, title, directory, pid, tab name and grid; empty fields print as -; --json adds each " +
		"pane's rect.",
		nil,
	},
	.Pane_Status = {
		"Prints the pane's line as pane.list does, without the header; a recently closed pane reports how " +
		"it ended.",
		nil,
	},
	.Tab_List = {"Prints a header row, then a line per tab in every workspace.", nil},
	.Workspace_List = {
		"Prints a header row, then a line per workspace with its window state, tab count and focus.",
		nil,
	},
	.App_Version = {"Prints AIODev's build; aio version shows it beside aio's own.", nil},
	.Pane_Focus = {"Focuses the pane and brings its window forward.", nil},
	.Rename_Pane = {
		"Names the pane; without text it opens the rename box on the pane.",
		{
			{
				.Text,
				{
					"the pane's new name (an empty name returns it to its program's title)",
					"none (opens the rename box)",
					"build",
				},
			},
		},
	},
	.Rename_Tab = {
		"Names the pane's tab; without text it opens the rename box.",
		{
			{
				.Text,
				{
					"the tab's new name (an empty name returns it to its pane's title)",
					"none (opens the rename box)",
					"Build",
				},
			},
		},
	},
	.Rename_Workspace = {
		"Renames the pane's workspace, or the one --workspace names; without a name it opens the pane's " +
		"workspace's name field, so --workspace needs a name.",
		{
			{.Text, {"the workspace's new name", "none (opens the name field; required with --workspace)", "Agents"}},
			{.Workspace, {default = "the pane's workspace"}},
		},
	},
	.Change_Workspace = {"Shows the workspace --workspace names in the pane's window.", nil},
	.Move_Pane_Workspace = {"Moves the pane to the workspace --workspace names.", nil},
	.Move_Tab_Workspace = {"Moves the pane's tab to the workspace --workspace names.", nil},
	.App_Commands = {
		"Lists every command, or describes one; aio commands and aio help ask it.",
		{{.Text, {"a command to describe", "none (lists every command)", "pane.split"}}},
	},
}

@(require_results)
register_actions :: proc(registry: ^commands.Registry) -> commands.Error {
	@(static, rodata)
	descriptors := ACTIONS
	@(static, rodata)
	help := COMMAND_HELP
	for descriptor, action in descriptors {
		command := commands.Command {
			id        = commands.Command_Id(action),
			name      = descriptor.name,
			title     = descriptor.title,
			shortcuts = {descriptor.shortcuts, len(descriptor.shortcuts)},
			arguments = descriptor.spec.accepted,
			required  = descriptor.spec.required,
			hidden    = descriptor.spec.hidden,
			summary   = help[action].summary,
			notes     = help[action].notes,
		}
		if err := commands.register(registry, command); err != .None {return err}
	}
	registry.builtin_count = len(registry.items)
	return .None
}

// The New Tab with Profile N command that opens visible profile `index`, if one does.
@(require_results)
profile_action :: proc(index: int) -> (Action, bool) {
	@(static, rodata)
	descriptors := ACTIONS
	for descriptor, action in descriptors {
		param := descriptor.spec.param
		if param.family == .Profile && param.index == index {return action, true}
	}
	return {}, false
}

// The label of the first shortcut that runs `action` now, written to out (SHORTCUT_TEXT_CAP bytes);
// empty when none does. Menus and hints show this rather than a default that rebinding can change.
@(require_results)
action_shortcut_text :: proc(app: ^App, action: Action, out: []u8) -> string {
	return commands.active_shortcut_text(commands.find(&app.registry, commands.Command_Id(action)), out)
}

shortcut_action :: proc(app: ^App, e: input.Key_Event) -> (Action, bool) {
	if command := commands.find_by_key(&app.registry, e.key, e.modifiers, e.unshifted);
	   command != nil {
		return action_builtin(command.id)
	}
	return {}, false
}

// Built-in ids are the descriptor indices; runtime ids must never index the Action tables.
@(require_results)
action_builtin :: proc(id: commands.Command_Id) -> (Action, bool) {
	if u64(id) >= u64(len(ACTIONS)) {return {}, false}
	return Action(id), true
}

Command_Origin :: enum u8 {
	Key, Palette, Menu, Button, Cli, Script, Config,
}

// The wire spelling of each origin, as `--origin` takes it.
COMMAND_ORIGIN_WORDS :: [Command_Origin]string {
	.Key     = "key",
	.Palette = "palette",
	.Menu    = "menu",
	.Button  = "button",
	.Cli     = "cli",
	.Script  = "script",
	.Config  = "config",
}

// A window's own keys, palette, menus and buttons act on its focus. Tab commands act on `tab`, or the
// selected tab when none is named; a tab menu names the tab it opened on.
Window_Context :: struct {
	window: ^Window,
	tab:    Maybe(int),
	origin: Command_Origin,
}

// A control request names its pane in the invocation; empty means `caller`, the pane the request came
// from (D-046). Pipe requests carry origin .Cli unless they name another.
Control_Request :: struct {
	caller: u32,
	origin: Command_Origin,
}

// Who runs a command, which decides what it acts on.
Command_Context :: union #no_nil {
	Window_Context,
	Control_Request,
}

// Runs `action` as a person at w would, on its focus and selected tab. Failures show as notices.
run_action :: proc(app: ^App, w: ^Window, action: Action, origin := Command_Origin.Key) {
	run_window_command(app, w, commands.Command_Id(action), origin)
}

@(private)
run_window_command :: proc(app: ^App, w: ^Window, id: commands.Command_Id, origin: Command_Origin) {
	invocation := commands.invocation(id, focus = true)
	_ = command_execute(app, Window_Context{window = w, origin = origin}, invocation)
}

// The window that runs a command w was asked to run, or nil when it must not run: a held drag that
// cannot be cancelled keeps it, and a linked window passes tab and workspace commands to the window
// showing its tab and refuses ones that would take its pane out of that tab.
@(private)
command_window :: proc(app: ^App, w: ^Window, action: Action) -> ^Window {
	@(static, rodata)
	descriptors := ACTIONS
	if drag_held(w) && !gesture_cancel(app, w) {return nil}
	if window_linked(w) {
		switch descriptors[action].route {
		case .Local:
			pane_link_reconcile(app, w)
		case .Host:
			host := pane_link_acting_window(app, w)
			return host != w ? command_window(app, host, action) : nil
		case .Refuse:
			notify(app, .Info, "Return this pane to its tab first.")
			return nil
		}
	}
	w.dirty = true
	return w
}

// Availability is command policy; each surface decides how an unavailable action is presented, and a key
// bound to one goes on to the focused pane. Copy needs something to copy: the find query's keyboard, or a
// selection in the focused terminal or document. Restart Stopped Pane needs a focused session that is not
// running, and leaves Enter to a find bar that has the keyboard.
action_available :: proc(app: ^App, w: ^Window, action: Action) -> bool {
	#partial switch action {
	case .Copy:
		if ui.find_has_keyboard(&w.find) {return true}
		if entry := focused_session(app, w); entry != nil {return term.has_selection(entry.session)}
		return markdown_selected(app, w) != ""
	case .Restart_Pane:
		if ui.find_has_keyboard(&w.find) {return false}
		entry := focused_session(app, w)
		return entry != nil && entry.status != .Running
	case .Edit_Markdown, .Open_Markdown_Default_App:
		return markdown_focused(app, w) != nil
	}
	return true
}

// Runs one command for every interface, so it behaves the same from each (WORK-038). A window context
// acts on that window's focus and reports failures as notices; its outcome carries nothing. A control
// request names its pane, which the command's Control_Form decides how to reach.
@(require_results)
command_execute :: proc(app: ^App, ctx: Command_Context, invocation: commands.Invocation) -> Outcome {
	@(static, rodata)
	descriptors := ACTIONS
	invocation := invocation
	command := commands.find(&app.registry, invocation.id)
	if command == nil {return outcome_failure(.Usage, "unknown command; use aio commands")}
	action, builtin := action_builtin(invocation.id)
	if !builtin {
		if app.runtime_runner == nil {
			return outcome_failure(.Failed, fmt.tprintf("no script defines %s", command.name))
		}
		return app.runtime_runner(app, ctx, invocation)
	}
	w: ^Window
	tab: Maybe(int)
	// The pane a control request names, for commands that act on it where it is.
	target: Maybe(Pane_Target)
	// The workspace a control request names with --workspace.
	named_workspace: ^Workspace
	switch c in ctx {
	case Window_Context:
		w = command_window(app, c.window, action)
		if w == nil || descriptors[action].spec.hidden {return {}}
		if w == c.window {tab = c.tab}
	case Control_Request:
		if commands.find(&app.registry, invocation.id) == nil {
			return outcome_failure(.Usage, "unknown command; use aio commands")
		}
		// Resolved before any pane takes focus, so a missing or ambiguous workspace changes nothing.
		if .Workspace in invocation.given {
			failure: Outcome
			named_workspace, failure = workspace_target_resolve(app, invocation.workspace)
			if named_workspace == nil {return failure}
		}
		switch descriptors[action].spec.control {
		case .Focus:
			named, failure := pane_target_resolve(app, invocation.pane, c.caller)
			if failure.status != .Ok {return failure}
			w, failure = control_focus(app, named, action)
			if w == nil {return failure}
		case .Pane:
			named, failure := pane_target_resolve(app, invocation.pane, c.caller)
			if failure.status != .Ok {return failure}
			target = named
		case .Unnamed:
		}
	}
	if failure := invocation_files_read(&invocation); failure.status != .Ok {return failure}
	param := descriptors[action].spec.param
	entry: ^Session_Entry
	tab_index := -1
	if w != nil {
		entry = focused_session(app, w)
		if w.workspace != nil {tab_index = tab.? or_else w.workspace.selected}
	}
	switch action {
	case .App_Commands:
		return command_catalogue(app, invocation.text)
	case .App_Version:
		return version_outcome()
	case .Pane_List:
		return {payload = Outcome_Panes(pane_reports(app, nil))}
	case .Tab_List:
		return {payload = Outcome_Tabs(tab_reports(app))}
	case .Workspace_List:
		return {payload = Outcome_Workspaces(workspace_reports(app))}
	case .Pane_Status:
		return control_pane_status(app, ctx.(Control_Request), invocation)
	case .Pane_Read:
		named := target.?
		return pane_read(named.pane.session, invocation)
	case .Pane_Send:
		named := target.?
		return pane_send(named.pane.session, invocation.text, invocation.enter)
	case .Pane_Send_Keys:
		named := target.?
		return control_pane_send_keys(named.pane.session, invocation.keys)
	case .Pane_Process:
		named := target.?
		return control_pane_process(app, named.pane.session)
	case .App_Notify:
		control_app_notify(app, invocation.title, invocation.text)
		return {}
	case .Clipboard_Read:
		text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
		if !ok {return outcome_failure(.Failed, "could not read the clipboard")}
		return {payload = Outcome_Text(text)}
	case .Clipboard_Write:
		if !clipboard_write(app, invocation.text) {
			return outcome_failure(.Failed, "could not write the clipboard")
		}
		return {}
	case .Settings_Get, .Settings_Set:
		return control_settings_value(app, invocation, action == .Settings_Set)
	case .Pane_Focus:
		return control_pane_focus(app, target.?)
	case .Close_Pane:
		if t, named := target.?; named {
			pane_close_at(app, t.workspace, t.pane.tab, t.pane.node)
			return {}
		}
		pane_close(app, w)
	case .New_Tab:
		if t, named := target.?; named {
			return control_tab_new(app, window_for_workspace(app, t.workspace), t.workspace, invocation)
		}
		tab_new(app, w)
	case .Split:
		if t, named := target.?; named {
			return control_split(app, window_for_workspace(app, t.workspace), t, invocation)
		}
		pane_split(app, w, invocation.direction, invocation.ratio, invocation.focus)
	case .Open_Markdown:
		if t, named := target.?; named {
			return control_markdown_open(app, window_for_workspace(app, t.workspace), t, invocation)
		}
		markdown_open_picker(app, w)
	case .Edit_Markdown:
		markdown_edit_toggle(app, w)
	case .Open_Markdown_Default_App:
		markdown_open_external(app, w)
	case .New_Floating:
		if t, named := target.?; named {
			return control_floating_new(app, window_for_workspace(app, t.workspace), t, invocation)
		}
		floating_new(app, w)
	case .Layout_Apply:
		t := target.?
		return control_layout_apply(app, window_for_workspace(app, t.workspace), t.workspace, invocation)
	case .Rename_Pane:
		if t, named := target.?; named {
			if .Text in invocation.given {return control_rename(app, t, invocation.text)}
			failure: Outcome
			w, failure = control_focus(app, t, action)
			if w == nil {return failure}
		}
		if pane := focused_session(app, w); pane != nil {rename_open(app, w, Rename_Pane_Target{pane.id})}
	case .Minimize_Floating:
		if t, named := target.?; named {
			shown, failure := control_show(app, t)
			if shown == nil {return failure}
			// Naming a minimized float restores it, as focusing it does.
			if floating, ok := layout.float_of(window_tree(shown), t.pane.node); ok && floating.minimized {
				pane_focus(app, shown, t.pane.node)
				layout_state_touch(app)
				return {}
			}
			w, failure = control_focus(app, t, action)
			if w == nil {return failure}
		}
		floating_minimize_toggle(app, w)
	case .Linked_Window:
		if tree := window_tree(w); layout.is_floating(tree, tree.focus) {
			notify(app, .Info, "Dock the float before moving its pane to a linked window.")
			return {}
		}
		pane_link_toggle(app, w)
	case .Float_Pane:
		floating_toggle(app, w)
	case .Minimize_All_Floating:
		floating_minimize_all_toggle(app, w)
	case .Show_Links:
		document_menu_open_focused(app, w)
	case .Show_Commands:
		command_menu_open_focused(app, w)
	case .Show_Build_Info:
		show_build_info(app)
	case .Install_Agent_Hooks:
		agent_hooks_install(app)
	case .Update:
		app_update_start(app)
	case .Command_Palette:
		if palette_active(app, w) {
			palette_close(app, w)
			return {}
		}
		palette_open(app, w)
	case .Palette_Tabs, .Palette_Workspaces, .Palette_Settings, .Palette_Commands:
		if palette_active(app, w) {
			ui.palette_set_mode(&app.palette, &app.registry, param.mode)
			return {}
		}
		palette_open_mode(app, w, param.mode)
	case .Copy:
		if ui.find_has_keyboard(&w.find) {
			clipboard_copy(app, ui.field_selected_text(&w.find.query))
		} else if entry != nil {
			copy_selection(app, entry, true)
		} else {
			markdown_copy(app, w)
		}
	case .Paste:
		if ui.find_has_keyboard(&w.find) {
			find_paste(app, w)
		} else if entry != nil {
			paste_clipboard(app, w, entry)
		}
	case .Select_All:
		if entry != nil {
			term.select_all(entry.session)
		} else {
			markdown_select_all(app, w)
		}
	case .Find:
		find := find_target(app, w)
		if find == nil {return {}}
		leader_cancel(w)
		pane_header_cancel(w)
		find_toggle(app, w, find)
	case .Clear_Scrollback:
		if entry != nil {
			term.clear_scrollback(entry.session)
		}
	case .Scroll_Page_Up, .Scroll_Page_Down:
		if entry != nil {
			page := max(1, int(term.geometry(entry.session).rows) - 1)
			term.scroll_viewport(entry.session, action == .Scroll_Page_Up ? -page : page)
		} else {
			markdown_page(app, w, action == .Scroll_Page_Up ? -1 : 1)
		}
	case .Scroll_Partial_Up, .Scroll_Partial_Down:
		if entry != nil {
			rows := f64(term.geometry(entry.session).rows) * app.settings.terminal.scroll_page_length
			page := max(1, int(rows + 0.5))
			term.scroll_viewport(entry.session, action == .Scroll_Partial_Up ? -page : page)
		} else {
			length := app.settings.terminal.scroll_page_length
			markdown_page(app, w, action == .Scroll_Partial_Up ? -length : length)
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
		settings_reveal(app, w, {section = .Shortcuts})
	case .Reload_Settings:
		reload_settings(app)
	case .Customize_Colors:
		settings_reveal(app, w, {section = .Colors})
	case .Rename_Tab:
		if t, named := target.?; named {
			if .Text in invocation.given {
				if !tab_name_set(app, t.workspace, t.workspace.tabs[t.pane.tab], invocation.text) {
					return outcome_failure(.Failed, "could not rename the tab")
				}
				return {}
			}
			failure: Outcome
			w, failure = control_focus(app, t, action)
			if w == nil {return failure}
			tab_index = w.workspace.selected
		}
		if tab_index >= 0 && tab_index < len(w.workspace.tabs) {
			rename_open(app, w, Rename_Tab_Target{w.workspace.id, w.workspace.tabs[tab_index].id})
		}
	case .Change_Pane_Shell:
		focus := window_tree(w).focus
		for pane in w.panes {
			if pane.node != focus || !pane_owns_session(pane.content.kind) {continue}
			profile_menu_open_pane(app, w, pane)
			break
		}
	case .Duplicate_Tab:
		tab_duplicate(app, w, tab_index)
	case .Move_Pane_Workspace, .Move_Tab_Workspace:
		whole_tab := action == .Move_Tab_Workspace
		if named_workspace != nil {
			return control_workspace_move(app, w, whole_tab, tab_index, named_workspace)
		}
		workspace_move_open(app, w, whole_tab, tab_index)
	case .Move_Pane_New_Workspace, .Move_Tab_New_Workspace:
		workspace_move_new(app, w, action == .Move_Tab_New_Workspace, tab_index)
	case .Move_Tab_Left, .Move_Tab_Right:
		tab_move_step(app, w, tab_index, action == .Move_Tab_Right ? 1 : -1)
	case .Move_Tab_Start, .Move_Tab_End:
		tab_move_marked(app, w, action == .Move_Tab_End)
	case .Close_Other_Tabs, .Close_Right_Tabs:
		tab_close_subset(app, w, action == .Close_Right_Tabs, tab_index)
	case .Close_Tab:
		tab_close_request(app, w, tab_index)
	case .New_Tab_Group, .Add_Tab_To_Group, .Remove_Tab_From_Group, .Rename_Tab_Group, .Tab_Group_Color,
	     .Fold_Tab_Group, .Ungroup_Tabs, .Close_Tab_Group, .New_Tab_In_Group, .Move_Tab_Group_Workspace:
		return tab_group_command(app, w, action, tab_index, invocation, named_workspace)
	case .Tab_Settings:
		settings_reveal(app, w, {key = "interface.confirm", search = .Clear})
	case .Restart_Shell:
		if entry != nil {
			session_restart(app, entry)
		}
	case .Restart_Pane:
		if entry != nil && entry.status != .Running {session_restart(app, entry)}
	case .Tab_Context_Menu:
		tab_menu_open_at(app, w, tab_index)
	case .Hide_To_Tray:
		hide_to_tray(app, w)
	case .Quit:
		app_quit(app)
	case .Profile_1, .Profile_2, .Profile_3, .Profile_4, .Profile_5, .Profile_6, .Profile_7, .Profile_8,
	     .Profile_9:
		tab_new_profile(app, w, param.index)
	case .New_Workspace:
		if t, named := target.?; named {
			return control_workspace_new(app, window_for_workspace(app, t.workspace), invocation)
		}
		workspace_new(app, w, false)
	case .Change_Workspace:
		if named_workspace != nil {
			if workspace_select(app, w, named_workspace) {return {}}
			return outcome_failure(.Failed, "could not show the workspace")
		}
		workspace_picker_open(app, w)
	case .Next_Workspace:
		workspace_select_step(app, w, 1)
	case .Previous_Workspace:
		workspace_select_step(app, w, -1)
	case .Rename_Workspace:
		if t, named := target.?; named {
			if .Text in invocation.given {
				subject := named_workspace != nil ? named_workspace : t.workspace
				return control_workspace_rename(app, subject, invocation.text)
			}
			if named_workspace != nil {return outcome_failure(.Usage, "supply the workspace's new name")}
			failure: Outcome
			w, failure = control_focus(app, t, action)
			if w == nil {return failure}
		}
		workspace_name_begin(app, w)
	case .Delete_Workspace:
		workspace_delete_request(app, w, w.workspace)
	case .Change_Workspace_Icon:
		workspace_icon_open(app, w)
	case .Workspace_1, .Workspace_2, .Workspace_3, .Workspace_4, .Workspace_5, .Workspace_6,
	     .Workspace_7, .Workspace_8, .Workspace_9:
		workspace_select_index(app, w, param.index)
	case .New_Window:
		workspace_new(app, w, true)
	case .Reopen_Closed:
		closed_reopen(app, w)
	case .Next_Tab:
		tab_show(app, w, tab_shown_step(w.workspace, w.workspace.selected, 1))
	case .Previous_Tab:
		tab_show(app, w, tab_shown_step(w.workspace, w.workspace.selected, -1))
	case .Tab_1, .Tab_2, .Tab_3, .Tab_4, .Tab_5, .Tab_6, .Tab_7, .Tab_8, .Tab_9:
		if param.index < len(w.workspace.tabs) {tab_show(app, w, param.index)}
	case .Last_Tab:
		if len(w.workspace.tabs) > 0 {tab_show(app, w, len(w.workspace.tabs) - 1)}
	case .Focus_Previous, .Focus_Next:
		step := action == .Focus_Next ? 1 : -1
		pane_focus(app, w, layout.focus_cycle(pane_action_rects(app, w), pane_action_focus(w), step))
	case .Split_Right, .Split_Down, .Split_Left, .Split_Up:
		pane_split(app, w, param.direction)
	case .Zoom_Pane:
		pane_view_toggle(app, w, .Toggle_Zoom)
	case .Fill_Window_Pane:
		pane_view_toggle(app, w, .Toggle_Fill)
	case .Fullscreen_Pane:
		pane_view_toggle(app, w, .Toggle_Screen)
	case .Balance_Panes:
		layout.balance(window_tree(w))
		pane_motion_arm(w, .Resize)
		window_relayout(app, w)
	case .Keep_Pane_Open:
		pane_keep_open(app, w)
	case .Swap_Left, .Swap_Right, .Swap_Up, .Swap_Down, .Swap_Previous, .Swap_Next:
		rects := pane_action_rects(app, w)
		other: layout.Node_Id
		tree := window_tree(w)
		if param.family == .Toward {
			other = layout.focus_direction(rects, tree.focus, param.direction)
		} else {
			other = layout.focus_cycle(rects, tree.focus, action == .Swap_Next ? 1 : -1)
		}
		if other != tree.focus {
			tab := selected_tab(w.workspace)
			swap := Pane_Operation{place = .Swap, source = tab, destination = tab, node = tree.focus,
				target = other, slot = layout.INVALID_NODE}
			_ = pane_rearrange(app, w, swap)
		}
	case .Focus_Left, .Focus_Right, .Focus_Up, .Focus_Down:
		pane_focus_toward(app, w, param.direction)
	case .Resize_Left, .Resize_Right, .Resize_Up, .Resize_Down, .Resize_Left_Large, .Resize_Right_Large,
	     .Resize_Up_Large, .Resize_Down_Large:
		step := param.resize
		tree := window_tree(w)
		if layout.resize_pixels(tree, tree.focus, step.axis, step.pixels, w.dividers[:]) {
			pane_motion_arm(w, .Resize)
			window_relayout(app, w)
		}
	case .Toggle_Tabs_Rail:
		// Only the vertical tabs have a rail.
		if !w.tabs_horizontal {rail_toggle(app, w)}
	case .Toggle_Tabs_Orientation:
		toggle_tab_orientation(app)
	case .Status_Next:
		status_next_attention(app, w)
	case .Focus_Back:
		focus_jump(app, w, -1)
	case .Focus_Forward:
		focus_jump(app, w, 1)
	case .Status_Inbox:
		status_inbox_toggle(app, w)
	case .Status_Panel:
		panel := app.settings.status.panel ? "false" : "true"
		// The panel slides in or out and the panes ease into the space, when the change applies at once.
		pane_motion_arm(w, .Chrome)
		settings_save_value(app, "status.panel", panel, "Could not save the setting.")
	case .Status_Dismiss_Finished:
		status_dismiss_finished(app, w)
	case .Status_Panel_Next:
		status_panel_step(app, w, 1)
	case .Status_Panel_Previous:
		status_panel_step(app, w, -1)
	}
	return {}
}

// The panes sharing the focused pane's arrangement, placed as its split places them whatever view shows:
// its floating group, or the tiled panes.
@(private)
pane_action_rects :: proc(app: ^App, w: ^Window) -> []layout.Pane_Rect {
	tree := window_tree(w)
	if !layout.is_floating(tree, tree.focus) {return pane_tiled_action_rects(app, w)}
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	g := window_geometry(app, w, w.pane_fill)
	layout.float_group_place(tree, tree.focus, g.floating, g.gap, g.header, &rects)
	return rects[:]
}

@(private)
pane_tiled_action_rects :: proc(app: ^App, w: ^Window) -> []layout.Pane_Rect {
	if !pane_view_solo(w) {return window_tiled_rects(w)}
	tree := window_tree(w)
	rects := make([dynamic]layout.Pane_Rect, context.temp_allocator)
	layout.compute(tree, window_content_area(app, w), window_gap(app, w), &rects)
	return rects[:]
}

@(private)
pane_action_focus :: proc(w: ^Window) -> layout.Node_Id {
	tree := window_tree(w)
	return layout.is_floating(tree, tree.focus) ? tree.focus : layout.focus_tiled(tree)
}
