package settings

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

Color :: [3]u8
Cursor_Style :: enum int {
	Block,
	Bar,
	Underline,
}
CURSOR_STYLE_NAME :: [Cursor_Style]string {
	.Block     = "block",
	.Bar       = "bar",
	.Underline = "underline",
}
#assert(len(Cursor_Style) == 3)
CURSOR_STYLE_NAMES :: []string {
	CURSOR_STYLE_NAME[Cursor_Style(0)],
	CURSOR_STYLE_NAME[Cursor_Style(1)],
	CURSOR_STYLE_NAME[Cursor_Style(2)],
}
Font_Settings :: struct {
	family:            string,
	show_all:          bool,
	size, line_height: f64,
}
Shell_Settings :: struct {
	default_profile:     string,
	refresh_environment: bool,
	integration:         bool,
}
Input_Settings :: struct {
	leader: string,
}
Interface_Settings :: struct {
	font_family:                      string,
	font_size, hover_lift, hover_gloss: f64,
}
Pane_Settings :: struct {
	gap, corner_radius:            int,
	show_headers:                  bool,
	markdown_floating:             bool,
	confirm_shell_switch:          bool,
	minimum_columns, minimum_rows: int,
	focus_border, unfocused_dim:   int,
}
Tab_Settings :: struct {
	confirm_close: bool,
}
Tabs_Orientation :: enum int {
	Vertical,
	Horizontal,
}
TABS_ORIENTATION_NAME :: [Tabs_Orientation]string {
	.Vertical   = "vertical",
	.Horizontal = "horizontal",
}
#assert(len(Tabs_Orientation) == 2)
TABS_ORIENTATION_NAMES :: []string {
	TABS_ORIENTATION_NAME[Tabs_Orientation(0)],
	TABS_ORIENTATION_NAME[Tabs_Orientation(1)],
}
Tabs_Settings :: struct {
	orientation:        Tabs_Orientation,
	rail_width:         int,
	program_icons:      bool,
	program_icon_files: string,
}
Status_Scope :: enum int {
	All,
	Workspace,
}
STATUS_SCOPE_NAME :: [Status_Scope]string {
	.All       = "all",
	.Workspace = "workspace",
}
#assert(len(Status_Scope) == 2)
STATUS_SCOPE_NAMES :: []string{STATUS_SCOPE_NAME[Status_Scope(0)], STATUS_SCOPE_NAME[Status_Scope(1)]}
Status_Panel_Side :: enum int {
	Right,
	Left,
}
STATUS_PANEL_SIDE_NAME :: [Status_Panel_Side]string {
	.Right = "right",
	.Left  = "left",
}
#assert(len(Status_Panel_Side) == 2)
STATUS_PANEL_SIDE_NAMES :: []string {
	STATUS_PANEL_SIDE_NAME[Status_Panel_Side(0)],
	STATUS_PANEL_SIDE_NAME[Status_Panel_Side(1)],
}
Status_Panel_View :: enum int {
	Comfy,
	Dense,
}
STATUS_PANEL_VIEW_NAME :: [Status_Panel_View]string {
	.Comfy = "comfy",
	.Dense = "dense",
}
// What Settings shows for each view.
STATUS_PANEL_VIEW_LABEL :: [Status_Panel_View]string {
	.Comfy = "Comfy",
	.Dense = "Dense",
}
#assert(len(Status_Panel_View) == 2)
STATUS_PANEL_VIEW_NAMES :: []string {
	STATUS_PANEL_VIEW_NAME[Status_Panel_View(0)],
	STATUS_PANEL_VIEW_NAME[Status_Panel_View(1)],
}
STATUS_PANEL_VIEW_LABELS :: []string {
	STATUS_PANEL_VIEW_LABEL[Status_Panel_View(0)],
	STATUS_PANEL_VIEW_LABEL[Status_Panel_View(1)],
}
Status_Keep :: enum int {
	Focus,
	Dismiss,
}
STATUS_KEEP_NAME :: [Status_Keep]string {
	.Focus   = "focus",
	.Dismiss = "dismiss",
}
#assert(len(Status_Keep) == 2)
STATUS_KEEP_NAMES :: []string{STATUS_KEEP_NAME[Status_Keep(0)], STATUS_KEEP_NAME[Status_Keep(1)]}
// How one program status reaches you. Each state chooses any combination; none means silence.
Status_Channel :: enum u8 {
	Banner,
	Tray,
	Flash,
	Sound,
	Notice,
}
Status_Channels :: bit_set[Status_Channel;u32]
// Saved names; bit i of a saved set is Status_Channel(i).
STATUS_CHANNEL_NAME :: [Status_Channel]string {
	.Banner = "banner",
	.Tray   = "tray",
	.Flash  = "flash",
	.Sound  = "sound",
	.Notice = "notice",
}
STATUS_CHANNEL_LABEL :: [Status_Channel]string {
	.Banner = "Windows banner",
	.Tray   = "Tray notification",
	.Flash  = "Flash taskbar",
	.Sound  = "Sound",
	.Notice = "In-app notice",
}
#assert(len(Status_Channel) == 5)
STATUS_CHANNEL_NAMES :: []string {
	STATUS_CHANNEL_NAME[Status_Channel(0)],
	STATUS_CHANNEL_NAME[Status_Channel(1)],
	STATUS_CHANNEL_NAME[Status_Channel(2)],
	STATUS_CHANNEL_NAME[Status_Channel(3)],
	STATUS_CHANNEL_NAME[Status_Channel(4)],
}
STATUS_CHANNEL_LABELS :: []string {
	STATUS_CHANNEL_LABEL[Status_Channel(0)],
	STATUS_CHANNEL_LABEL[Status_Channel(1)],
	STATUS_CHANNEL_LABEL[Status_Channel(2)],
	STATUS_CHANNEL_LABEL[Status_Channel(3)],
	STATUS_CHANNEL_LABEL[Status_Channel(4)],
}
// Program status (OSC 7501). Each surface and state can be turned off on its own; `enabled` turns
// the whole protocol off, so programs see the terminal as unsupported.
Status_Settings :: struct {
	notify_idle, notify_working, notify_blocked, notify_error, notify_done: Status_Channels,
	taskbar_working, taskbar_blocked, taskbar_error: bool,

	panel_side: Status_Panel_Side,
	panel_view: Status_Panel_View,
	panel_width, panel_height: int,
	enabled, tab_indicators, active_tab_indicator, pane_headers, workspace_picker: bool,
	inbox, panel, taskbar:                                                        bool,
	show_idle, show_working, show_blocked, show_done, show_error:                 bool,
	notify_focused:                                                               bool,
	scope:                                                                        Status_Scope,
	keep_finished:                                                                Status_Keep,
	ignore_apps:                                                                  string,
}
Window_Settings :: struct {
	columns, rows, padding: int,
	tray_notification:      bool,
}
// The CLI pipe exists only while `enabled` is on (D-046).
Control_Settings :: struct {
	enabled: bool,
}
Scrollback_Settings :: struct {
	lines: int,
}
Terminal_Settings :: struct {
	copy_on_select, confirm_multiline_paste: bool,
	find_keep_query, find_select_query:      bool,
	minimum_contrast:                        f64,
	scroll_page_length:                      f64,
	scrollbar:                               bool,
}
Cursor_Settings :: struct {
	style: Cursor_Style,
	blink: bool,
}
Color_Settings :: struct {
	foreground, background, cursor, cursor_text, selection_background: Color,
	selection_foreground:                                              Maybe(Color),
	search_foreground, search_background, search_selected_background:  Color,
	palette:                                                           [16]Color,
}
Settings :: struct {
	keys:            [dynamic]Key_Binding,
	font:            Font_Settings,
	shell:           Shell_Settings,
	input:           Input_Settings,
	interface:       Interface_Settings,
	process:         Process_Settings,
	window:          Window_Settings,
	scrollback:      Scrollback_Settings,
	terminal:        Terminal_Settings,
	cursor:          Cursor_Settings,
	// The active theme's terminal colors, derived from active_theme.
	colors:          Color_Settings,
	theme:           Theme_Settings,
	themes:          [dynamic]Custom_Theme,
	active_theme:    Theme,
	pane:            Pane_Settings,
	tab:             Tab_Settings,
	tabs:            Tabs_Settings,
	status:          Status_Settings,
	control:         Control_Settings,
	profiles:        Profiles,
	allocator:       runtime.Allocator,
	// The file line of each SCHEMA entry, zero when the file does not set it; read through
	// setting_line. Sized by a constant because SCHEMA's own length depends on this struct.
	lines:           [SCHEMA_CAPACITY]int,
}
SCHEMA_CAPACITY :: 128
#assert(len(SCHEMA) <= SCHEMA_CAPACITY)
// Font zoom keys keep the shell font size within this span, apart from the file's `valid` range
// and the slider's comfortable one.
FONT_SIZE_ZOOM :: Range{6, 72}
KEY_BINDING_PREFIX :: "keys."
Key_Binding :: struct {
	name, value: string,
	line:        int,
}
Kind :: enum {
	String,
	Int,
	Float,
	Bool,
	// One of `names`, stored as its index: names[i] is the saved name of enum value i.
	Enum,
	// A bit set saved as comma-separated `names`, or `none`: bit i is names[i].
	Set,
}
// Inclusive bounds. For a String they bound its length in UTF-8 bytes.
Range :: struct {
	minimum, maximum: f64,
}
// How Settings and the palette edit a setting.
Setting_Control :: enum {
	// Follows `kind`: text, integer or number slider, toggle, or a choice of `names`.
	By_Kind,
	// A chord captured from the keyboard.
	Shortcut,
	// A String chosen from the list `live_choices` names.
	Choice,
	// Edited by a group editor of its own, such as program padding groups. The palette can only
	// jump to it and offers no reset for it.
	Group,
}
// The grammar a String value must follow beyond its length.
Setting_Validator :: enum {
	None,
	Padding_Groups,
	Program_Icons,
}
// Where a Choice setting's options come from while the app runs.
Live_Choices :: enum {
	None,
	Themes,
	Shell_Fonts,
	Interface_Fonts,
}
// When the running app applies a saved value.
Apply_Timing :: enum {
	Immediate,
	New_Sessions,
}
// One setting: its storage, file form and how it is edited. Ranges are separate policies: `valid` is
// what the file accepts, `slider` the comfortable span a slider offers when narrower.
Schema_Entry :: struct {
	key, title:        string,
	kind:              Kind,
	offset:            uintptr,
	default_value:     string,
	valid:             Range,
	// Saved names of an Enum or Set and, optionally, what Settings shows for each.
	names, labels:     []string,
	// The file comment; Settings shows `page_description` instead when it is set.
	description:       string,
	page_description:  string,
	control:           Setting_Control,
	validator:         Setting_Validator,
	live_choices:      Live_Choices,
	// Zero means the slider spans `valid`.
	slider:            Range,
	// The rounding of a numeric control; zero rounds by kind.
	step:              f64,
	// Edited inside another setting's control, so it has no row or palette entry of its own.
	embedded:          bool,
	// The embedded Bool setting that widens this setting's live choices, switched in its popup.
	choice_filter:     string,
	apply_timing:      Apply_Timing,
	// A change must be checked against every command shortcut.
	affects_bindings:  bool,
}
SCHEMA :: [?]Schema_Entry {
	{
		key = "terminal.scroll_page_length",
		title = "Scroll Page Length",
		kind = .Float,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, scroll_page_length),
		default_value = "0.5",
		valid = {0.01, 1},
		description = "Fraction of the visible page used by the configured page scrolling commands.",
	},
	{
		key = "terminal.scrollbar",
		title = "Show Scrollbar",
		kind = .Bool,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, scrollbar),
		default_value = "true",
		description = "Show a scrollbar on terminal panes with scrollback.",
	},
	{
		key = "theme.name",
		title = "Theme",
		kind = .String,
		offset = offset_of(Settings, theme) + offset_of(Theme_Settings, name),
		default_value = DEFAULT_THEME_ID,
		valid = {1, 64},
		control = .Choice,
		live_choices = .Themes,
		page_description = "Theme file or custom theme. Changing any color saves a custom theme.",
		description = "Color theme ID: a file in the themes folder, such as studio-light, or a custom theme.",
	},
	{
		key = "pane.gap",
		title = "Pane Gap",
		kind = .Int,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, gap),
		default_value = "4",
		valid = {0, 24},
		description = "Space between and around pane cards in DIPs.",
	},
	{
		key = "pane.corner_radius",
		title = "Pane Corner Radius",
		kind = .Int,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, corner_radius),
		default_value = "8",
		valid = {0, 16},
		description = "Pane card corner radius in DIPs.",
	},
	{
		key = "pane.focus_border",
		title = "Focus Border Width",
		kind = .Int,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, focus_border),
		default_value = "1",
		valid = {0, 8},
		description = "Width of the focused pane's accent outline in DIPs. Zero outlines it like every other pane.",
	},
	{
		key = "pane.unfocused_dim",
		title = "Dim Unfocused Panes",
		kind = .Int,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, unfocused_dim),
		default_value = "0",
		valid = {0, 90},
		description = "How far unfocused panes fade toward their background, in percent, so only the focused " +
			"pane keeps full contrast. Zero disables dimming.",
	},
	{
		key = "pane.show_headers",
		title = "Show Pane Headers",
		kind = .Bool,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, show_headers),
		default_value = "true",
		description = "Show a header and controls on every terminal pane.",
	},
	{
		key = "pane.markdown_floating",
		title = "Open Markdown Files in a Float",
		kind = .Bool,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, markdown_floating),
		default_value = "false",
		description = "Open a Markdown file from a terminal link or Open Markdown File in a float above the tab, " +
			"so the panes already there keep their size.",
	},
	{
		key = "pane.confirm_shell_switch",
		title = "Confirm Switching Pane Shells",
		kind = .Bool,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, confirm_shell_switch),
		default_value = "true",
		description = "Ask before a running pane's shell is replaced, losing its session.",
	},
	{
		key = "pane.minimum_columns",
		title = "Minimum Pane Width",
		kind = .Int,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, minimum_columns),
		default_value = "20",
		valid = {0, 32767},
		description = "Minimum content columns for a new pane or split. Zero disables the width check; " +
			"existing panes may shrink.",
	},
	{
		key = "pane.minimum_rows",
		title = "Minimum Pane Height",
		kind = .Int,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, minimum_rows),
		default_value = "5",
		valid = {0, 32767},
		description = "Minimum content rows for a new pane or split. Zero disables the height check; existing " +
			"panes may shrink.",
	},
	{
		key = "tab.confirm_close",
		title = "Confirm Closing Split Tabs",
		kind = .Bool,
		offset = offset_of(Settings, tab) + offset_of(Tab_Settings, confirm_close),
		default_value = "true",
		description = "Ask before closing a tab that has more than one pane.",
	},
	{
		key = "tabs.orientation",
		title = "Tab Orientation",
		kind = .Enum,
		offset = offset_of(Settings, tabs) + offset_of(Tabs_Settings, orientation),
		default_value = "horizontal",
		names = TABS_ORIENTATION_NAMES,
		description = "Draw tabs in a vertical rail along the left or in a horizontal strip in the title bar. " +
			"Switch at any time with Ctrl+Shift+L.",
	},
	{
		key = "tabs.rail_width",
		title = "Vertical Tab Width",
		kind = .Int,
		offset = offset_of(Settings, tabs) + offset_of(Tabs_Settings, rail_width),
		default_value = "208",
		valid = {144, 480},
		description = "Width of the vertical tab rail in DIPs. Double-clicking its edge returns it to this width.",
	},
	{
		key = "tabs.program_icons",
		title = "Program Icons",
		kind = .Bool,
		offset = offset_of(Settings, tabs) + offset_of(Tabs_Settings, program_icons),
		default_value = "true",
		description = "Show the icon of the program running in a pane, such as Neovim, Codex or Claude Code, on " +
			"its tab and pane header.",
	},
	{
		key = PROGRAM_ICON_FILES_KEY,
		title = "Program Icon Files",
		kind = .String,
		offset = offset_of(Settings, tabs) + offset_of(Tabs_Settings, program_icon_files),
		default_value = "",
		valid = {0, 4096},
		validator = .Program_Icons,
		description = "Your own PNG icons for programs, used instead of built-in ones: " +
			PROGRAM_ICON_FILES_EXAMPLE + ".",
	},
	{
		key = "status.enabled",
		title = "Program Status",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, enabled),
		default_value = "true",
		description = "Listen for OSC 7501 program status reports from agents, builds and other long-running " +
			"programs. Off drops reports and tells programs the terminal does not support them.",
	},
	{
		key = "status.tab_indicators",
		title = "Status on Tabs",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, tab_indicators),
		default_value = "true",
		description = "Show a spinner, progress bar or symbol on tabs whose programs are working, blocked, " +
			"finished or failed.",
	},
	{
		key = "status.active_tab_indicator",
		title = "Status on the Active Tab",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, active_tab_indicator),
		default_value = "true",
		description = "Also show tab status on the tab you are looking at.",
	},
	{
		key = "status.pane_headers",
		title = "Status in Pane Headers",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, pane_headers),
		default_value = "true",
		description = "Show what a pane's program reports in its header. Needs pane headers.",
	},
	{
		key = "status.workspace_picker",
		title = "Status in Workspace Picker",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, workspace_picker),
		default_value = "true",
		description = "Summarize each workspace's program status in the workspace picker.",
	},
	{
		key = "status.inbox",
		title = "Status Inbox",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, inbox),
		default_value = "false",
		description = "Show a title-bar summary that opens a list of programs ordered by what needs you first.",
	},
	{
		key = "status.panel",
		title = "Activity Panel",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, panel),
		default_value = "true",
		description = "Show a docked list of every program reporting status.",
	},
	{
		key = "status.panel_side",
		title = "Activity Panel Side",
		kind = .Enum,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, panel_side),
		default_value = "right",
		names = STATUS_PANEL_SIDE_NAMES,
		description = "Dock Activity at the far right or far left of the workspace.",
	},
	{
		key = "status.panel_view",
		title = "Activity Panel View",
		kind = .Enum,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, panel_view),
		default_value = "comfy",
		names = STATUS_PANEL_VIEW_NAMES,
		labels = STATUS_PANEL_VIEW_LABELS,
		description = "Comfy shows each task with its message. Dense fits more programs in compact rows.",
	},
	{
		key = "status.panel_width",
		title = "Activity Panel Width",
		kind = .Int,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, panel_width),
		default_value = "300",
		valid = {144, 480},
		description = "Width of the docked activity panel in DIPs. Double-clicking its edge returns it to this " +
			"width.",
	},
	{
		key = "status.panel_height",
		title = "Activity Panel Height",
		kind = .Int,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, panel_height),
		default_value = "45",
		valid = {20, 80},
		description = "Share of the vertical tab rail the activity panel takes below the tabs, in percent. " +
			"Double-clicking its edge returns it to this height.",
	},
	{
		key = "status.taskbar",
		title = "Taskbar Progress",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, taskbar),
		default_value = "true",
		description = "Show progress, blocked and failed work on the window's taskbar button.",
	},
	{
		key = "status.show_working",
		title = "Show Working",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, show_working),
		default_value = "true",
		description = "Show programs that are working.",
	},
	{
		key = "status.show_blocked",
		title = "Show Blocked",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, show_blocked),
		default_value = "true",
		description = "Show programs waiting for permission, an answer or a sign-in.",
	},
	{
		key = "status.show_done",
		title = "Show Done",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, show_done),
		default_value = "true",
		description = "Show programs that finished work for you to look at.",
	},
	{
		key = "status.show_error",
		title = "Show Errors",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, show_error),
		default_value = "true",
		description = "Show programs that failed and stopped.",
	},
	{
		key = "status.show_idle",
		title = "Show Idle",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, show_idle),
		default_value = "false",
		description = "Show programs waiting at their own prompt.",
	},
	{
		key = "status.notify_blocked",
		title = "Notify When Blocked",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, notify_blocked),
		default_value = "banner, sound",
		names = STATUS_CHANNEL_NAMES,
		labels = STATUS_CHANNEL_LABELS,
		description = "How to notify you when a program needs you.",
	},
	{
		key = "status.notify_error",
		title = "Notify on Errors",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, notify_error),
		default_value = "banner, sound",
		names = STATUS_CHANNEL_NAMES,
		labels = STATUS_CHANNEL_LABELS,
		description = "How to notify you when a program fails.",
	},
	{
		key = "status.notify_done",
		title = "Notify When Done",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, notify_done),
		default_value = "none",
		names = STATUS_CHANNEL_NAMES,
		labels = STATUS_CHANNEL_LABELS,
		description = "How to notify you when a program finishes.",
	},
	{
		key = "status.notify_idle",
		title = "Notify When Idle",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, notify_idle),
		default_value = "none",
		names = STATUS_CHANNEL_NAMES,
		labels = STATUS_CHANNEL_LABELS,
		description = "How to notify you when a program becomes idle.",
	},
	{
		key = "status.notify_working",
		title = "Notify When Working",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, notify_working),
		default_value = "none",
		names = STATUS_CHANNEL_NAMES,
		labels = STATUS_CHANNEL_LABELS,
		description = "How to notify you when a program starts working.",
	},
	{
		key = "status.taskbar_working",
		title = "Working: Taskbar Progress",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, taskbar_working),
		default_value = "true",
		description = "Include this state in the taskbar progress indicator.",
	},
	{
		key = "status.taskbar_blocked",
		title = "Blocked: Taskbar Progress",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, taskbar_blocked),
		default_value = "true",
		description = "Include this state in the taskbar progress indicator.",
	},
	{
		key = "status.taskbar_error",
		title = "Error: Taskbar Progress",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, taskbar_error),
		default_value = "true",
		description = "Include this state in the taskbar progress indicator.",
	},
	{
		key = "status.notify_focused",
		title = "Notify While Watching",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, notify_focused),
		default_value = "false",
		description = "Also notify about the pane you are looking at.",
	},
	{
		key = "status.scope",
		title = "Status Overview Scope",
		kind = .Enum,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, scope),
		default_value = "all",
		names = STATUS_SCOPE_NAMES,
		description = "Whether the inbox and panel list every workspace or only the window's workspace.",
	},
	{
		key = "status.keep_finished",
		title = "Keep Finished Status",
		kind = .Enum,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, keep_finished),
		default_value = "focus",
		names = STATUS_KEEP_NAMES,
		description = "Remove done and error status once you leave the pane you looked at, or keep it until you " +
			"dismiss it.",
	},
	{
		key = "status.ignore_apps",
		title = "Ignore Status From",
		kind = .String,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, ignore_apps),
		default_value = "",
		valid = {0, 256},
		description = "Comma-separated program names, the OSC 7501 app key such as vite or cargo, whose status " +
			"is never shown.",
	},
	{
		key = "shell.default_profile",
		title = "Default Shell Profile",
		kind = .String,
		offset = offset_of(Settings, shell) + offset_of(Shell_Settings, default_profile),
		default_value = "default",
		valid = {1, 64},
		description = "Profile for new tabs, splits and the plus button. Profiles are ordered by profile.order.",
	},
	{
		key = "input.leader",
		title = "Leader Key",
		kind = .String,
		offset = offset_of(Settings, input) + offset_of(Input_Settings, leader),
		default_value = "",
		valid = {0, 128},
		control = .Shortcut,
		affects_bindings = true,
		description = "Optional leader chord, for example Ctrl+B; use Leader+T in a command shortcut. Empty " +
			"disables it.",
	},
	{
		key = "font.family",
		title = "Shell Font",
		kind = .String,
		offset = offset_of(Settings, font) + offset_of(Font_Settings, family),
		default_value = "Cascadia Mono",
		valid = {1, 256},
		control = .Choice,
		live_choices = .Shell_Fonts,
		choice_filter = "font.show_all",
		description = "Terminal font family.",
	},
	{
		key = "font.show_all",
		title = "Show All Fonts",
		kind = .Bool,
		offset = offset_of(Settings, font) + offset_of(Font_Settings, show_all),
		default_value = "false",
		embedded = true,
		description = "Include proportional fonts in the shell font list.",
	},
	{
		key = "interface.font_family",
		title = "GUI Font",
		kind = .String,
		offset = offset_of(Settings, interface) + offset_of(Interface_Settings, font_family),
		default_value = "Segoe UI Variable Text",
		valid = {1, 256},
		control = .Choice,
		live_choices = .Interface_Fonts,
		description = "Font family for interface text; independent of the shells.",
	},
	{
		key = "interface.font_size",
		title = "GUI Font Size",
		kind = .Float,
		offset = offset_of(Settings, interface) + offset_of(Interface_Settings, font_size),
		default_value = "9.75",
		valid = {6, 14},
		// 0.75 pt is one pixel at 96 DPI, so each step lands on a whole pixel size.
		step = 0.75,
		description = "Body text size in points (9.75 is 13 px); other interface text keeps its ratio to it.",
	},
	{
		key = "interface.hover_lift",
		title = "Hover Lift",
		kind = .Float,
		offset = offset_of(Settings, interface) + offset_of(Interface_Settings, hover_lift),
		default_value = "1.5",
		valid = {0, 4},
		description = "How far interactive controls rise on hover, in DIPs. Zero disables the lift.",
	},
	{
		key = "interface.hover_gloss",
		title = "Hover Gloss",
		kind = .Float,
		offset = offset_of(Settings, interface) + offset_of(Interface_Settings, hover_gloss),
		default_value = "1",
		valid = {0, 2},
		description = "Strength of the pointer-following rim light on hovered controls. One is the designed " +
			"strength; zero disables it.",
	},
	{
		key = "font.size",
		title = "Font Size",
		kind = .Float,
		offset = offset_of(Settings, font) + offset_of(Font_Settings, size),
		default_value = "12",
		valid = {1, 200},
		slider = {6, 32},
		step = 1,
		description = "Font size in points.",
	},
	{
		key = "font.line_height",
		title = "Line Height",
		kind = .Float,
		offset = offset_of(Settings, font) + offset_of(Font_Settings, line_height),
		default_value = "1.0",
		valid = {0.5, 4},
		slider = {0.8, 2},
		step = 0.05,
		description = "Line height multiplier.",
	},
	{
		key = "shell.refresh_environment",
		title = "Refresh Shell Environment",
		kind = .Bool,
		offset = offset_of(Settings, shell) + offset_of(Shell_Settings, refresh_environment),
		default_value = "true",
		description = "Read current Windows environment variables for new and restarted shells; keep " +
			"launcher-only variables.",
	},
	{
		key = "shell.integration",
		title = "Shell Integration",
		kind = .Bool,
		offset = offset_of(Settings, shell) + offset_of(Shell_Settings, integration),
		default_value = "true",
		description = "Report the PowerShell prompt's directory so splits open there. Applies to new shells.",
	},
	{
		key = "window.columns",
		title = "Initial Columns",
		kind = .Int,
		offset = offset_of(Settings, window) + offset_of(Window_Settings, columns),
		default_value = "120",
		valid = {1, 32767},
		apply_timing = .New_Sessions,
		description = "Initial terminal columns.",
	},
	{
		key = "window.rows",
		title = "Initial Rows",
		kind = .Int,
		offset = offset_of(Settings, window) + offset_of(Window_Settings, rows),
		default_value = "32",
		valid = {1, 32767},
		apply_timing = .New_Sessions,
		description = "Initial terminal rows.",
	},
	{
		key = "window.padding",
		title = "Content Padding",
		kind = .Int,
		offset = offset_of(Settings, window) + offset_of(Window_Settings, padding),
		default_value = "8",
		valid = {0, 1024},
		description = "Terminal content inset inside each pane card in DIPs; outer spacing follows pane.gap.",
	},
	{
		key = "window.tray_notification",
		title = "Notify When Closing to Tray",
		kind = .Bool,
		offset = offset_of(Settings, window) + offset_of(Window_Settings, tray_notification),
		default_value = "true",
		description = "Show the \"AIODev is still running\" notification the first time closing the last window " +
			"hides AIODev to the tray.",
	},
	{
		key = PADDING_GROUPS_KEY,
		title = "Process Padding Groups",
		kind = .String,
		offset = offset_of(Settings, process) + offset_of(Process_Settings, padding_groups),
		default_value = "",
		valid = {0, 4096},
		control = .Group,
		validator = .Padding_Groups,
		description = "Named groups: " + PADDING_GROUPS_EXAMPLE + ". First match wins; " +
			"other processes use Content Padding.",
	},
	{
		key = "scrollback.lines",
		title = "Scrollback Lines",
		kind = .Int,
		offset = offset_of(Settings, scrollback) + offset_of(Scrollback_Settings, lines),
		default_value = "10000",
		valid = {0, 10000000},
		description = "Scrollback lines to keep; history is freed in blocks, so the count kept varies by a few " +
			"hundred.",
	},
	{
		key = "terminal.copy_on_select",
		title = "Copy on Select",
		kind = .Bool,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, copy_on_select),
		default_value = "false",
		description = "Copy selected text automatically; otherwise Ctrl+Shift+C copies it.",
	},
	{
		key = "terminal.confirm_multiline_paste",
		title = "Confirm Multiline Paste",
		kind = .Bool,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, confirm_multiline_paste),
		default_value = "true",
		description = "Ask before pasting line breaks the shell would run as separate commands.",
	},
	{
		key = "terminal.find_keep_query",
		title = "Keep Last Search",
		kind = .Bool,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, find_keep_query),
		default_value = "false",
		description = "Start find with the last search filled in.",
	},
	{
		key = "terminal.find_select_query",
		title = "Select Last Search",
		kind = .Bool,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, find_select_query),
		default_value = "false",
		description = "Start find with the last search filled in and selected, so typing replaces it.",
	},
	{
		key = "terminal.minimum_contrast",
		title = "Minimum Text Contrast",
		kind = .Float,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, minimum_contrast),
		default_value = "4.5",
		valid = {1, 21},
		description = "Minimum text contrast in light themes, including application colors. " +
			"One preserves exact colors; dark themes stay unchanged.",
	},
	{
		key = "cursor.style",
		title = "Cursor Style",
		kind = .Enum,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, style),
		default_value = "block",
		names = CURSOR_STYLE_NAMES,
		description = "Cursor shape: block, bar, or underline.",
	},
	{
		key = "cursor.blink",
		title = "Cursor Blink",
		kind = .Bool,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, blink),
		default_value = "false",
		description = "Blink the cursor.",
	},
	{
		key = "control.enabled",
		title = "Command Line Control",
		kind = .Bool,
		offset = offset_of(Settings, control) + offset_of(Control_Settings, enabled),
		default_value = "false",
		description = "Accept commands from the aio command line, which scripts and coding agents use to open " +
			"tabs and panes, send them text and read their screens. Only programs running as you " +
			"on this computer can connect.",
	},
}
Diagnostic_Kind :: enum {
	Unknown_Key,
	Malformed_Line,
	Invalid_Value,
	Out_Of_Range,
	Duplicate_Key,
	Shortcut_Warning,
}
Diagnostic :: struct {
	line:         int,
	key, message: string,
	kind:         Diagnostic_Kind,
	// What the problem means without where it is, so moved source lines do not make it new. Every
	// diagnostic has one: given by the producer, or derived by diagnostic_identity_of.
	identity:     string,
}

