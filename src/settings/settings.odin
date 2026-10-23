package settings

import "aio:colour"
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
	colors:          Color_Settings,
	color_overrides: Color_Overrides,
	theme:           Theme_Settings,
	pane:            Pane_Settings,
	tab:             Tab_Settings,
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
	Color,
	Optional_Color,
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
		.Enum,
		offset_of(Settings, theme) + offset_of(Theme_Settings, name),
		"studio",
		0,
		0,
		{"studio", "tide", "ember"},
		"Color theme: studio, tide, or ember.",
	},
	{
		"theme.mode",
		"Theme Mode",
		.Enum,
		offset_of(Settings, theme) + offset_of(Theme_Settings, mode),
		"dark",
		0,
		0,
		{"dark", "light"},
		"Color theme mode: dark or light.",
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
	{
		key = COLOR_ENTRIES[0].key,
		title = COLOR_ENTRIES[0].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[0].override_offset,
		description = COLOR_ENTRIES[0].description,
	},
	{
		key = COLOR_ENTRIES[1].key,
		title = COLOR_ENTRIES[1].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[1].override_offset,
		description = COLOR_ENTRIES[1].description,
	},
	{
		key = COLOR_ENTRIES[2].key,
		title = COLOR_ENTRIES[2].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[2].override_offset,
		description = COLOR_ENTRIES[2].description,
	},
	{
		key = COLOR_ENTRIES[3].key,
		title = COLOR_ENTRIES[3].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[3].override_offset,
		description = COLOR_ENTRIES[3].description,
	},
	{
		key = COLOR_ENTRIES[4].key,
		title = COLOR_ENTRIES[4].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[4].override_offset,
		description = COLOR_ENTRIES[4].description,
	},
	{
		key = COLOR_ENTRIES[5].key,
		title = COLOR_ENTRIES[5].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[5].override_offset,
		description = COLOR_ENTRIES[5].description,
	},
	{
		key = COLOR_ENTRIES[6].key,
		title = COLOR_ENTRIES[6].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[6].override_offset,
		description = COLOR_ENTRIES[6].description,
	},
	{
		key = COLOR_ENTRIES[7].key,
		title = COLOR_ENTRIES[7].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[7].override_offset,
		description = COLOR_ENTRIES[7].description,
	},
	{
		key = COLOR_ENTRIES[8].key,
		title = COLOR_ENTRIES[8].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[8].override_offset,
		description = COLOR_ENTRIES[8].description,
	},
	{
		key = COLOR_ENTRIES[9].key,
		title = COLOR_ENTRIES[9].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[9].override_offset,
		description = COLOR_ENTRIES[9].description,
	},
	{
		key = COLOR_ENTRIES[10].key,
		title = COLOR_ENTRIES[10].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[10].override_offset,
		description = COLOR_ENTRIES[10].description,
	},
	{
		key = COLOR_ENTRIES[11].key,
		title = COLOR_ENTRIES[11].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[11].override_offset,
		description = COLOR_ENTRIES[11].description,
	},
	{
		key = COLOR_ENTRIES[12].key,
		title = COLOR_ENTRIES[12].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[12].override_offset,
		description = COLOR_ENTRIES[12].description,
	},
	{
		key = COLOR_ENTRIES[13].key,
		title = COLOR_ENTRIES[13].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[13].override_offset,
		description = COLOR_ENTRIES[13].description,
	},
	{
		key = COLOR_ENTRIES[14].key,
		title = COLOR_ENTRIES[14].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[14].override_offset,
		description = COLOR_ENTRIES[14].description,
	},
	{
		key = COLOR_ENTRIES[15].key,
		title = COLOR_ENTRIES[15].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[15].override_offset,
		description = COLOR_ENTRIES[15].description,
	},
	{
		key = COLOR_ENTRIES[16].key,
		title = COLOR_ENTRIES[16].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[16].override_offset,
		description = COLOR_ENTRIES[16].description,
	},
	{
		key = COLOR_ENTRIES[17].key,
		title = COLOR_ENTRIES[17].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[17].override_offset,
		description = COLOR_ENTRIES[17].description,
	},
	{
		key = COLOR_ENTRIES[18].key,
		title = COLOR_ENTRIES[18].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[18].override_offset,
		description = COLOR_ENTRIES[18].description,
	},
	{
		key = COLOR_ENTRIES[19].key,
		title = COLOR_ENTRIES[19].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[19].override_offset,
		description = COLOR_ENTRIES[19].description,
	},
	{
		key = COLOR_ENTRIES[20].key,
		title = COLOR_ENTRIES[20].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[20].override_offset,
		description = COLOR_ENTRIES[20].description,
	},
	{
		key = COLOR_ENTRIES[21].key,
		title = COLOR_ENTRIES[21].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[21].override_offset,
		description = COLOR_ENTRIES[21].description,
	},
	{
		key = COLOR_ENTRIES[22].key,
		title = COLOR_ENTRIES[22].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[22].override_offset,
		description = COLOR_ENTRIES[22].description,
	},
	{
		key = COLOR_ENTRIES[23].key,
		title = COLOR_ENTRIES[23].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[23].override_offset,
		description = COLOR_ENTRIES[23].description,
	},
	{
		key = COLOR_ENTRIES[24].key,
		title = COLOR_ENTRIES[24].title,
		kind = .Optional_Color,
		offset = offset_of(Settings, color_overrides) + COLOR_ENTRIES[24].override_offset,
		description = COLOR_ENTRIES[24].description,
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
	case .Color, .Optional_Color:
		if entry.kind == .Optional_Color && value == "" {
			(cast(^Maybe(Color))p)^ = nil
			return nil, nil
		}
		color, valid, _ := colour.parse(value, .Strict)
		if !valid {
			return problem(
				.Invalid_Value,
				s.allocator,
				"invalid color \"",
				value,
				"\", expected #rrggbb",
			)
		}
		if entry.kind == .Color {
			(cast(^Color)p)^ = color
		} else {
			(cast(^Maybe(Color))p)^ = color
		}
	}
	return nil, nil
}

@(require_results)
defaults :: proc(allocator := context.allocator) -> (Settings, runtime.Allocator_Error) {
	s := Settings {
		allocator = allocator,
	}
	s.keys.allocator = allocator
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
	resolve_colors(&s)
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
	resolve_colors(&s)
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
		"\"\n",
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
		parse_error: runtime.Allocator_Error
		s, diagnostics, parse_error = parse(string(data), allocator)
		if parse_error != nil {
			err = parse_error
			return
		}
		updated, changed, migration_alloc := migrate_text(string(data), allocator)
		if migration_alloc != nil {
			destroy(&s)
			diagnostics_destroy(&diagnostics)
			err = migration_alloc
			return
		}
		if changed {
			defer delete(updated, allocator)
			switch save(path, string(data), updated) {
			case .None:
				migrated = true
			case .Conflict:
				migration_error = .Conflict
			case .IO:
				migration_error = .IO
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
	s, default_error = defaults(allocator)
	if default_error != nil {
		err = default_error
		return
	}
	created = true
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
