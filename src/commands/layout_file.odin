package commands

import "aio:layout"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:path/filepath"
import "core:strings"

// The largest layout file layout.apply reads, in bytes.
LAYOUT_FILE_SIZE_MAX :: 1 << 20

// The most panes one layout may open. Building a run of n panes gives each new pane the share of the
// panes still to come, at most (n - 1) / n, which must stay within layout's split share range.
LAYOUT_PANES_MAX :: 16
#assert(f32(LAYOUT_PANES_MAX - 1) / f32(LAYOUT_PANES_MAX) <= layout.SPLIT_SHARE_MAX)

// A tab described by either columns or a split tree, with optional floating panes.
// Empty strings take what a new tab would use.
Layout_File :: struct {
	tab:     string,
	columns: [][]Layout_Pane,
	root:    ^Layout_Node,
	floats:  []Layout_Float,
}

// One pane of a layout. The program line is joined from the file's argument array; the directory is
// absolute.
Layout_Pane :: struct {
	name, program, directory, profile: string,
}

// A leaf holds pane settings; a split gives ratio of its space to first, then the rest to second.
Layout_Node :: struct {
	pane:          Layout_Pane,
	split:         bool,
	direction:     layout.Direction,
	ratio:         f32,
	first, second: ^Layout_Node,
}

Layout_Float :: struct {
	pane:   Layout_Pane,
	bounds: layout.Rect,
	cells:  bool,
}

// Where a layout file is wrong, such as `columns[1][0].command`, and what to do about it.
Layout_Error :: struct {
	field, advice: string,
}

// Reads a layout file:
//
//	{"tab": "Review", "cwd": "D:\\work", "columns": [[{"name": "A1", "command": ["claude.exe"]}], [{}]]}
//
// Supply columns or root, never both. Root is a pane or {split: "right"|"down", ratio: 0.5, first,
// second}; ratio gives first its share. Floats take bounds [x, y, width, height], unit "share" (default)
// or "cells", and a pane. A pane takes name, command (the program, then its arguments), cwd and profile.
// A relative top-level cwd is relative to base, the file's directory; without one, cwd is caller, or
// none when empty. A pane's relative cwd is relative to the layout's. Everything, the result included,
// is allocated with allocator, which the caller frees whole.
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
	if len(data) > LAYOUT_FILE_SIZE_MAX {
		return {}, Layout_Error{"", fmt.aprintf("use at most %d bytes", LAYOUT_FILE_SIZE_MAX)}
	}
	failure = layout_json_depth(data)
	if failure != nil {return {}, failure}
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
	tree, floating: json.Value
	have_root, have_floats := false, false
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
		case "root":
			tree, have_root = value, true
		case "floats":
			floating, have_floats = value, true
		case:
			return {}, Layout_Error{key, "unknown key; a layout takes tab, cwd, columns, root and floats"}
		}
	}
	if have_root && have_columns {
		return {}, Layout_Error{"root", "use root or columns, not both"}
	}
	if !have_root && (!have_columns || len(columns) == 0) {
		return {}, Layout_Error{"columns", "list at least one column of panes, or supply root"}
	}
	count := 0
	if have_root {
		result.root = layout_node(tree, "root", directory, &count, 1) or_return
	} else {
		result.columns = make([][]Layout_Pane, len(columns))
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
				at := fmt.aprintf("%s[%d]", field, r)
				result.columns[c][r] = layout_pane(pane, at, directory) or_return
			}
		}
	}
	if have_floats {
		items, is_array := floating.(json.Array)
		if !is_array {return {}, Layout_Error{"floats", "use an array of floating panes"}}
		// Check the total before allocating an attacker-controlled array.
		if len(items) > LAYOUT_PANES_MAX - count {
			at := fmt.aprintf("floats[%d].pane", LAYOUT_PANES_MAX - count)
			return {}, Layout_Error{at, fmt.aprintf("use at most %d panes total", LAYOUT_PANES_MAX)}
		}
		result.floats = make([]Layout_Float, len(items))
		for item, i in items {
			at := fmt.aprintf("floats[%d]", i)
			result.floats[i] = layout_float(item, at, directory) or_return
		}
	}
	return result, nil
}

// Guard the JSON library's recursive descent too, including malformed input outside the tree grammar.
// A valid sixteen-pane tree needs at most eighteen nested containers, including a command array.
@(private = "file", require_results)
layout_json_depth :: proc(data: []u8) -> Maybe(Layout_Error) {
	depth := 0
	quoted, escaped := false, false
	for c in data {
		if quoted {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				quoted = false
			}
			continue
		}
		switch c {
		case '"':
			quoted = true
		case '{', '[':
			depth += 1
			if depth > 64 {return Layout_Error{"", "use at most 64 nested JSON objects or arrays"}}
		case '}', ']':
			depth = max(0, depth - 1)
		}
	}
	return nil
}