@(private)
Problem :: struct {
	kind:    Diagnostic_Kind,
	message: string,
}

@(private, require_results)
problem :: proc(
	kind: Diagnostic_Kind,
	allocator: runtime.Allocator,
	parts: ..string,
) -> (
	Maybe(Problem),
	runtime.Allocator_Error,
) {
	message, err := strings.concatenate(parts, allocator)
	if err != nil {return nil, err}
	return Problem{kind, message}, nil
}

// The diagnostic every file family reports for a repeated key; the later line's value is used.
@(require_results)
duplicate_key_diagnostic :: proc(
	diagnostics: ^[dynamic]Diagnostic,
	key: string,
	line: int,
) -> runtime.Allocator_Error {
	issue, issue_error := problem(
		.Duplicate_Key,
		diagnostics.allocator,
		"duplicate key \"",
		key,
		"\"; last value wins",
	)
	if issue_error != nil {return issue_error}
	return add_diagnostic(diagnostics, line, key, issue.(Problem))
}

// The message for a collection that reached its limit, such as "too many profiles; the limit is
// 64". Temporary.
limit_message :: proc(items: string, limit: int) -> string {
	return fmt.tprintf("too many %s; the limit is %d", items, limit)
}

// The text of a file value: checked for UTF-8 without NUL bytes, then one enclosing pair of double
// quotes removed. `text` borrows `input`; `issue` is empty when the value is usable.
text_value_decode :: proc(input: string) -> (text, issue: string) {
	if !text_valid(input) {return "", "expected UTF-8 text without NUL bytes"}
	text = input
	if len(text) > 0 && text[0] == '"' {
		if len(text) < 2 || text[len(text) - 1] != '"' {return "", "expected a closing double quote"}
		text = text[1:len(text) - 1]
	}
	return text, ""
}

