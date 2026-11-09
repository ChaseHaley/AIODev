package commands

import "aio:layout"
import "core:encoding/json"
import "core:fmt"
import "core:path/filepath"
import "core:strings"

// The largest layout file layout.apply reads, in bytes.
LAYOUT_FILE_SIZE_MAX :: 1 << 20

// The most panes one layout may open. Building a run of n panes gives each new pane the share of the
// panes still to come, at most (n - 1) / n, which must stay within layout's split share range.
LAYOUT_PANES_MAX :: 16
#assert(f32(LAYOUT_PANES_MAX - 1) / f32(LAYOUT_PANES_MAX) <= layout.SPLIT_SHARE_MAX)

// A tab of panes as a layout file describes it: columns left to right, each column's panes top to
// bottom. Empty strings take what a new tab would use.
Layout_File :: struct {
	tab:     string,
	columns: [][]Layout_Pane,
}

// One pane of a layout. The program line is joined from the file's argument array; the directory is
// absolute.
Layout_Pane :: struct {
	name, program, directory, profile: string,
}

// Where a layout file is wrong, such as `columns[1][0].command`, and what to do about it.
Layout_Error :: struct {
	field, advice: string,
}

// Reads a layout file:
//
//	{"tab": "Review", "cwd": "D:\\work", "columns": [[{"name": "A1", "command": ["claude.exe"]}], [{}]]}
//
// Every key is optional except columns. A pane takes name, command (the program, then its arguments),
// cwd and profile. A relative top-level cwd is relative to `base`, the directory holding the file;
// without one, the layout's cwd is `caller`, the requester's working directory, or none when empty. A
// pane's relative cwd is relative to the layout's. Everything, the result included, is allocated with
// allocator, which the caller frees whole.
@(require_results)
layout_file_parse :: proc(
	data: []u8,
	base, caller: string,
	allocator := context.allocator,
) -> (
	result: Layout_File,
	failure: Maybe(Layout_Error),
) {
	context.allocator = allocator
	// Windows PowerShell 5.1 writes UTF-8 files with a byte order mark.
	text := strings.trim_prefix(string(data), "\uFEFF")
	parser := json.make_parser(text, .JSON, false, allocator)
	root, parse_error := json.parse_value(&parser)
	if parse_error == .None && parser.curr_token.kind != .EOF {parse_error = .Unexpected_Token}
	if parse_error != .None {
		at := parser.curr_token.pos
		return {}, Layout_Error{"", fmt.aprintf("not valid JSON at line %d, column %d", at.line, at.column)}
	}
	object, is_object := root.(json.Object)
	if !is_object {return {}, Layout_Error{"", "the file must hold one JSON object"}}
	directory := caller
	columns: json.Array
	have_columns := false
	for key, value in object {
		switch key {
		case "tab":
			result.tab = layout_text(value, key) or_return
		case "cwd":
			directory = layout_text(value, key) or_return
			if !filepath.is_abs(directory) && base != "" {
				directory = layout_join(base, directory, key) or_return
			}
		case "columns":
			array, is_array := value.(json.Array)
			if !is_array {return {}, Layout_Error{key, "use an array of columns, each an array of panes"}}
			columns, have_columns = array, true
		case:
			return {}, Layout_Error{key, "unknown key; a layout takes tab, cwd and columns"}
		}
	}
	if !have_columns || len(columns) == 0 {
		return {}, Layout_Error{"columns", "list at least one column of panes"}
	}
	result.columns = make([][]Layout_Pane, len(columns))
	count := 0
	for column_value, c in columns {
		field := fmt.aprintf("columns[%d]", c)
		column, is_array := column_value.(json.Array)
		if !is_array {return {}, Layout_Error{field, "use an array of panes"}}
		if len(column) == 0 {return {}, Layout_Error{field, "list at least one pane"}}
		count += len(column)
		if count > LAYOUT_PANES_MAX {
			return {}, Layout_Error{"columns", fmt.aprintf("use at most %d panes", LAYOUT_PANES_MAX)}
		}
		result.columns[c] = make([]Layout_Pane, len(column))
		for pane, r in column {
			result.columns[c][r] = layout_pane(pane, fmt.aprintf("%s[%d]", field, r), directory) or_return
		}
	}
	return result, nil
}

@(private = "file", require_results)
layout_pane :: proc(
	value: json.Value,
	field, directory: string,
) -> (
	pane: Layout_Pane,
	failure: Maybe(Layout_Error),
) {
	object, is_object := value.(json.Object)
	if !is_object {return {}, Layout_Error{field, "use an object with name, command, cwd and profile"}}
	pane.directory = directory
	for key, item in object {
		at := fmt.aprintf("%s.%s", field, key)
		switch key {
		case "name":
			pane.name = layout_text(item, at) or_return
		case "profile":
			pane.profile = layout_text(item, at) or_return
		case "cwd":
			given := layout_text(item, at) or_return
			if filepath.is_abs(given) {
				pane.directory = given
			} else if directory != "" {
				pane.directory = layout_join(directory, given, at) or_return
			} else {
				return {}, Layout_Error{at, "a relative cwd needs the layout's cwd; give one, or an absolute path"}
			}
		case "command":
			pane.program = layout_command(item, at) or_return
		case:
			return {}, Layout_Error{at, "unknown key; a pane takes name, command, cwd and profile"}
		}
	}
	return pane, nil
}

// The program line for an argument array: the program, then its arguments, quoted so that
// CommandLineToArgvW splits them back unchanged.
@(private = "file", require_results)
layout_command :: proc(value: json.Value, field: string) -> (string, Maybe(Layout_Error)) {
	items, is_array := value.(json.Array)
	if !is_array || len(items) == 0 {
		return "", Layout_Error{field, "use an array of strings: the program, then its arguments"}
	}
	args := make([]string, len(items))
	for item, i in items {
		text, is_text := item.(json.String)
		if !is_text {return "", Layout_Error{fmt.aprintf("%s[%d]", field, i), "use a string"}}
		args[i] = string(text)
	}
	if args[0] == "" {return "", Layout_Error{fmt.aprintf("%s[0]", field), "name a program"}}
	line, err := command_line_join(args)
	if err != nil {return "", Layout_Error{field, "not enough memory for the program line"}}
	return line, nil
}

@(private = "file", require_results)
layout_text :: proc(value: json.Value, field: string) -> (string, Maybe(Layout_Error)) {
	text, is_text := value.(json.String)
	if !is_text || text == "" {return "", Layout_Error{field, "use a nonempty string"}}
	return string(text), nil
}

@(private = "file", require_results)
layout_join :: proc(directory, path, field: string) -> (string, Maybe(Layout_Error)) {
	joined, err := filepath.join({directory, path})
	if err != nil {return "", Layout_Error{field, "not enough memory for the path"}}
	return joined, nil
}
