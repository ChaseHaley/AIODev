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
Font_Settings :: struct {
	family:            string,
	size, line_height: f64,
}
Shell_Settings :: struct {
	// Legacy parse targets for the default profile. The file format uses profile.default.*;
	// these remain so an unwritable file still launches and existing callers keep working.
	command, directory, icon: string,
	default_profile:          string,
	refresh_environment:      bool,
	report_directory:         bool,
}
Input_Settings :: struct {
	leader: string,
}
Interface_Settings :: struct {
	font_size, hover_lift, hover_gloss: f64,
}
Tab_Settings :: struct {
	confirm_close: bool,
}
Tabs_Orientation :: enum int {
	Vertical,
	Horizontal,
}
Tabs_Settings :: struct {
	orientation: Tabs_Orientation,
}
Status_Scope :: enum int {
	All,
	Workspace,
}
Status_Keep :: enum int {
	Focus,
	Dismiss,
}
// Program status (OSC 7501). Each surface and state can be turned off on its own; `enabled` turns
// the whole protocol off, so programs see the terminal as unsupported.
Status_Settings :: struct {
	enabled, tab_indicators, active_tab_indicator, pane_headers, workspace_picker: bool,
	inbox, panel, board, taskbar:                                                 bool,
	show_idle, show_working, show_blocked, show_done, show_error:                 bool,
	notify_blocked, notify_error, notify_done, notify_focused:                    bool,
	scope:                                                                        Status_Scope,
	keep_finished:                                                                Status_Keep,
	ignore_apps:                                                                  string,
}
Window_Settings :: struct {
	columns, rows, padding: int,
}
Scrollback_Settings :: struct {
	lines: int,
}
Terminal_Settings :: struct {
	copy_on_select, confirm_multiline_paste: bool,
	minimum_contrast:                        f64,
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
	theme_line:      int,
	pane:            Pane_Settings,
	tab:             Tab_Settings,
	tabs:            Tabs_Settings,
	status:          Status_Settings,
	profiles:        Profiles,
	allocator:       runtime.Allocator,
	leader_line:     int,
	default_profile_line: int,
}
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
	Enum,
}
Schema_Entry :: struct {
	key, title:       string,
	kind:             Kind,
	offset:           uintptr,
	default_value:    string,
	minimum, maximum: f64,
	enum_names:       []string,
	description:      string,
}
SCHEMA :: [?]Schema_Entry {
	{
		"theme.name",
		"Theme",
		.String,
		offset_of(Settings, theme) + offset_of(Theme_Settings, name),
		DEFAULT_THEME_ID,
		1,
		64,
		nil,
		"Color theme ID: a file in the themes folder, such as studio-light, or a custom theme.",
	},
	{
		"pane.gap",
		"Pane Gap",
		.Int,
		offset_of(Settings, pane) + offset_of(Pane_Settings, gap),
		"5",
		0,
		24,
		nil,
		"Space between and around pane cards in DIPs.",
	},
	{
		"pane.corner_radius",
		"Pane Corner Radius",
		.Int,
		offset_of(Settings, pane) + offset_of(Pane_Settings, corner_radius),
		"7",
		0,
		16,
		nil,
		"Pane card corner radius in DIPs.",
	},
	{
		"pane.show_headers",
		"Show Pane Headers",
		.Bool,
		offset_of(Settings, pane) + offset_of(Pane_Settings, show_headers),
		"true",
		0,
		0,
		nil,
		"Show a header and controls on every terminal pane.",
	},
	{
		"pane.confirm_shell_switch",
		"Confirm Switching Pane Shells",
		.Bool,
		offset_of(Settings, pane) + offset_of(Pane_Settings, confirm_shell_switch),
		"true",
		0,
		0,
		nil,
		"Ask before a running pane's shell is replaced, losing its session.",
	},
	{
		"pane.minimum_columns",
		"Minimum Pane Width",
		.Int,
		offset_of(Settings, pane) + offset_of(Pane_Settings, minimum_columns),
		"20",
		0,
		32767,
		nil,
		"Minimum content columns for a new pane or split. Zero disables the width check; " +
			"existing panes may shrink.",
	},
	{
		"pane.minimum_rows",
		"Minimum Pane Height",
		.Int,
		offset_of(Settings, pane) + offset_of(Pane_Settings, minimum_rows),
		"5",
		0,
		32767,
		nil,
		"Minimum content rows for a new pane or split. Zero disables the height check; existing panes may shrink.",
	},
	{
		"tab.confirm_close",
		"Confirm Closing Split Tabs",
		.Bool,
		offset_of(Settings, tab) + offset_of(Tab_Settings, confirm_close),
		"true",
		0,
		0,
		nil,
		"Ask before closing a tab that has more than one pane.",
	},
	{
		"tabs.orientation",
		"Tab Orientation",
		.Enum,
		offset_of(Settings, tabs) + offset_of(Tabs_Settings, orientation),
		"horizontal",
		0,
		0,
		{"vertical", "horizontal"},
		"Draw tabs in a vertical rail along the left or in a horizontal strip in the title bar. " +
			"Switch at any time with Ctrl+Shift+L.",
	},
	{
		"status.enabled",
		"Program Status",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, enabled),
		"true",
		0,
		0,
		nil,
		"Listen for OSC 7501 program status reports from agents, builds and other long-running " +
			"programs. Off drops reports and tells programs the terminal does not support them.",
	},
	{
		"status.tab_indicators",
		"Status on Tabs",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, tab_indicators),
		"true",
		0,
		0,
		nil,
		"Show a spinner, progress bar or symbol on tabs whose programs are working, blocked, finished or failed.",
	},
	{
		"status.active_tab_indicator",
		"Status on the Active Tab",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, active_tab_indicator),
		"false",
		0,
		0,
		nil,
		"Also show tab status on the tab you are looking at.",
	},
	{
		"status.pane_headers",
		"Status in Pane Headers",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, pane_headers),
		"true",
		0,
		0,
		nil,
		"Show what a pane's program reports in its header. Needs pane headers.",
	},
	{
		"status.workspace_picker",
		"Status in Workspace Picker",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, workspace_picker),
		"true",
		0,
		0,
		nil,
		"Summarize each workspace's program status in the workspace picker.",
	},
	{
		"status.inbox",
		"Status Inbox",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, inbox),
		"true",
		0,
		0,
		nil,
		"Show a title-bar summary that opens a list of programs ordered by what needs you first.",
	},
	{
		"status.panel",
		"Activity Panel",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, panel),
		"false",
		0,
		0,
		nil,
		"Show a docked list of every program reporting status: under the tabs in vertical view, " +
			"at the right in horizontal view.",
	},
	{
		"status.board",
		"Status Board",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, board),
		"true",
		0,
		0,
		nil,
		"Allow the full-window board of program status, opened with Ctrl+Shift+O.",
	},
	{
		"status.taskbar",
		"Taskbar Progress",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, taskbar),
		"true",
		0,
		0,
		nil,
		"Show progress, blocked and failed work on the window's taskbar button.",
	},
	{
		"status.show_working",
		"Show Working",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, show_working),
		"true",
		0,
		0,
		nil,
		"Show programs that are working.",
	},
	{
		"status.show_blocked",
		"Show Blocked",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, show_blocked),
		"true",
		0,
		0,
		nil,
		"Show programs waiting for permission, an answer or a sign-in.",
	},
	{
		"status.show_done",
		"Show Done",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, show_done),
		"true",
		0,
		0,
		nil,
		"Show programs that finished work for you to look at.",
	},
	{
		"status.show_error",
		"Show Errors",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, show_error),
		"true",
		0,
		0,
		nil,
		"Show programs that failed and stopped.",
	},
	{
		"status.show_idle",
		"Show Idle",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, show_idle),
		"false",
		0,
		0,
		nil,
		"Show programs waiting at their own prompt.",
	},
	{
		"status.notify_blocked",
		"Notify When Blocked",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, notify_blocked),
		"true",
		0,
		0,
		nil,
		"Show a notice and flash the window when a program needs you.",
	},
	{
		"status.notify_error",
		"Notify on Errors",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, notify_error),
		"true",
		0,
		0,
		nil,
		"Show a notice and flash the window when a program fails.",
	},
	{
		"status.notify_done",
		"Notify When Done",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, notify_done),
		"false",
		0,
		0,
		nil,
		"Show a notice and flash the window when a program finishes.",
	},
	{
		"status.notify_focused",
		"Notify While Watching",
		.Bool,
		offset_of(Settings, status) + offset_of(Status_Settings, notify_focused),
		"false",
		0,
		0,
		nil,
		"Also notify about the pane you are looking at.",
	},
	{
		"status.scope",
		"Status Overview Scope",
		.Enum,
		offset_of(Settings, status) + offset_of(Status_Settings, scope),
		"all",
		0,
		0,
		{"all", "workspace"},
		"Whether the inbox, panel and board list every workspace or only the window's workspace.",
	},
	{
		"status.keep_finished",
		"Keep Finished Status",
		.Enum,
		offset_of(Settings, status) + offset_of(Status_Settings, keep_finished),
		"focus",
		0,
		0,
		{"focus", "dismiss"},
		"Remove done and error status once you leave the pane you looked at, or keep it until you dismiss it.",
	},
	{
		"status.ignore_apps",
		"Ignore Status From",
		.String,
		offset_of(Settings, status) + offset_of(Status_Settings, ignore_apps),
		"",
		0,
		256,
		nil,
		"Comma-separated program names, the OSC 7501 app key such as vite or cargo, whose status is never shown.",
	},
	{
		"shell.default_profile",
		"Default Shell Profile",
		.String,
		offset_of(Settings, shell) + offset_of(Shell_Settings, default_profile),
		"default",
		1,
		64,
		nil,
		"Profile for new tabs, splits and the plus button. Profiles are ordered by profile.order.",
	},
	{
		"input.leader",
		"Leader Key",
		.String,
		offset_of(Settings, input) + offset_of(Input_Settings, leader),
		"",
		0,
		128,
		nil,
		"Optional leader chord, for example Ctrl+B; use Leader+T in a command shortcut. Empty disables it.",
	},
	{
		"font.family",
		"Font Family",
		.String,
		offset_of(Settings, font) + offset_of(Font_Settings, family),
		"Cascadia Mono",
		1,
		256,
		nil,
		"Terminal font family.",
	},
	{
		"interface.font_size",
		"GUI Font Size",
		.Float,
		offset_of(Settings, interface) + offset_of(Interface_Settings, font_size),
		"9",
		6,
		14,
		nil,
		"Interface text size in points; independent of the terminal font.",
	},
	{
		"interface.hover_lift",
		"Hover Lift",
		.Float,
		offset_of(Settings, interface) + offset_of(Interface_Settings, hover_lift),
		"1.5",
		0,
		4,
		nil,
		"How far interactive controls rise on hover, in DIPs. Zero disables the lift.",
	},
	{
		"interface.hover_gloss",
		"Hover Gloss",
		.Float,
		offset_of(Settings, interface) + offset_of(Interface_Settings, hover_gloss),
		"1",
		0,
		2,
		nil,
		"Strength of the pointer-following rim light on hovered controls. One is the designed " +
			"strength; zero disables it.",
	},
	{
		"font.size",
		"Font Size",
		.Float,
		offset_of(Settings, font) + offset_of(Font_Settings, size),
		"12",
		1,
		200,
		nil,
		"Font size in points.",
	},
	{
		"font.line_height",
		"Line Height",
		.Float,
		offset_of(Settings, font) + offset_of(Font_Settings, line_height),
		"1.0",
		0.5,
		4,
		nil,
		"Line height multiplier.",
	},
	{
		"shell.refresh_environment",
		"Refresh Shell Environment",
		.Bool,
		offset_of(Settings, shell) + offset_of(Shell_Settings, refresh_environment),
		"true",
		0,
		0,
		nil,
		"Read current Windows environment variables for new and restarted shells; keep launcher-only variables.",
	},
	{
		"shell.report_directory",
		"Report PowerShell Directory",
		.Bool,
		offset_of(Settings, shell) + offset_of(Shell_Settings, report_directory),
		"false",
		0,
		0,
		nil,
		"Wrap the interactive PowerShell prompt to report its directory. Applies to new and restarted shells.",
	},
	{
		"window.columns",
		"Initial Columns",
		.Int,
		offset_of(Settings, window) + offset_of(Window_Settings, columns),
		"120",
		1,
		32767,
		nil,
		"Initial terminal columns.",
	},
	{
		"window.rows",
		"Initial Rows",
		.Int,
		offset_of(Settings, window) + offset_of(Window_Settings, rows),
		"32",
		1,
		32767,
		nil,
		"Initial terminal rows.",
	},
	{
		"window.padding",
		"Content Padding",
		.Int,
		offset_of(Settings, window) + offset_of(Window_Settings, padding),
		"8",
		0,
		1024,
		nil,
		"Terminal content inset inside each pane card in DIPs; outer spacing follows pane.gap.",
	},
	{
		PADDING_GROUPS_KEY,
		"Process Padding Groups",
		.String,
		offset_of(Settings, process) + offset_of(Process_Settings, padding_groups),
		"",
		0,
		4096,
		nil,
		"Named groups: " + PADDING_GROUPS_EXAMPLE + ". First match wins; " +
			"other processes use Content Padding.",
	},
	{
		"scrollback.lines",
		"Scrollback Lines",
		.Int,
		offset_of(Settings, scrollback) + offset_of(Scrollback_Settings, lines),
		"10000",
		0,
		10000000,
		nil,
		"Scrollback lines to keep; history is freed in blocks, so the count kept varies by a few hundred.",
	},
	{
		"terminal.copy_on_select",
		"Copy on Select",
		.Bool,
		offset_of(Settings, terminal) + offset_of(Terminal_Settings, copy_on_select),
		"false",
		0,
		0,
		nil,
		"Copy selected text automatically; otherwise Ctrl+Shift+C copies it.",
	},
	{
		"terminal.confirm_multiline_paste",
		"Confirm Multiline Paste",
		.Bool,
		offset_of(Settings, terminal) + offset_of(Terminal_Settings, confirm_multiline_paste),
		"true",
		0,
		0,
		nil,
		"Ask before pasting line breaks the shell would run as separate commands.",
	},
	{
		"terminal.minimum_contrast",
		"Minimum Text Contrast",
		.Float,
		offset_of(Settings, terminal) + offset_of(Terminal_Settings, minimum_contrast),
		"4.5",
		1,
		21,
		nil,
		"Minimum text contrast in light themes, including application colors. " +
			"One preserves exact colors; dark themes stay unchanged.",
	},
	{
		"cursor.style",
		"Cursor Style",
		.Enum,
		offset_of(Settings, cursor) + offset_of(Cursor_Settings, style),
		"block",
		0,
		0,
		{"block", "bar", "underline"},
		"Cursor shape: block, bar, or underline.",
	},
	{
		"cursor.blink",
		"Cursor Blink",
		.Bool,
		offset_of(Settings, cursor) + offset_of(Cursor_Settings, blink),
		"false",
		0,
		0,
		nil,
		"Blink the cursor.",
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
	limits := fmt.bprintf(buffer[:], "%g..%g", entry.minimum, entry.maximum)
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

@(private, require_results)
assign :: proc(
	s: ^Settings,
	entry: Schema_Entry,
	input: string,
) -> (
	Maybe(Problem),
	runtime.Allocator_Error,
) {
	value := input
	if !utf8.valid_string(value) || strings.contains(value, "\x00") {
		return problem(.Invalid_Value, s.allocator, "expected UTF-8 text without NUL bytes")
	}
	if len(value) > 0 && value[0] == '"' {
		if len(value) < 2 || value[len(value) - 1] != '"' {
			return problem(.Invalid_Value, s.allocator, "expected a closing double quote")
		}
		value = value[1:len(value) - 1]
	}
	p := rawptr(uintptr(s) + entry.offset)
	switch entry.kind {
	case .String:
		if entry.key == PADDING_GROUPS_KEY && !padding_groups_valid(value) {
			buffer: [192]u8
			return problem(.Invalid_Value, s.allocator, padding_groups_rules(buffer[:]))
		}
		if f64(len(value)) < entry.minimum || f64(len(value)) > entry.maximum {
			return range_problem(entry, value, s.allocator)
		}
		copy, err := strings.clone(value, s.allocator)
		if err != nil {return nil, err}
		v := cast(^string)p
		delete(v^, s.allocator)
		v^ = copy
	case .Int:
		v, ok := strconv.parse_int(value, 10)
		if !ok {
			return problem(
				.Invalid_Value,
				s.allocator,
				"invalid integer \"",
				value,
				"\", expected a decimal integer",
			)
		}
		if f64(v) < entry.minimum || f64(v) > entry.maximum {
			return range_problem(entry, value, s.allocator)
		}
		(cast(^int)p)^ = v
	case .Float:
		v, ok := strconv.parse_f64(value)
		if !ok {
			return problem(
				.Invalid_Value,
				s.allocator,
				"invalid number \"",
				value,
				"\", expected a number",
			)
		}
		if !(v >= entry.minimum && v <= entry.maximum) {
			return range_problem(entry, value, s.allocator)
		}
		(cast(^f64)p)^ = v
	case .Bool:
		if value != "true" && value != "false" {
			return problem(
				.Invalid_Value,
				s.allocator,
				"invalid boolean \"",
				value,
				"\", expected true or false",
			)
		}
		(cast(^bool)p)^ = value == "true"
	case .Enum:
		for name, i in entry.enum_names {
			if name == value {
				(cast(^int)p)^ = i
				return nil, nil
			}
		}
		names, err := strings.join(entry.enum_names, ", ", s.allocator)
		if err != nil {return nil, err}
		defer delete(names, s.allocator)
		return problem(.Invalid_Value, s.allocator, "\"", value, "\" is not one of ", names)
	}
	return nil, nil
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
	legacy_error: runtime.Allocator_Error
	s.shell.command, legacy_error = strings.clone(DEFAULT_PROFILE_COMMAND, allocator)
	if legacy_error != nil {
		destroy(&s)
		return {}, legacy_error
	}
	s.shell.directory, legacy_error = strings.clone(DEFAULT_PROFILE_DIRECTORY, allocator)
	if legacy_error != nil {
		destroy(&s)
		return {}, legacy_error
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
	delete(s.shell.command, s.allocator)
	delete(s.shell.directory, s.allocator)
	delete(s.shell.icon, s.allocator)
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
) -> runtime.Allocator_Error {
	issue, err := problem(kind, out.allocator, message)
	if err != nil {return err}
	return add_diagnostic(out, line, key, issue.(Problem))
}

@(private, require_results)
add_diagnostic :: proc(
	out: ^[dynamic]Diagnostic,
	line: int,
	key: string,
	issue: Problem,
) -> runtime.Allocator_Error {
	copy, err := strings.clone(key, out.allocator)
	if err != nil {
		delete(issue.message, out.allocator)
		return err
	}
	_, err = append(out, Diagnostic{line, copy, issue.message, issue.kind})
	if err != nil {
		delete(copy, out.allocator)
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
		issue, issue_error := problem(
			.Duplicate_Key,
			allocator,
			"duplicate key \"",
			key,
			"\"; last value wins",
		)
		if issue_error != nil {return issue_error}
		err := add_diagnostic(diagnostics, line_number, key, issue.(Problem))
		if err != nil {return err}
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

@(require_results)
parse :: proc(
	text: string,
	allocator := context.allocator,
	themes_directory: string = "",
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
	seen: [len(SCHEMA)]bool
	legacy_seen: [3]bool
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
		if slot, legacy := legacy_shell_slot(key); legacy {
			entry := legacy_shell_entry(slot)
			if legacy_seen[slot] {
				issue, issue_error := problem(
					.Duplicate_Key,
					allocator,
					"duplicate key \"",
					key,
					"\"; last value wins",
				)
				if issue_error != nil {return {}, {}, issue_error}
				err = add_diagnostic(&diagnostics, line.number, key, issue.(Problem))
				if err != nil {return {}, {}, err}
			}
			legacy_seen[slot] = true
			issue, assign_error := assign(&s, entry, value)
			if assign_error != nil {return {}, {}, assign_error}
			if p, present := issue.?; present {
				err = add_diagnostic(&diagnostics, line.number, key, p)
				if err != nil {return {}, {}, err}
				reset_issue, reset_error := assign(&s, entry, entry.default_value)
				if reset_error != nil {return {}, {}, reset_error}
				assert(reset_issue == nil)
			}
			continue
		}
		index := -1
		for entry, i in SCHEMA {
			if entry.key == key {
				index = i
				break
			}
		}
		if index < 0 || seen[index] {
			kind := Diagnostic_Kind.Unknown_Key
			parts := []string{"unknown key \"", key, "\"; expected a key from the settings schema"}
			if index >= 0 {
				kind = .Duplicate_Key
				parts = {"duplicate key \"", key, "\"; last value wins"}
			}
			issue, issue_error := problem(kind, allocator, ..parts)
			if issue_error != nil {return {}, {}, issue_error}
			err = add_diagnostic(&diagnostics, line.number, key, issue.(Problem))
			if err != nil {return {}, {}, err}
			if index < 0 {continue}
		}
		seen[index] = true
		if key == "input.leader" {s.leader_line = line.number}
		if key == "shell.default_profile" {s.default_profile_line = line.number}
		if key == "theme.name" {s.theme_line = line.number}
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
	if profile_error := profiles_finalize(&s); profile_error != nil {return {}, {}, profile_error}
	if themes_directory != "" {
		if file_error := theme_files_load(&s, &diagnostics, themes_directory);
		   file_error != nil {return {}, {}, file_error}
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

@(require_results)
load :: proc(
	path: string,
	allocator := context.allocator,
	extra_comments: []string = nil,
	themes_directory: string = "",
) -> (
	s: Settings,
	diagnostics: [dynamic]Diagnostic,
	created: bool,
	migrated: bool,
	migration_error: Save_Error,
	err: os.Error,
) {
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
		s, diagnostics, parse_error = parse(text, allocator, themes_directory)
		if parse_error != nil {err = parse_error}
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
	s, diagnostics, default_error = parse(text, allocator, themes_directory)
	if default_error != nil {
		err = default_error
		return
	}
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

@(require_results)
expand_home :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
	if path != "~" && !strings.has_prefix(path, "~/") && !strings.has_prefix(path, "~\\") {
		copy, err := strings.clone(path, allocator)
		if err != nil {
			return "", err
		}
		return copy, nil
	}
	home, err := os.user_home_dir(allocator)
	if err != nil {
		return "", err
	}
	defer delete(home, allocator)
	result, copy_error := strings.concatenate({home, path[1:]}, allocator)
	if copy_error != nil {
		return "", copy_error
	}
	return result, nil
}