// Whether settings can store `text`: UTF-8 without NUL bytes.
text_valid :: proc(text: string) -> bool {
	return utf8.valid_string(text) && !strings.contains(text, "\x00")
}

@(private, require_results)
range_problem :: proc(
	entry: Schema_Entry,
	value: string,
	allocator: runtime.Allocator,
) -> (
	Maybe(Problem),
	runtime.Allocator_Error,
) {
	buffer: [128]u8
	limits := fmt.bprintf(buffer[:], "%g..%g", entry.valid.minimum, entry.valid.maximum)
	if entry.kind == .String {
		return problem(
			.Out_Of_Range,
			allocator,
			"string length is out of range ",
			limits,
			" UTF-8 bytes",
		)
	}
	return problem(.Out_Of_Range, allocator, value, " is out of range ", limits)
}

// One checked schema value: a String borrows the text it was parsed from, an Enum is its index in
// `names` and a Set is its mask.
@(private)
Parsed_Value :: union {
	string,
	int,
	f64,
	bool,
	u32,
}

// Checks one file value against its descriptor without touching any settings. A problem's message
// is owned by `allocator`.
@(private, require_results)
value_parse :: proc(
	entry: Schema_Entry,
	input: string,
	allocator: runtime.Allocator,
) -> (
	Parsed_Value,
	Maybe(Problem),
	runtime.Allocator_Error,
) {
	value, text_issue := text_value_decode(input)
	if text_issue != "" {
		issue, err := problem(.Invalid_Value, allocator, text_issue)
		return nil, issue, err
	}
	switch entry.kind {
	case .String:
		switch entry.validator {
		case .None:
		case .Padding_Groups:
			if !padding_groups_valid(value) {
				buffer: [192]u8
				issue, err := problem(.Invalid_Value, allocator, padding_groups_rules(buffer[:]))
				return nil, issue, err
			}
		case .Program_Icons:
			if !program_icon_files_valid(value) {
				buffer: [256]u8
				issue, err := problem(.Invalid_Value, allocator, program_icon_files_rules(buffer[:]))
				return nil, issue, err
			}
		}
		if f64(len(value)) < entry.valid.minimum || f64(len(value)) > entry.valid.maximum {
			issue, err := range_problem(entry, value, allocator)
			return nil, issue, err
		}
		return value, nil, nil
	case .Int:
		v, ok := strconv.parse_int(value, 10)
		if !ok {
			issue, err := problem(
				.Invalid_Value,
				allocator,
				"invalid integer \"",
				value,
				"\", expected a decimal integer",
			)
			return nil, issue, err
		}
		if f64(v) < entry.valid.minimum || f64(v) > entry.valid.maximum {
			issue, err := range_problem(entry, value, allocator)
			return nil, issue, err
		}
		return v, nil, nil
	case .Float:
		v, ok := strconv.parse_f64(value)
		if !ok {
			issue, err := problem(
				.Invalid_Value,
				allocator,
				"invalid number \"",
				value,
				"\", expected a number",
			)
			return nil, issue, err
		}
		if !(v >= entry.valid.minimum && v <= entry.valid.maximum) {
			issue, err := range_problem(entry, value, allocator)
			return nil, issue, err
		}
		return v, nil, nil
	case .Bool:
		if value != "true" && value != "false" {
			issue, err := problem(
				.Invalid_Value,
				allocator,
				"invalid boolean \"",
				value,
				"\", expected true or false",
			)
			return nil, issue, err
		}
		return value == "true", nil, nil
	case .Enum:
		for name, i in entry.names {
			if name == value {return i, nil, nil}
		}
		names, err := strings.join(entry.names, ", ", allocator)
		if err != nil {return nil, nil, err}
		defer delete(names, allocator)
		issue, issue_error := problem(.Invalid_Value, allocator, "\"", value, "\" is not one of ", names)
		return nil, issue, issue_error
	case .Set:
		mask, unknown, ok := set_parse(entry.names, value)
		if ok {return mask, nil, nil}
		names, err := strings.join(entry.names, ", ", allocator)
		if err != nil {return nil, nil, err}
		defer delete(names, allocator)
		issue, issue_error := problem(
			.Invalid_Value,
			allocator,
			"\"",
			unknown,
			"\" is not one of ",
			names,
			"; separate choices with commas, or use none",
		)
		return nil, issue, issue_error
	}
	return nil, nil, nil
}

