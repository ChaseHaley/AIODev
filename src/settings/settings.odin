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
// How the cursor moves between cells. Off keeps the plain cursor and turns every other cursor
// animation setting off.
Cursor_Animation :: enum int {
	Off,
	Smooth,
	Smear,
	Trail,
}
CURSOR_ANIMATION_NAME :: [Cursor_Animation]string {
	.Off    = "off",
	.Smooth = "smooth",
	.Smear  = "smear",
	.Trail  = "trail",
}
// What Settings shows for each animation.
CURSOR_ANIMATION_LABEL :: [Cursor_Animation]string {
	.Off    = "Off",
	.Smooth = "Smooth",
	.Smear  = "Smear",
	.Trail  = "Trail",
}
#assert(len(Cursor_Animation) == 4)
CURSOR_ANIMATION_NAMES :: []string {
	CURSOR_ANIMATION_NAME[Cursor_Animation(0)],
	CURSOR_ANIMATION_NAME[Cursor_Animation(1)],
	CURSOR_ANIMATION_NAME[Cursor_Animation(2)],
	CURSOR_ANIMATION_NAME[Cursor_Animation(3)],
}
CURSOR_ANIMATION_LABELS :: []string {
	CURSOR_ANIMATION_LABEL[Cursor_Animation(0)],
	CURSOR_ANIMATION_LABEL[Cursor_Animation(1)],
	CURSOR_ANIMATION_LABEL[Cursor_Animation(2)],
	CURSOR_ANIMATION_LABEL[Cursor_Animation(3)],
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
	confirm:                          Confirm_Prompts,
}
// What Confirm Before asks about.
Confirm_Prompt :: enum u8 {
	Close_Split_Tab,
	Shell_Switch,
	Multiline_Paste,
}
Confirm_Prompts :: bit_set[Confirm_Prompt;u32]
// Saved names; bit i of a saved set is Confirm_Prompt(i).
CONFIRM_PROMPT_NAME :: [Confirm_Prompt]string {
	.Close_Split_Tab = "close_split_tab",
	.Shell_Switch    = "shell_switch",
	.Multiline_Paste = "multiline_paste",
}
CONFIRM_PROMPT_LABEL :: [Confirm_Prompt]string {
	.Close_Split_Tab = "Closing Split Tabs",
	.Shell_Switch    = "Switching Pane Shells",
	.Multiline_Paste = "Multiline Paste",
}
#assert(len(Confirm_Prompt) == 3)
CONFIRM_PROMPT_NAMES :: []string {
	CONFIRM_PROMPT_NAME[Confirm_Prompt(0)],
	CONFIRM_PROMPT_NAME[Confirm_Prompt(1)],
	CONFIRM_PROMPT_NAME[Confirm_Prompt(2)],
}
CONFIRM_PROMPT_LABELS :: []string {
	CONFIRM_PROMPT_LABEL[Confirm_Prompt(0)],
	CONFIRM_PROMPT_LABEL[Confirm_Prompt(1)],
	CONFIRM_PROMPT_LABEL[Confirm_Prompt(2)],
}
Pane_Settings :: struct {
	gap, corner_radius:            int,
	show_headers:                  bool,
	markdown_floating:             bool,
	resume_agents:                 bool,
	minimum_columns, minimum_rows: int,
	focus_border, unfocused_dim:   int,
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
// How Activity and the status inbox group and order reports (WORK-412). Within a group, reports
// with the same status sort by pane name; the view only sets row size.
Status_Group :: enum int {
	Status,
	Workspace,
}
STATUS_GROUP_NAME :: [Status_Group]string {
	.Status    = "status",
	.Workspace = "workspace",
}
STATUS_GROUP_LABEL :: [Status_Group]string {
	.Status    = "Status",
	.Workspace = "Workspace, then status",
}
#assert(len(Status_Group) == 2)
STATUS_GROUP_NAMES :: []string{STATUS_GROUP_NAME[Status_Group(0)], STATUS_GROUP_NAME[Status_Group(1)]}
STATUS_GROUP_LABELS :: []string{STATUS_GROUP_LABEL[Status_Group(0)], STATUS_GROUP_LABEL[Status_Group(1)]}
// What names a program's row in Activity and the inbox (WORK-406). A subagent's report keeps its
// own title.
Status_Row_Name :: enum int {
	Pane,
	Program,
	Tab,
	Folder,
}
STATUS_ROW_NAME_NAME :: [Status_Row_Name]string {
	.Pane    = "pane",
	.Program = "program",
	.Tab     = "tab",
	.Folder  = "folder",
}
STATUS_ROW_NAME_LABEL :: [Status_Row_Name]string {
	.Pane    = "Pane title",
	.Program = "Program",
	.Tab     = "Tab",
	.Folder  = "Folder",
}
#assert(len(Status_Row_Name) == 4)
STATUS_ROW_NAME_NAMES :: []string {
	STATUS_ROW_NAME_NAME[Status_Row_Name(0)],
	STATUS_ROW_NAME_NAME[Status_Row_Name(1)],
	STATUS_ROW_NAME_NAME[Status_Row_Name(2)],
	STATUS_ROW_NAME_NAME[Status_Row_Name(3)],
}
STATUS_ROW_NAME_LABELS :: []string {
	STATUS_ROW_NAME_LABEL[Status_Row_Name(0)],
	STATUS_ROW_NAME_LABEL[Status_Row_Name(1)],
	STATUS_ROW_NAME_LABEL[Status_Row_Name(2)],
	STATUS_ROW_NAME_LABEL[Status_Row_Name(3)],
}
// The details a row shows after its name, always in this order. Title is the report's own title,
// which tells apart several reports from one pane.
Status_Row_Term :: enum u8 {
	Title,
	Message,
	Pane,
	Program,
	Tab,
	Workspace,
	Folder,
}
Status_Row_Terms :: bit_set[Status_Row_Term;u32]
// Saved names; bit i of a saved set is Status_Row_Term(i).
STATUS_ROW_TERM_NAME :: [Status_Row_Term]string {
	.Title     = "title",
	.Message   = "message",
	.Pane      = "pane",
	.Program   = "program",
	.Tab       = "tab",
	.Workspace = "workspace",
	.Folder    = "folder",
}
STATUS_ROW_TERM_LABEL :: [Status_Row_Term]string {
	.Title     = "Report title",
	.Message   = "Message",
	.Pane      = "Pane title",
	.Program   = "Program",
	.Tab       = "Tab",
	.Workspace = "Workspace",
	.Folder    = "Folder",
}
#assert(len(Status_Row_Term) == 7)
STATUS_ROW_TERM_NAMES :: []string {
	STATUS_ROW_TERM_NAME[Status_Row_Term(0)],
	STATUS_ROW_TERM_NAME[Status_Row_Term(1)],
	STATUS_ROW_TERM_NAME[Status_Row_Term(2)],
	STATUS_ROW_TERM_NAME[Status_Row_Term(3)],
	STATUS_ROW_TERM_NAME[Status_Row_Term(4)],
	STATUS_ROW_TERM_NAME[Status_Row_Term(5)],
	STATUS_ROW_TERM_NAME[Status_Row_Term(6)],
}
STATUS_ROW_TERM_LABELS :: []string {
	STATUS_ROW_TERM_LABEL[Status_Row_Term(0)],
	STATUS_ROW_TERM_LABEL[Status_Row_Term(1)],
	STATUS_ROW_TERM_LABEL[Status_Row_Term(2)],
	STATUS_ROW_TERM_LABEL[Status_Row_Term(3)],
	STATUS_ROW_TERM_LABEL[Status_Row_Term(4)],
	STATUS_ROW_TERM_LABEL[Status_Row_Term(5)],
	STATUS_ROW_TERM_LABEL[Status_Row_Term(6)],
}
// When finished work you have read leaves the lists.
Status_Keep :: enum int {
	Program,
	Focus,
	Dismiss,
}
STATUS_KEEP_NAME :: [Status_Keep]string {
	.Program = "program",
	.Focus   = "focus",
	.Dismiss = "dismiss",
}
STATUS_KEEP_LABEL :: [Status_Keep]string {
	.Program = "Until the program ends",
	.Focus   = "When you leave the pane",
	.Dismiss = "Until dismissed",
}
#assert(len(Status_Keep) == 3)
STATUS_KEEP_NAMES :: []string {
	STATUS_KEEP_NAME[Status_Keep(0)],
	STATUS_KEEP_NAME[Status_Keep(1)],
	STATUS_KEEP_NAME[Status_Keep(2)],
}
STATUS_KEEP_LABELS :: []string {
	STATUS_KEEP_LABEL[Status_Keep(0)],
	STATUS_KEEP_LABEL[Status_Keep(1)],
	STATUS_KEEP_LABEL[Status_Keep(2)],
}
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
// Where Show Status On draws program status.
Status_Surface :: enum u8 {
	Tabs,
	Active_Tab,
	Pane_Headers,
	Workspace_Picker,
}
Status_Surfaces :: bit_set[Status_Surface;u32]
// Saved names; bit i of a saved set is Status_Surface(i).
STATUS_SURFACE_NAME :: [Status_Surface]string {
	.Tabs             = "tabs",
	.Active_Tab       = "active_tab",
	.Pane_Headers     = "pane_headers",
	.Workspace_Picker = "workspace_picker",
}
STATUS_SURFACE_LABEL :: [Status_Surface]string {
	.Tabs             = "Tabs",
	.Active_Tab       = "Active Tab",
	.Pane_Headers     = "Pane Headers",
	.Workspace_Picker = "Workspace Picker",
}
#assert(len(Status_Surface) == 4)
STATUS_SURFACE_NAMES :: []string {
	STATUS_SURFACE_NAME[Status_Surface(0)],
	STATUS_SURFACE_NAME[Status_Surface(1)],
	STATUS_SURFACE_NAME[Status_Surface(2)],
	STATUS_SURFACE_NAME[Status_Surface(3)],
}
STATUS_SURFACE_LABELS :: []string {
	STATUS_SURFACE_LABEL[Status_Surface(0)],
	STATUS_SURFACE_LABEL[Status_Surface(1)],
	STATUS_SURFACE_LABEL[Status_Surface(2)],
	STATUS_SURFACE_LABEL[Status_Surface(3)],
}
// The program states Show Statuses lists.
Status_Show_State :: enum u8 {
	Working,
	Blocked,
	Done,
	Error,
	Idle,
}
Status_Show_States :: bit_set[Status_Show_State;u32]
// Saved names; bit i of a saved set is Status_Show_State(i).
STATUS_SHOW_STATE_NAME :: [Status_Show_State]string {
	.Working = "working",
	.Blocked = "blocked",
	.Done    = "done",
	.Error   = "error",
	.Idle    = "idle",
}
STATUS_SHOW_STATE_LABEL :: [Status_Show_State]string {
	.Working = "Working",
	.Blocked = "Blocked",
	.Done    = "Done",
	.Error   = "Error",
	.Idle    = "Idle",
}
#assert(len(Status_Show_State) == 5)
STATUS_SHOW_STATE_NAMES :: []string {
	STATUS_SHOW_STATE_NAME[Status_Show_State(0)],
	STATUS_SHOW_STATE_NAME[Status_Show_State(1)],
	STATUS_SHOW_STATE_NAME[Status_Show_State(2)],
	STATUS_SHOW_STATE_NAME[Status_Show_State(3)],
	STATUS_SHOW_STATE_NAME[Status_Show_State(4)],
}
STATUS_SHOW_STATE_LABELS :: []string {
	STATUS_SHOW_STATE_LABEL[Status_Show_State(0)],
	STATUS_SHOW_STATE_LABEL[Status_Show_State(1)],
	STATUS_SHOW_STATE_LABEL[Status_Show_State(2)],
	STATUS_SHOW_STATE_LABEL[Status_Show_State(3)],
	STATUS_SHOW_STATE_LABEL[Status_Show_State(4)],
}
// The program states Taskbar Progress shows; none turns it off.
Status_Taskbar_State :: enum u8 {
	Working,
	Blocked,
	Error,
}
Status_Taskbar_States :: bit_set[Status_Taskbar_State;u32]
// Saved names; bit i of a saved set is Status_Taskbar_State(i).
STATUS_TASKBAR_STATE_NAME :: [Status_Taskbar_State]string {
	.Working = "working",
	.Blocked = "blocked",
	.Error   = "error",
}
STATUS_TASKBAR_STATE_LABEL :: [Status_Taskbar_State]string {
	.Working = "Working",
	.Blocked = "Blocked",
	.Error   = "Error",
}
#assert(len(Status_Taskbar_State) == 3)
STATUS_TASKBAR_STATE_NAMES :: []string {
	STATUS_TASKBAR_STATE_NAME[Status_Taskbar_State(0)],
	STATUS_TASKBAR_STATE_NAME[Status_Taskbar_State(1)],
	STATUS_TASKBAR_STATE_NAME[Status_Taskbar_State(2)],
}
STATUS_TASKBAR_STATE_LABELS :: []string {
	STATUS_TASKBAR_STATE_LABEL[Status_Taskbar_State(0)],
	STATUS_TASKBAR_STATE_LABEL[Status_Taskbar_State(1)],
	STATUS_TASKBAR_STATE_LABEL[Status_Taskbar_State(2)],
}
// Program status (OSC 7501). Each surface and state can be turned off on its own; `enabled` turns
// the whole protocol off, so programs see the terminal as unsupported.
Status_Settings :: struct {
	notify_idle, notify_working, notify_blocked, notify_error, notify_done: Status_Channels,
	surfaces: Status_Surfaces,
	show:     Status_Show_States,
	taskbar:  Status_Taskbar_States,

	panel_side: Status_Panel_Side,
	panel_view: Status_Panel_View,
	group_by:   Status_Group,
	row_name:   Status_Row_Name,
	row_terms:  Status_Row_Terms,
	panel_width, panel_height: int,
	enabled, inbox, panel, notify_focused: bool,
	scope:                                 Status_Scope,
	keep_finished:                         Status_Keep,
	ignore_apps:                           string,
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
// What the find bar starts with when it opens.
Find_Reopen :: enum int {
	Empty,
	Last,
	Last_Selected,
}
FIND_REOPEN_NAME :: [Find_Reopen]string {
	.Empty         = "empty",
	.Last          = "last",
	.Last_Selected = "last_selected",
}
FIND_REOPEN_LABEL :: [Find_Reopen]string {
	.Empty         = "Empty",
	.Last          = "Last Search",
	.Last_Selected = "Last Search Selected",
}
#assert(len(Find_Reopen) == 3)
FIND_REOPEN_NAMES :: []string {
	FIND_REOPEN_NAME[Find_Reopen(0)],
	FIND_REOPEN_NAME[Find_Reopen(1)],
	FIND_REOPEN_NAME[Find_Reopen(2)],
}
FIND_REOPEN_LABELS :: []string {
	FIND_REOPEN_LABEL[Find_Reopen(0)],
	FIND_REOPEN_LABEL[Find_Reopen(1)],
	FIND_REOPEN_LABEL[Find_Reopen(2)],
}
Terminal_Settings :: struct {
	copy_on_select:     bool,
	find_reopen:        Find_Reopen,
	minimum_contrast:   f64,
	scroll_page_length: f64,
	scrollbar:          bool,
}
Cursor_Settings :: struct {
	style:              Cursor_Style,
	blink:              bool,
	animation:          Cursor_Animation,
	// Milliseconds one animation lasts.
	animation_duration: int,
	// Percent strength of the smear or trail.
	animation_strength: int,
	// Glide the cursor to its new place; off moves it at once.
	animation_movement: bool,
	animation_across_panes: bool,
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
	motion:          Motion_Settings,
	tabs:            Tabs_Settings,
	status:          Status_Settings,
	control:         Control_Settings,
	profiles:        Profiles,
	openers:         Openers,
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
// The settings key of the leader shortcut, which binding validation reports beside the "keys." rows.
LEADER_KEY :: "input.leader"
// The settings key of a command's shortcuts, "keys.NAME". Temporary.
binding_key :: proc(name: string) -> string {
	return fmt.tprintf("%s%s", KEY_BINDING_PREFIX, name)
}
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
	// A motion context's value, read for the context its key names.
	Motion,
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

group_title :: proc(key: string) -> string {
	dot := strings.index_byte(key, '.')
	switch dot < 0 ? key : key[:dot] {
	case "theme":
		return "Theme"
	case "motion":
		return "Motion"
	case "pane":
		return "Panes"
	case "tab":
		return "Tabs"
	case "tabs":
		return "Tabs"
	case "status":
		return "Program Status"
	case "shell":
		return "Shell"
	case "input":
		return "Input"
	case "process":
		return "Processes"
	case "font":
		return "Font"
	case "interface":
		return "Interface"
	case "window":
		return "Window"
	case "scrollback":
		return "Scrollback"
	case "terminal":
		return "Terminal"
	case "cursor":
		return "Cursor"
	case "colors":
		return "Colors"
	case "control":
		return "Command Line"
	}
	return "Other"
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
		key = "pane.resume_agents",
		title = "Resume Agent Sessions",
		kind = .Bool,
		offset = offset_of(Settings, pane) + offset_of(Pane_Settings, resume_agents),
		default_value = "true",
		description = "Bring a pane running Claude Code, Codex or omp back in the same conversation when it " +
			"is reopened or AIODev restarts. Run Install Agent Session Hooks once so Claude Code and Codex " +
			"panes always know their conversation.",
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
		key = "motion.speed",
		title = "Animation Speed",
		kind = .Float,
		offset = offset_of(Settings, motion) + offset_of(Motion_Settings, speed),
		default_value = "1",
		valid = {0.25, 4},
		step = 0.05,
		description = "Speed of every pane animation: 2 runs them twice as fast, 0.5 at half speed. Windows' " +
			"Animation effects setting still turns them all off.",
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Panes],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Panes],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Panes) * size_of(string),
		default_value = "on 160ms decelerate",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Panes],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Panes] + MOTION_ROOT_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Split],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Split],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Split) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Split],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Split] + MOTION_CHILD_HINT +
			" Effects: grow, popin, fade or slide.",
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Close],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Close],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Close) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Close],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Close] + MOTION_CHILD_HINT +
			" Effects: collapse, popout, fade or slide.",
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.View],
		title = MOTION_CONTEXT_TITLE[Motion_Context.View],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.View) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.View],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.View] + MOTION_CHILD_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Switch],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Switch],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Switch) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Switch],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Switch] + MOTION_CHILD_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Workspace],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Workspace],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Workspace) * size_of(string),
		default_value = MOTION_WORKSPACE_DEFAULT,
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Workspace],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Workspace] + MOTION_CHILD_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Resize],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Resize],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Resize) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Resize],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Resize] + MOTION_CHILD_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Move],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Move],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Move) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Move],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Move] + MOTION_CHILD_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Float],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Float],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Float) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Float],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Float] + MOTION_CHILD_HINT,
	},
	{
		key = MOTION_CONTEXT_KEY[Motion_Context.Chrome],
		title = MOTION_CONTEXT_TITLE[Motion_Context.Chrome],
		kind = .String,
		offset = MOTION_CONTEXTS_OFFSET + uintptr(Motion_Context.Chrome) * size_of(string),
		default_value = "",
		valid = {0, 128},
		control = .Group,
		validator = .Motion,
		page_description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Chrome],
		description = MOTION_CONTEXT_DESCRIPTION[Motion_Context.Chrome] + MOTION_CHILD_HINT,
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
		key = "status.surfaces",
		title = "Show Status On",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, surfaces),
		default_value = "tabs, active_tab, pane_headers, workspace_picker",
		names = STATUS_SURFACE_NAMES,
		labels = STATUS_SURFACE_LABELS,
		description = "Where program status shows: a spinner, progress bar or symbol on tabs and on the " +
			"tab you are looking at, what a pane's program reports in its header, and a summary of " +
			"each workspace in the workspace picker. Active Tab needs Tabs; Pane Headers needs pane " +
			"headers.",
	},
	{
		key = "status.inbox",
		title = "Status Inbox",
		kind = .Bool,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, inbox),
		default_value = "true",
		description = "Show a title-bar button whose ring shows each program's status and opens a list of " +
			"programs grouped as Activity groups them.",
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
		key = "status.group_by",
		title = "Activity Grouping",
		kind = .Enum,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, group_by),
		default_value = "status",
		names = STATUS_GROUP_NAMES,
		labels = STATUS_GROUP_LABELS,
		description = "Group Activity and the status inbox by status, or by workspace and then status. " +
			"Programs with the same status sort by pane name.",
	},
	{
		key = "status.row_name",
		title = "Activity Row Name",
		kind = .Enum,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, row_name),
		default_value = "pane",
		names = STATUS_ROW_NAME_NAMES,
		labels = STATUS_ROW_NAME_LABELS,
		description = "What names each program in Activity and the status inbox. A subagent's report " +
			"keeps its own title.",
	},
	{
		key = "status.row_terms",
		title = "Activity Row Details",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, row_terms),
		default_value = "message, workspace",
		names = STATUS_ROW_TERM_NAMES,
		labels = STATUS_ROW_TERM_LABELS,
		description = "What each row in Activity and the status inbox shows after its name.",
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
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, taskbar),
		default_value = "working, blocked, error",
		names = STATUS_TASKBAR_STATE_NAMES,
		labels = STATUS_TASKBAR_STATE_LABELS,
		description = "Which programs show on the window's taskbar button: progress for working ones, " +
			"and blocked and failed work. None turns taskbar progress off.",
	},
	{
		key = "status.show",
		title = "Show Statuses",
		kind = .Set,
		offset = offset_of(Settings, status) + offset_of(Status_Settings, show),
		default_value = "working, blocked, done, error, idle",
		names = STATUS_SHOW_STATE_NAMES,
		labels = STATUS_SHOW_STATE_LABELS,
		description = "Which programs status shows: working, waiting for you, finished work to look at, " +
			"failed, or idle at their own prompt.",
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
		default_value = "program",
		names = STATUS_KEEP_NAMES,
		labels = STATUS_KEEP_LABELS,
		description = "When done and error status you have read leaves the lists: once the program that " +
			"reported it ends, as soon as you leave the pane, or only when you dismiss it.",
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
		key = LEADER_KEY,
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
		key = "interface.confirm",
		title = "Confirm Before",
		kind = .Set,
		offset = offset_of(Settings, interface) + offset_of(Interface_Settings, confirm),
		default_value = "close_split_tab, shell_switch, multiline_paste",
		names = CONFIRM_PROMPT_NAMES,
		labels = CONFIRM_PROMPT_LABELS,
		description = "Ask before closing a tab that has more than one pane, before replacing a running " +
			"pane's shell and losing its session, and before pasting line breaks the shell would run as " +
			"separate commands.",
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
		valid = CONTENT_PADDING_RANGE,
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
		key = "terminal.find_reopen",
		title = "Find Bar Reopens With",
		kind = .Enum,
		offset = offset_of(Settings, terminal) + offset_of(Terminal_Settings, find_reopen),
		default_value = "empty",
		names = FIND_REOPEN_NAMES,
		labels = FIND_REOPEN_LABELS,
		description = "What find starts with: an empty search, the last search, or the last search " +
			"selected so typing replaces it.",
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
		key = "cursor.animation",
		title = "Cursor Animation",
		kind = .Enum,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, animation),
		default_value = "off",
		names = CURSOR_ANIMATION_NAMES,
		labels = CURSOR_ANIMATION_LABELS,
		description = "Cursor animation preset for the terminal cursor and the caret of every text field: " +
			"off, smooth, smear, or trail. Off draws the cursor in place and turns every other cursor " +
			"animation setting off. Smooth glides the cursor without a trail; smear stretches it toward " +
			"its new place; trail leaves a fading trail behind it.",
	},
	{
		key = "cursor.animation_duration",
		title = "Cursor Animation Duration (ms)",
		kind = .Int,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, animation_duration),
		default_value = "100",
		valid = {20, 500},
		description = "How long one cursor animation lasts, in milliseconds.",
	},
	{
		key = "cursor.animation_strength",
		title = "Cursor Smear and Trail Strength (%)",
		kind = .Int,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, animation_strength),
		default_value = "65",
		valid = {0, 100},
		description = "How strong the smear or trail is, in percent, independent of cursor movement. Zero " +
			"removes the smear or trail; smooth has none.",
	},
	{
		key = "cursor.animation_movement",
		title = "Animate Cursor Movement",
		kind = .Bool,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, animation_movement),
		default_value = "true",
		description = "Glide the cursor to its new place. Off moves it there at once, while smear and trail " +
			"still draw at their own strength.",
	},
	{
		key = "cursor.animation_across_panes",
		title = "Animate Cursor Across Panes",
		kind = .Bool,
		offset = offset_of(Settings, cursor) + offset_of(Cursor_Settings, animation_across_panes),
		default_value = "true",
		description = "Use the selected cursor animation when switching between panes. " +
			"Has no effect when Cursor Animation is Off.",
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
	// diagnostic has one: given by the producer, or its message.
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
		case .Motion:
			c, _ := motion_context_from_key(entry.key)
			if _, motion_issue := motion_spec_parse(c, value); motion_issue != "" {
				issue, err := problem(.Invalid_Value, allocator, motion_issue)
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
		if entry.validator == .Motion {motion_spec_refresh(s, entry.key)}
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
#assert(size_of(Status_Surfaces) == size_of(u32))
#assert(size_of(Status_Show_States) == size_of(u32))
#assert(size_of(Status_Taskbar_States) == size_of(u32))
#assert(size_of(Confirm_Prompts) == size_of(u32))
#assert(size_of(Find_Reopen) == size_of(int))
#assert(size_of(Status_Row_Terms) == size_of(u32))

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
	openers_init(&s.openers, allocator)
	motion_init(&s.motion, allocator)
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
	openers_destroy(&s.openers)
	motion_destroy(&s.motion, s.allocator)
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
	meaning := identity != "" ? identity : issue.message
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
		if strings.has_prefix(key, OPENER_PREFIX) {
			opener_error := parse_opener_key(&s, &diagnostics, key, value, line.number)
			if opener_error != nil {return {}, {}, opener_error}
			continue
		}
		if strings.has_prefix(key, CUSTOM_THEME_PREFIX) {
			theme_error := parse_custom_theme_key(&s, &diagnostics, key, value, line.number)
			if theme_error != nil {return {}, {}, theme_error}
			continue
		}
		if strings.has_prefix(key, MOTION_CURVE_PREFIX) {
			curve_error := parse_motion_curve_key(&s, &diagnostics, key, value, line.number)
			if curve_error != nil {return {}, {}, curve_error}
			continue
		}
		if strings.has_prefix(key, MOTION_PRESET_PREFIX) {
			preset_error := parse_motion_preset_key(&s, &diagnostics, key, value, line.number)
			if preset_error != nil {return {}, {}, preset_error}
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
	if opener_error := openers_finalize(&s.openers, &diagnostics); opener_error != nil {
		return {}, {}, opener_error
	}
	if motion_error := motion_finalize(&s, &diagnostics); motion_error != nil {return {}, {}, motion_error}
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
		"# Link programs open a link's file or folder from its menu: opener.ID.name, .command,\n",
		"# .offers (files, folders, or both separated by a comma) and .placement (right, down,\n",
		"# float, tab, linked or window). %1 in the command is the path; without %1 the path\n",
		"# follows the command. .icon is a PNG path; without one, a known program such as Neovim shows\n",
		"# its own icon.\n",
		"# opener.order controls menu order; unlisted IDs follow by ID.\n",
		"# opener.nvim.name = \"Neovim\"\n",
		"# opener.nvim.command = \"nvim %1\"\n",
		"# opener.nvim.offers = files, folders\n",
		"# opener.nvim.placement = right\n\n",
		"# Custom themes: theme.custom.ID.base names another theme such as studio-dark, and\n",
		"# theme.custom.ID.COLOR = #rrggbb overrides one color. Changing a color in Settings saves one.\n\n",
		"# Motion curves: motion.curve.NAME = x1, y1, x2, y2 is a cubic Bezier whose y may leave 0..1\n",
		"# to overshoot, and motion.curve.NAME = spring BOUNCE a spring that bounces 0 to 0.9.\n\n",
		"# Motion presets: motion.preset.NAME = panes: on 160ms decelerate; split: popin. Applying one in\n",
		"# Settings copies its values into the motion.panes keys.\n",
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
	toggles, toggles_changed := migrate_toggle_sets_text(updated, allocator) or_return
	if toggles_changed {
		delete(updated, allocator)
		updated, changed = toggles, true
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
