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
	family: string,
	size, line_height: f64,
}
Shell_Settings :: struct {
	command, directory, icon: string,
}
Input_Settings :: struct { leader: string }
Window_Settings :: struct {
	columns, rows, padding: int,
	show_tab_bar_with_one_tab: bool,
}
Scrollback_Settings :: struct {
	lines: int,
}
Terminal_Settings :: struct {
	copy_on_select, confirm_multiline_paste: bool,
}
Cursor_Settings :: struct {
	style: Cursor_Style,
	blink: bool,
}
Color_Settings :: struct {
	foreground, background, cursor, cursor_text, selection_background: Color,
	selection_foreground: Maybe(Color),
	search_foreground, search_background, search_selected_background: Color,
	palette: [16]Color,
}
Settings :: struct {
	keys: [dynamic]Key_Binding,
	font: Font_Settings,
	shell: Shell_Settings,
	input: Input_Settings,
	window: Window_Settings,
	scrollback: Scrollback_Settings,
	terminal: Terminal_Settings,
	cursor: Cursor_Settings,
	colors: Color_Settings,
	color_overrides: Color_Overrides,
	theme: Theme_Settings,
	pane: Pane_Settings,
	allocator: runtime.Allocator,
	leader_line: int,
}
KEY_BINDING_PREFIX :: "keys."
Key_Binding :: struct { name, value: string, line: int }
Kind :: enum { String, Int, Float, Bool, Color, Optional_Color, Enum }
Schema_Entry :: struct {
	key, title: string,
	kind: Kind,
	offset: uintptr,
	default_value: string,
	minimum, maximum: f64,
	enum_names: []string,
	description: string,
}
SCHEMA :: [?]Schema_Entry{
	{"theme.name", "Theme", .Enum, offset_of(Settings, theme) + offset_of(Theme_Settings, name), "studio", 0, 0, {"studio", "tide", "ember"}, "Color theme: studio, tide, or ember."},
	{"theme.mode", "Theme Mode", .Enum, offset_of(Settings, theme) + offset_of(Theme_Settings, mode), "dark", 0, 0, {"dark", "light"}, "Color theme mode: dark or light."},
	{"pane.gap", "Pane Gap", .Int, offset_of(Settings, pane) + offset_of(Pane_Settings, gap), "5", 0, 24, nil, "Space between and around pane cards in DIPs."},
	{"pane.corner_radius", "Pane Corner Radius", .Int, offset_of(Settings, pane) + offset_of(Pane_Settings, corner_radius), "7", 0, 16, nil, "Pane card corner radius in DIPs."},
	{"pane.show_headers", "Show Pane Headers", .Bool, offset_of(Settings, pane) + offset_of(Pane_Settings, show_headers), "true", 0, 0, nil, "Show pane headers when a tab has multiple panes."},
	{"shell.icon", "Shell Badge", .String, offset_of(Settings, shell) + offset_of(Shell_Settings, icon), "", 0, 16, nil, "Shell badge text; empty chooses the shell default."},
	{"input.leader", "Leader Key", .String, offset_of(Settings, input) + offset_of(Input_Settings, leader), "", 0, 128, nil, "Optional leader chord, for example Ctrl+B; use Leader+T in a command shortcut. Empty disables it."},
	{"font.family", "Font Family", .String, offset_of(Settings, font) + offset_of(Font_Settings, family), "Cascadia Mono", 1, 256, nil, "Terminal font family."},
	{"font.size", "Font Size", .Float, offset_of(Settings, font) + offset_of(Font_Settings, size), "12", 1, 200, nil, "Font size in points."},
	{"font.line_height", "Line Height", .Float, offset_of(Settings, font) + offset_of(Font_Settings, line_height), "1.0", 0.5, 4, nil, "Line height multiplier."},
	{"shell.command", "Shell Command", .String, offset_of(Settings, shell) + offset_of(Shell_Settings, command), "pwsh.exe -NoLogo", 1, 32767, nil, "Shell command line."},
	{"shell.directory", "Starting Directory", .String, offset_of(Settings, shell) + offset_of(Shell_Settings, directory), "~", 1, 32767, nil, "Initial directory; the caller expands the home prefix."},
	{"window.columns", "Initial Columns", .Int, offset_of(Settings, window) + offset_of(Window_Settings, columns), "120", 1, 32767, nil, "Initial terminal columns."},
	{"window.rows", "Initial Rows", .Int, offset_of(Settings, window) + offset_of(Window_Settings, rows), "32", 1, 32767, nil, "Initial terminal rows."},
	{"window.padding", "Content Padding", .Int, offset_of(Settings, window) + offset_of(Window_Settings, padding), "8", 0, 1024, nil, "Terminal content inset inside each pane card in DIPs; outer spacing follows pane.gap."},
	{"window.show_tab_bar_with_one_tab", "Show Tab Bar With One Tab", .Bool, offset_of(Settings, window) + offset_of(Window_Settings, show_tab_bar_with_one_tab), "true", 0, 0, nil, "Show the tab bar even with only one tab."},
	{"scrollback.lines", "Scrollback Lines", .Int, offset_of(Settings, scrollback) + offset_of(Scrollback_Settings, lines), "10000", 0, 10000000, nil, "Scrollback lines to keep; history is freed in blocks, so the count kept varies by a few hundred."},
	{"terminal.copy_on_select", "Copy on Select", .Bool, offset_of(Settings, terminal) + offset_of(Terminal_Settings, copy_on_select), "false", 0, 0, nil, "Copy selected text automatically; otherwise Ctrl+Shift+C copies it."},
	{"terminal.confirm_multiline_paste", "Confirm Multiline Paste", .Bool, offset_of(Settings, terminal) + offset_of(Terminal_Settings, confirm_multiline_paste), "true", 0, 0, nil, "Ask before pasting line breaks the shell would run as separate commands."},
	{"cursor.style", "Cursor Style", .Enum, offset_of(Settings, cursor) + offset_of(Cursor_Settings, style), "block", 0, 0, {"block", "bar", "underline"}, "Cursor shape: block, bar, or underline."},
	{"cursor.blink", "Cursor Blink", .Bool, offset_of(Settings, cursor) + offset_of(Cursor_Settings, blink), "false", 0, 0, nil, "Blink the cursor."},
	{"colors.foreground", "Foreground Color", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, foreground), "", 0, 0, nil, "Default foreground color."},
	{"colors.background", "Background Color", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, background), "", 0, 0, nil, "Default background color."},
	{"colors.cursor", "Cursor Color", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, cursor), "", 0, 0, nil, "Cursor color."},
	{"colors.cursor_text", "Cursor Text Color", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, cursor_text), "", 0, 0, nil, "Text under the block cursor."},
	{"colors.selection_background", "Selection Background", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, selection_background), "", 0, 0, nil, "Selection background color."},
	{"colors.selection_foreground", "Selection Text Color", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, selection_foreground), "", 0, 0, nil, "Selection foreground; empty preserves the cell color."},
	{"colors.search_foreground", "Search Match Text Color", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, search_foreground), "", 0, 0, nil, "Text color of search matches."},
	{"colors.search_background", "Search Match Background", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, search_background), "", 0, 0, nil, "Background of search matches."},
	{"colors.search_selected_background", "Selected Match Background", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, search_selected_background), "", 0, 0, nil, "Background of the selected search match."},
	{"colors.palette.0", "ANSI Black", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 0 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 0."},
	{"colors.palette.1", "ANSI Red", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 1 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 1."},
	{"colors.palette.2", "ANSI Green", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 2 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 2."},
	{"colors.palette.3", "ANSI Yellow", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 3 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 3."},
	{"colors.palette.4", "ANSI Blue", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 4 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 4."},
	{"colors.palette.5", "ANSI Magenta", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 5 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 5."},
	{"colors.palette.6", "ANSI Cyan", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 6 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 6."},
	{"colors.palette.7", "ANSI White", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 7 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 7."},
	{"colors.palette.8", "ANSI Bright Black", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 8 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 8."},
	{"colors.palette.9", "ANSI Bright Red", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 9 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 9."},
	{"colors.palette.10", "ANSI Bright Green", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 10 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 10."},
	{"colors.palette.11", "ANSI Bright Yellow", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 11 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 11."},
	{"colors.palette.12", "ANSI Bright Blue", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 12 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 12."},
	{"colors.palette.13", "ANSI Bright Magenta", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 13 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 13."},
	{"colors.palette.14", "ANSI Bright Cyan", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 14 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 14."},
	{"colors.palette.15", "ANSI Bright White", .Optional_Color, offset_of(Settings, color_overrides) + offset_of(Color_Overrides, palette) + 15 * size_of(Maybe(Color)), "", 0, 0, nil, "ANSI palette color 15."},
}
Diagnostic_Kind :: enum { Unknown_Key, Malformed_Line, Invalid_Value, Out_Of_Range, Duplicate_Key, Shortcut_Warning }
Diagnostic :: struct {
	line: int,
	key, message: string,
	kind: Diagnostic_Kind,
}

@(private)
Problem :: struct {
	kind: Diagnostic_Kind,
	message: string,
}

@(private, require_results)
problem :: proc(
	kind: Diagnostic_Kind,
	allocator: runtime.Allocator,
	parts: ..string,
) -> (Maybe(Problem), runtime.Allocator_Error) {
	message, err := strings.concatenate(parts, allocator)
	if err != nil { return nil, err }
	return Problem{kind, message}, nil
}

@(private, require_results)
range_problem :: proc(
	entry: Schema_Entry,
	value: string,
	allocator: runtime.Allocator,
) -> (Maybe(Problem), runtime.Allocator_Error) {
	buffer: [128]u8
	limits := fmt.bprintf(buffer[:], "%g..%g", entry.minimum, entry.maximum)
	if entry.kind == .String {
		return problem(.Out_Of_Range, allocator, "string length is out of range ", limits, " UTF-8 bytes")
	}
	return problem(.Out_Of_Range, allocator, value, " is out of range ", limits)
}

@(private, require_results)
assign :: proc(
	s: ^Settings,
	entry: Schema_Entry,
	input: string,
) -> (Maybe(Problem), runtime.Allocator_Error) {
	value := input
	if !utf8.valid_string(value) || strings.contains(value, "\x00") {
		return problem(.Invalid_Value, s.allocator, "expected UTF-8 text without NUL bytes")
	}
	if len(value) > 0 && value[0] == '"' {
		if len(value) < 2 || value[len(value)-1] != '"' {
			return problem(.Invalid_Value, s.allocator, "expected a closing double quote")
		}
		value = value[1:len(value)-1]
	}
	p := rawptr(uintptr(s) + entry.offset)
	switch entry.kind {
	case .String:
		if f64(len(value)) < entry.minimum || f64(len(value)) > entry.maximum {
			return range_problem(entry, value, s.allocator)
		}
		copy, err := strings.clone(value, s.allocator)
		if err != nil { return nil, err }
		v := cast(^string)p
		delete(v^, s.allocator)
		v^ = copy
	case .Int:
		v, ok := strconv.parse_int(value, 10)
		if !ok {
			return problem(
				.Invalid_Value, s.allocator, "invalid integer \"", value, "\", expected a decimal integer",
			)
		}
		if f64(v) < entry.minimum || f64(v) > entry.maximum {
			return range_problem(entry, value, s.allocator)
		}
		(cast(^int)p)^ = v
	case .Float:
		v, ok := strconv.parse_f64(value)
		if !ok {
			return problem(.Invalid_Value, s.allocator, "invalid number \"", value, "\", expected a number")
		}
		if !(v >= entry.minimum && v <= entry.maximum) {
			return range_problem(entry, value, s.allocator)
		}
		(cast(^f64)p)^ = v
	case .Bool:
		if value != "true" && value != "false" {
			return problem(
				.Invalid_Value, s.allocator, "invalid boolean \"", value, "\", expected true or false",
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
		if err != nil { return nil, err }
		defer delete(names, s.allocator)
		return problem(.Invalid_Value, s.allocator, "\"", value, "\" is not one of ", names)
	case .Color, .Optional_Color:
		if entry.kind == .Optional_Color && value == "" {
			(cast(^Maybe(Color))p)^ = nil
			return nil, nil
		}
		valid := len(value) == 7 && value[0] == '#'
		color: Color
		if valid {
			for c, i in value[1:] {
				digit: u8
				switch {
				case c >= '0' && c <= '9': digit = u8(c - '0')
				case c >= 'a' && c <= 'f': digit = u8(c - 'a') + 10
				case c >= 'A' && c <= 'F': digit = u8(c - 'A') + 10
				case: valid = false
				}
				color[i/2] = color[i/2] * 16 + digit
			}
		}
		if !valid {
			return problem(.Invalid_Value, s.allocator, "invalid color \"", value, "\", expected #rrggbb")
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
	s := Settings{allocator = allocator}
	s.keys.allocator = allocator
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
	if err != nil { return err }
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
parse_key_binding :: proc(s: ^Settings, diagnostics: ^[dynamic]Diagnostic,
	key, value: string, line_number: int) -> runtime.Allocator_Error {
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
		issue, issue_error := problem(.Duplicate_Key, allocator, "duplicate key \"", key,
			"\"; last value wins")
		if issue_error != nil { return issue_error }
		err := add_diagnostic(diagnostics, line_number, key, issue.(Problem))
		if err != nil { return err }
	}
	name, name_error := strings.clone(binding_name, allocator)
	if name_error != nil { return name_error }
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
) -> (Settings, [dynamic]Diagnostic, runtime.Allocator_Error) {
	s, err := defaults(allocator)
	if err != nil { return {}, {}, err }
	diagnostics := make([dynamic]Diagnostic, allocator)
	success := false
	defer if !success {
		destroy(&s)
		diagnostics_destroy(&diagnostics)
	}
	schema := SCHEMA
	seen: [len(SCHEMA)]bool
	rest := strings.trim_prefix(text, "\xef\xbb\xbf")
	line_number := 0
	for raw_line in strings.split_lines_iterator(&rest) {
		line_number += 1
		line := strings.trim_space(raw_line)
		if line == "" || line[0] == '#' { continue }
		equal := strings.index_byte(line, '=')
		if equal < 0 {
			issue, issue_error := problem(.Malformed_Line, allocator, "expected \"key = value\"")
			if issue_error != nil { return {}, {}, issue_error }
			err = add_diagnostic(&diagnostics, line_number, line, issue.(Problem))
			if err != nil { return {}, {}, err }
			continue
		}
		key := strings.trim_space(line[:equal])
		value := strings.trim_space(line[equal+1:])
		if strings.has_prefix(key, KEY_BINDING_PREFIX) {
			binding_error := parse_key_binding(&s, &diagnostics, key, value, line_number)
			if binding_error != nil { return {}, {}, binding_error }
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
			if issue_error != nil { return {}, {}, issue_error }
			err = add_diagnostic(&diagnostics, line_number, key, issue.(Problem))
			if err != nil { return {}, {}, err }
			if index < 0 { continue }
		}
		seen[index] = true
		if key == "input.leader" { s.leader_line = line_number }
		issue, assign_error := assign(&s, schema[index], value)
		if assign_error != nil { return {}, {}, assign_error }
		if p, present := issue.?; present {
			err = add_diagnostic(&diagnostics, line_number, key, p)
			if err != nil { return {}, {}, err }
			default_issue, default_error := assign(&s, schema[index], schema[index].default_value)
			if default_error != nil { return {}, {}, default_error }
			assert(default_issue == nil)
		}
	}
	resolve_colors(&s)
	success = true
	return s, diagnostics, nil
}

@(private, require_results)
write_parts :: proc(b: ^strings.Builder, parts: ..string) -> runtime.Allocator_Error {
	for part in parts {
		if strings.write_string(b, part) != len(part) { return .Out_Of_Memory }
	}
	return nil
}

@(require_results)
default_text :: proc(
	allocator := context.allocator,
	extra_comments: []string = nil,
) -> (text: string, err: runtime.Allocator_Error) {
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
		if entry.kind == .String {
			write_parts(&builder, "\"") or_return
		}
		write_parts(&builder, entry.default_value) or_return
		if entry.kind == .String {
			write_parts(&builder, "\"") or_return
		}
		write_parts(&builder, "\n") or_return
	}
	if len(extra_comments) > 0 { write_parts(&builder, "\n") or_return }
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
) -> (s: Settings, diagnostics: [dynamic]Diagnostic, created: bool, err: os.Error) {
	data, read_error := os.read_entire_file(path, allocator)
	defer delete(data, allocator)
	if read_error == nil {
		parse_error: runtime.Allocator_Error
		s, diagnostics, parse_error = parse(string(data), allocator)
		if parse_error != nil {
			err = parse_error
		}
		return
	}
	if read_error != os.Error(os.General_Error.Not_Exist) {
		err = read_error
		return
	}
	err = os.mkdir_all(os.dir(path))
	if err != nil { return }
	text, text_error := default_text(allocator, extra_comments)
	if text_error != nil {
		err = text_error
		return
	}
	defer delete(text, allocator)
	err = os.write_entire_file(path, text)
	if err != nil { return }
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