@(private, require_results)
assign :: proc(
	s: ^Settings,
	entry: Schema_Entry,
	input: string,
) -> (
	Maybe(Problem),
	runtime.Allocator_Error,
) {
	value, issue, err := value_parse(entry, input, s.allocator)
	if err != nil || issue != nil {return issue, err}
	p := rawptr(uintptr(s) + entry.offset)
	switch v in value {
	case string:
		copy, clone_error := strings.clone(v, s.allocator)
		if clone_error != nil {return nil, clone_error}
		field := cast(^string)p
		delete(field^, s.allocator)
		field^ = copy
	case int:
		(cast(^int)p)^ = v
	case f64:
		(cast(^f64)p)^ = v
	case bool:
		(cast(^bool)p)^ = v
	case u32:
		(cast(^u32)p)^ = v
	}
	return nil, nil
}

#assert(size_of(Status_Channels) == size_of(u32))

// Reads `none` or comma-separated names; bit i is names[i]. On failure `unknown` is the bad part.
set_parse :: proc(names: []string, value: string) -> (mask: u32, unknown: string, ok: bool) {
	if strings.trim_space(value) == "none" {return 0, "", true}
	rest := value
	for part in strings.split_iterator(&rest, ",") {
		name := strings.trim_space(part)
		found := false
		for candidate, i in names {
			if candidate == name {
				mask |= 1 << u32(i)
				found = true
				break
			}
		}
		if !found {return 0, name, false}
	}
	return mask, "", true
}