@(private = "file", require_results)
layout_node :: proc(
	value: json.Value,
	field, directory: string,
	count: ^int,
	depth: int,
) -> (
	result: ^Layout_Node,
	failure: Maybe(Layout_Error),
) {
	if depth > LAYOUT_PANES_MAX {
		return nil, Layout_Error{field, fmt.aprintf("use at most %d tree levels", LAYOUT_PANES_MAX)}
	}
	object, is_object := value.(json.Object)
	if !is_object {return nil, Layout_Error{field, "use a pane object or a split with first and second"}}
	split_value, is_split := object["split"]
	if !is_split {
		if count^ >= LAYOUT_PANES_MAX {
			return nil, Layout_Error{field, fmt.aprintf("use at most %d panes total", LAYOUT_PANES_MAX)}
		}
		pane := layout_pane(value, field, directory) or_return
		count^ += 1
		node := new(Layout_Node)
		node.pane = pane
		return node, nil
	}
	node := new(Layout_Node)
	node.split, node.ratio = true, 0.5
	direction, is_text := split_value.(json.String)
	if !is_text || (direction != "right" && direction != "down") {
		return nil, Layout_Error{fmt.aprintf("%s.split", field), "use right or down"}
	}
	node.direction = direction == "right" ? .Right : .Down
	for key, item in object {
		at := fmt.aprintf("%s.%s", field, key)
		switch key {
		case "split", "first", "second":
		case "ratio":
			node.ratio = layout_number(item, at) or_return
			if node.ratio < layout.SPLIT_SHARE_MIN || node.ratio > layout.SPLIT_SHARE_MAX {
				advice := fmt.aprintf("use a ratio from %g to %g", layout.SPLIT_SHARE_MIN,
					layout.SPLIT_SHARE_MAX)
				return nil, Layout_Error{at, advice}
			}
		case:
			return nil, Layout_Error{at, "unknown key; a split takes split, ratio, first and second"}
		}
	}
	first, have_first := object["first"]
	first_field := fmt.aprintf("%s.first", field)
	if !have_first {return nil, Layout_Error{first_field, "supply the first pane or split"}}
	second, have_second := object["second"]
	second_field := fmt.aprintf("%s.second", field)
	if !have_second {return nil, Layout_Error{second_field, "supply the second pane or split"}}
	node.first = layout_node(first, first_field, directory, count, depth + 1) or_return
	node.second = layout_node(second, second_field, directory, count, depth + 1) or_return
	return node, nil
}

@(private = "file", require_results)
layout_float :: proc(
	value: json.Value,
	field, directory: string,
) -> (
	result: Layout_Float,
	failure: Maybe(Layout_Error),
) {
	object, is_object := value.(json.Object)
	if !is_object {return {}, Layout_Error{field, "use an object with bounds, unit and pane"}}
	for key, item in object {
		at := fmt.aprintf("%s.%s", field, key)
		switch key {
		case "bounds", "pane":
		case "unit":
			unit, is_text := item.(json.String)
			if !is_text || (unit != "share" && unit != "cells") {
				return {}, Layout_Error{at, "use share or cells"}
			}
			result.cells = unit == "cells"
		case:
			return {}, Layout_Error{at, "unknown key; a float takes bounds, unit and pane"}
		}
	}
	given_bounds, have_bounds := object["bounds"]
	bounds_field := fmt.aprintf("%s.bounds", field)
	if !have_bounds {return {}, Layout_Error{bounds_field, "supply [x, y, width, height]"}}
	bounds, is_array := given_bounds.(json.Array)
	if !is_array || len(bounds) != 4 {
		return {}, Layout_Error{bounds_field, "use [x, y, width, height]"}
	}
	values: [4]f32
	for item, i in bounds {
		at := fmt.aprintf("%s.bounds[%d]", field, i)
		values[i] = layout_number(item, at) or_return
		if i >= 2 && values[i] <= 0 {return {}, Layout_Error{at, "use a positive width or height"}}
	}
	result.bounds = {values[0], values[1], values[2], values[3]}
	pane, have_pane := object["pane"]
	pane_field := fmt.aprintf("%s.pane", field)
	if !have_pane {return {}, Layout_Error{pane_field, "supply a pane object"}}
	result.pane = layout_pane(pane, pane_field, directory) or_return
	return result, nil
}

@(private = "file", require_results)
layout_number :: proc(value: json.Value, field: string) -> (f32, Maybe(Layout_Error)) {
	number, is_number := value.(json.Float)
	if !is_number {return 0, Layout_Error{field, "use a finite number"}}
	result := f32(number)
	if math.is_nan(result) || math.is_inf(result) {
		return 0, Layout_Error{field, "use a finite number representable as a 32-bit float"}
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