// The canonical saved form: names in schema order, or `none`. Allocated from the temp allocator.
set_text :: proc(names: []string, mask: u32) -> string {
	b := strings.builder_make(context.temp_allocator)
	for name, i in names {
		if mask & (1 << u32(i)) == 0 {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, name)
	}
	return strings.builder_len(b) == 0 ? "none" : strings.to_string(b)
}

@(require_results)
defaults :: proc(allocator := context.allocator) -> (Settings, runtime.Allocator_Error) {
	s := Settings {
		allocator = allocator,
	}
	s.keys.allocator = allocator
	s.themes.allocator = allocator
	profiles_init(&s.profiles, allocator)
	for entry in SCHEMA {
		issue, err := assign(&s, entry, entry.default_value)
		if err != nil {
			destroy(&s)
			return {}, err
		}
		if p, present := issue.?; present {
			delete(p.message, allocator)
			unreachable()
		}
	}
	if profile_error := profiles_finalize(&s); profile_error != nil {
		destroy(&s)
		return {}, profile_error
	}
	if theme_error := resolve_theme(&s, nil); theme_error != nil {
		destroy(&s)
		return {}, theme_error
	}
	return s, nil
}

destroy :: proc(s: ^Settings) {
	for binding in s.keys {
		delete(binding.name, s.allocator)
		delete(binding.value, s.allocator)
	}
	delete(s.keys)
	for entry in SCHEMA {
		if entry.kind == .String {
			delete((cast(^string)(uintptr(s) + entry.offset))^, s.allocator)
		}
	}
	profiles_destroy(&s.profiles)
	for theme in s.themes {
		delete(theme.id, s.allocator)
		delete(theme.base, s.allocator)
		delete(theme.name, s.allocator)
	}
	delete(s.themes)
	s^ = {}
}

diagnostics_destroy :: proc(diagnostics: ^[dynamic]Diagnostic) {
	for d in diagnostics^ {
		delete(d.key, diagnostics.allocator)
		delete(d.message, diagnostics.allocator)
		delete(d.identity, diagnostics.allocator)
	}
	delete(diagnostics^)
	diagnostics^ = {}
}

@(require_results)
diagnostic_append :: proc(
	out: ^[dynamic]Diagnostic,
	line: int,
	key, message: string,
	kind: Diagnostic_Kind = .Invalid_Value,
	identity := "",
) -> runtime.Allocator_Error {
	issue, err := problem(kind, out.allocator, message)
	if err != nil {return err}
	return add_diagnostic(out, line, key, issue.(Problem), identity)
}

@(private, require_results)
add_diagnostic :: proc(
	out: ^[dynamic]Diagnostic,
	line: int,
	key: string,
	issue: Problem,
	identity := "",
) -> runtime.Allocator_Error {
	copy, err := strings.clone(key, out.allocator)
	if err != nil {
		delete(issue.message, out.allocator)
		return err
	}
	meaning := identity != "" ? identity : diagnostic_identity_of(issue.kind, issue.message)
	if meaning, err = strings.clone(meaning, out.allocator); err == nil {
		_, err = append(out, Diagnostic{line, copy, issue.message, issue.kind, meaning})
	}
	if err != nil {
		delete(copy, out.allocator)
		delete(meaning, out.allocator)
		delete(issue.message, out.allocator)
	}
	return err
}

// The identity of a diagnostic whose producer gave none. Settings problems carry their line apart
// from the message, so the message is the meaning. A shortcut warning names its source lines in a
// trailing " [file:line; ...]" part, which is location rather than meaning.
@(private)
diagnostic_identity_of :: proc(kind: Diagnostic_Kind, message: string) -> string {
	if kind == .Shortcut_Warning && strings.has_suffix(message, "]") {
		if at := strings.last_index(message, " ["); at > 0 {return strings.trim_space(message[:at])}
	}
	return message
}

@(private, require_results)
parse_key_binding :: proc(
	s: ^Settings,
	diagnostics: ^[dynamic]Diagnostic,
	key, value: string,
	line_number: int,
) -> runtime.Allocator_Error {
	allocator := s.allocator
	binding_name := strings.trim_prefix(key, KEY_BINDING_PREFIX)
	duplicate := -1
	for binding, i in s.keys {
		if binding.name == binding_name {
			duplicate = i
			break
		}
	}
	if duplicate >= 0 {
		if err := duplicate_key_diagnostic(diagnostics, key, line_number); err != nil {return err}
	}
	name, name_error := strings.clone(binding_name, allocator)
	if name_error != nil {return name_error}
	owned, value_error := strings.clone(value, allocator)
	if value_error != nil {
		delete(name, allocator)
		return value_error
	}
	binding := Key_Binding{name, owned, line_number}
	if duplicate >= 0 {
		delete(s.keys[duplicate].name, allocator)
		delete(s.keys[duplicate].value, allocator)
		s.keys[duplicate] = binding
	} else {
		_, append_error := append(&s.keys, binding)
		if append_error != nil {
			delete(name, allocator)
			delete(owned, allocator)
			return append_error
		}
	}
	return nil
}

// Parses settings text. With `inputs`, the revision also gets that snapshot's detected shells and
// theme files; the result owns its own copies.
@(require_results)
parse :: proc(
	text: string,
	allocator := context.allocator,
	inputs: ^Inputs = nil,
) -> (
	Settings,
	[dynamic]Diagnostic,
	runtime.Allocator_Error,
) {
	s, err := defaults(allocator)
	if err != nil {return {}, {}, err}
	diagnostics := make([dynamic]Diagnostic, allocator)
	success := false
	defer if !success {
		destroy(&s)
		diagnostics_destroy(&diagnostics)
	}
	schema := SCHEMA
	legacy: Legacy_Shell_Input
	scanner := line_scanner_init(text)
	for {
		line, ok := line_next(&scanner)
		if !ok {break}
		if line.text == "" || line.text[0] == '#' {continue}
		if !line.split {
			issue, issue_error := problem(.Malformed_Line, allocator, "expected \"key = value\"")
			if issue_error != nil {return {}, {}, issue_error}
			err = add_diagnostic(&diagnostics, line.number, line.text, issue.(Problem))
			if err != nil {return {}, {}, err}
			continue
		}
		key := line.key
		value := line.value
		// Retired keys must not make an existing settings file invalid.
		if key == "tabs.vertical_scope" || key == "theme.mode" {continue}
		if strings.has_prefix(key, KEY_BINDING_PREFIX) {
			binding_error := parse_key_binding(&s, &diagnostics, key, value, line.number)
			if binding_error != nil {return {}, {}, binding_error}
			continue
		}
		if strings.has_prefix(key, PROFILE_PREFIX) {
			profile_error := parse_profile_key(&s, &diagnostics, key, value, line.number)
			if profile_error != nil {return {}, {}, profile_error}
			continue
		}
		if strings.has_prefix(key, CUSTOM_THEME_PREFIX) {
			theme_error := parse_custom_theme_key(&s, &diagnostics, key, value, line.number)
			if theme_error != nil {return {}, {}, theme_error}
			continue
		}
		if field, is_legacy := legacy_shell_field(key); is_legacy {
			if legacy[field] != nil {
				err = duplicate_key_diagnostic(&diagnostics, key, line.number)
				if err != nil {return {}, {}, err}
			}
			entry := legacy_shell_entries[field]
			parsed, issue, parse_error := value_parse(entry, value, allocator)
			if parse_error != nil {return {}, {}, parse_error}
			legacy_value := entry.default_value
			if p, present := issue.?; present {
				err = add_diagnostic(&diagnostics, line.number, key, p)
				if err != nil {return {}, {}, err}
			} else {
				legacy_value = parsed.(string)
			}
			legacy[field] = legacy_value
			continue
		}
		index := schema_index(key)
		if index < 0 {
			issue, issue_error := problem(
				.Unknown_Key,
				allocator,
				"unknown key \"",
				key,
				"\"; expected a key from the settings schema",
			)
			if issue_error != nil {return {}, {}, issue_error}
			err = add_diagnostic(&diagnostics, line.number, key, issue.(Problem))
			if err != nil {return {}, {}, err}
			continue
		}
		if s.lines[index] > 0 {
			err = duplicate_key_diagnostic(&diagnostics, key, line.number)
			if err != nil {return {}, {}, err}
		}
		s.lines[index] = line.number
		issue, assign_error := assign(&s, schema[index], value)
		if assign_error != nil {return {}, {}, assign_error}
		if p, present := issue.?; present {
			err = add_diagnostic(&diagnostics, line.number, key, p)
			if err != nil {return {}, {}, err}
			default_issue, default_error := assign(&s, schema[index], schema[index].default_value)
			if default_error != nil {return {}, {}, default_error}
			assert(default_issue == nil)
		}
	}
	if legacy_error := profiles_resolve_legacy(&s.profiles, legacy); legacy_error != nil {
		return {}, {}, legacy_error
	}
	if profile_error := profiles_finalize(&s); profile_error != nil {return {}, {}, profile_error}
	if inputs != nil {
		if detect_error := profiles_apply_detection(&s, inputs.detected[:]); detect_error != nil {
			return {}, {}, detect_error
		}
		if file_error := theme_files_apply(&s, &diagnostics, inputs.theme_files[:]); file_error != nil {
			return {}, {}, file_error
		}
	}
	if default_error := theme_default_add(&s); default_error != nil {return {}, {}, default_error}
	if theme_error := resolve_theme(&s, &diagnostics); theme_error != nil {return {}, {}, theme_error}
	success = true
	return s, diagnostics, nil
}

@(require_results)
default_text :: proc(
	allocator := context.allocator,
	extra_comments: []string = nil,
) -> (
	text: string,
	err: runtime.Allocator_Error,
) {
	builder := strings.builder_make(allocator) or_return
	defer strings.builder_destroy(&builder)
	previous: string
	for entry in SCHEMA {
		group := entry.key[:strings.index_byte(entry.key, '.')]
		if previous != "" && previous != group {
			write_parts(&builder, "\n") or_return
		}
		previous = group
		write_parts(&builder, "# ", entry.description, "\n", entry.key, " = ") or_return
		encode_value(&builder, entry, entry.default_value) or_return
		write_parts(&builder, "\n") or_return
	}
	write_parts(
		&builder,
		"\n# Profiles: profile.ID.name, .command, .directory, .icon and .hidden.\n",
		"# profile.order controls menu order and Ctrl+Shift+1 to 9; unlisted IDs follow by ID.\n",
		PROFILE_ORDER_KEY,
		" = default\n\n",
		"profile.default.name = \"PowerShell 7\"\n",
		"profile.default.command = \"",
		DEFAULT_PROFILE_COMMAND,
		"\"\n",
		"profile.default.directory = \"",
		DEFAULT_PROFILE_DIRECTORY,
		"\"\n\n",
		"# Custom themes: theme.custom.ID.base names another theme such as studio-dark, and\n",
		"# theme.custom.ID.COLOR = #rrggbb overrides one color. Changing a color in Settings saves one.\n",
	) or_return
	if len(extra_comments) > 0 {write_parts(&builder, "\n") or_return}
	for line in extra_comments {
		write_parts(&builder, "# ", line, "\n") or_return
	}
	return strings.clone(strings.to_string(builder), allocator)
}

// When requested, source_out receives the text the file holds as far as this load knows, owned by
// allocator: the migrated text once its save succeeds, otherwise the text as read, so a later save's
// exact-text check compares against the file. The caller frees it with that allocator. On failure it
// is empty; omitted outputs cost no allocation.
@(require_results)
load :: proc(
	path: string,
	allocator := context.allocator,
	extra_comments: []string = nil,
	inputs: ^Inputs = nil,
	source_out: ^string = nil,
) -> (
	s: Settings,
	diagnostics: [dynamic]Diagnostic,
	created: bool,
	migrated: bool,
	migration_error: Save_Error,
	err: os.Error,
) {
	if source_out != nil {source_out^ = ""}
	data, read_error := os.read_entire_file(path, allocator)
	defer delete(data, allocator)
	if read_error == nil {
		text, changed, migration_alloc := migrate_settings_text(string(data), allocator)
		if migration_alloc != nil {
			err = migration_alloc
			return
		}
		defer delete(text, allocator)
		// A failed save still runs the migrated text, so the colors on screen match the file a
		// later save writes.
		if changed {
			switch save(path, string(data), text) {
			case .None:
				migrated = true
			case .Conflict:
				migration_error = .Conflict
			case .IO:
				migration_error = .IO
			}
		}
		parse_error: runtime.Allocator_Error
		s, diagnostics, parse_error = parse(text, allocator, inputs)
		if parse_error != nil {err = parse_error; return}
		if source_out != nil {
			if changed && !migrated {
				source_out^, data = string(data), nil
			} else {
				source_out^, text = text, ""
			}
		}
		return
	}
	if read_error != os.Error(os.General_Error.Not_Exist) {
		err = read_error
		return
	}
	err = os.mkdir_all(os.dir(path))
	if err != nil {return}
	text, text_error := default_text(allocator, extra_comments)
	if text_error != nil {
		err = text_error
		return
	}
	defer delete(text, allocator)
	err = os.write_entire_file(path, text)
	if err != nil {return}
	default_error: runtime.Allocator_Error
	s, diagnostics, default_error = parse(text, allocator, inputs)
	if default_error != nil {
		err = default_error
		return
	}
	if source_out != nil {source_out^, text = text, ""}
	created = true
	return
}

// Applies every file migration in order. The result is owned whether or not it changed.
@(require_results)
migrate_settings_text :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	updated: string,
	changed: bool,
	err: runtime.Allocator_Error,
) {
	updated = strings.clone(text, allocator) or_return
	profiles, profiles_changed := migrate_text(updated, allocator) or_return
	if profiles_changed {
		delete(updated, allocator)
		updated, changed = profiles, true
	}
	variant, variant_changed := migrate_theme_variant_text(updated, allocator) or_return
	if variant_changed {
		delete(updated, allocator)
		updated, changed = variant, true
	}
	status, status_changed := migrate_status_notify_text(updated, allocator) or_return
	if status_changed {
		delete(updated, allocator)
		updated, changed = status, true
	}
	themes, themes_changed, theme_error := migrate_theme_text(updated, allocator)
	if theme_error != nil {
		delete(updated, allocator)
		return "", false, theme_error
	}
	if themes_changed {
		delete(updated, allocator)
		updated, changed = themes, true
	}
	return
}
