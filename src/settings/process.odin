package settings

import "aio:procinfo"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

Process_Settings :: struct {
	padding_groups: string,
}

PADDING_GROUPS_KEY :: "process.padding_groups"

// The documented shape of a padding-group value. The settings description and the diagnostic for a
// malformed value both show it, so a grammar change updates the example with the parser.
PADDING_GROUPS_EXAMPLE :: "editors:0:nvim,vim; tools:4:less,bat"

CONTENT_PADDING_RANGE :: Range{0, 1024}
@(private)
PADDING_NAME_FORBIDDEN :: ":/\\*?\""
// `;` ends a group and a line break ends the setting, so no edited field can hold either. A group
// name also ends at `:` and a program at `,`.
@(private)
PADDING_GROUP_END :: ";\r\n"

// One `group:padding:process,process` entry. `valid` carries the parser's verdict so validation
// rejects the file value and lookup skips only the group it cannot trust.
Padding_Group :: struct {
	name:      string,
	padding:   int,
	processes: string,
	valid:     bool,
}

// A cursor over the `;`-separated groups. A blank value has no groups; anywhere else an empty item
// is malformed, which makes a trailing or doubled separator follow the same rule as an empty name.
Padding_Groups :: struct {
	rest: string,
	done: bool,
}

@(require_results)
padding_groups_scan :: proc(text: string) -> Padding_Groups {
	if strings.trim_space(text) == "" {return {done = true}}
	return {rest = text}
}

@(require_results)
padding_groups_next :: proc(groups: ^Padding_Groups) -> (group: Padding_Group, more: bool) {
	if groups.done {return {}, false}
	text := groups.rest
	if end := strings.index_byte(text, ';'); end >= 0 {
		groups.rest = text[end + 1:]
		text = text[:end]
	} else {
		groups.done = true
	}
	group = padding_group(text)
	return group, true
}

Padding_Processes :: struct {
	rest: string,
	done: bool,
}

@(require_results)
padding_processes_next :: proc(names: ^Padding_Processes) -> (name: string, more: bool) {
	if names.done {return "", false}
	name = names.rest
	if comma := strings.index_byte(name, ','); comma >= 0 {
		names.rest = name[comma + 1:]
		name = name[:comma]
	} else {
		names.done = true
	}
	return strings.trim_space(name), true
}

@(private, require_results)
padding_group :: proc(text: string) -> (group: Padding_Group) {
	first := strings.index_byte(text, ':')
	if first < 1 {return}
	rest := text[first + 1:]
	second := strings.index_byte(rest, ':')
	if second < 1 {return}
	padding, parsed := padding_value(rest[:second])
	if !parsed {return}
	group.name = strings.trim_space(text[:first])
	group.processes = strings.trim_space(rest[second + 1:])
	if group.name == "" || group.processes == "" {return}
	names := Padding_Processes{rest = group.processes}
	for {
		name, more := padding_processes_next(&names)
		if !more {break}
		if !padding_process_valid(name) {return}
	}
	group.padding = padding
	group.valid = true
	return
}

@(private, require_results)
padding_value :: proc(text: string) -> (int, bool) {
	padding, parsed := strconv.parse_int(strings.trim_space(text), 10)
	return padding, parsed &&
		padding >= int(CONTENT_PADDING_RANGE.minimum) && padding <= int(CONTENT_PADDING_RANGE.maximum)
}

@(private, require_results)
padding_process_valid :: proc(name: string) -> bool {
	return name != "" && !strings.contains_any(name, PADDING_NAME_FORBIDDEN)
}

// What an edited group cannot store, reported for its programs first, then its name and padding.
Padding_Problem :: enum u8 {
	Program,
	Duplicate_Program,
	Name,
	Padding,
	No_Programs,
}

// One edited `name:padding:program,program` group; each field is the raw text typed for it.
Padding_Draft :: struct {
	name, padding: string,
	programs:      []string,
}

// Encodes edited groups in the grammar padding_groups_next and padding_processes_next read back, or
// reports the first field of the first group it cannot store; a refused draft encodes nothing.
@(require_results)
padding_groups_text :: proc(
	groups: []Padding_Draft,
	allocator := context.allocator,
) -> (
	text: string,
	problem: Maybe(Padding_Problem),
	err: runtime.Allocator_Error,
) {
	for group in groups {
		if problem = padding_group_check(group); problem != nil {return}
	}
	builder := strings.builder_make(allocator) or_return
	for group, index in groups {
		if index > 0 {strings.write_byte(&builder, ';')}
		padding, _ := padding_value(group.padding)
		fmt.sbprintf(&builder, "%s:%d:", strings.trim_space(group.name), padding)
		for program, slot in group.programs {
			if slot > 0 {strings.write_byte(&builder, ',')}
			strings.write_string(&builder, strings.trim_space(program))
		}
	}
	return strings.to_string(builder), nil, nil
}

// A field must not hold a separator that would split it on the next parse. Editing also refuses a
// program listed twice in one group: a file may repeat it harmlessly, but an editor repeat is a slip.
@(private, require_results)
padding_group_check :: proc(group: Padding_Draft) -> Maybe(Padding_Problem) {
	for program, index in group.programs {
		name := strings.trim_space(program)
		if !padding_process_valid(name) || strings.contains_any(name, "," + PADDING_GROUP_END) {
			return Padding_Problem.Program
		}
		for other in group.programs[:index] {
			if strings.equal_fold(procinfo.executable_stem(other), procinfo.executable_stem(name)) {
				return Padding_Problem.Duplicate_Program
			}
		}
	}
	name := strings.trim_space(group.name)
	if name == "" || strings.contains_any(name, ":" + PADDING_GROUP_END) {return Padding_Problem.Name}
	if _, valid := padding_value(group.padding); !valid {return Padding_Problem.Padding}
	if len(group.programs) == 0 {return Padding_Problem.No_Programs}
	return nil
}

@(private, require_results)
padding_groups_valid :: proc(text: string) -> bool {
	groups := padding_groups_scan(text)
	for {
		group, more := padding_groups_next(&groups)
		if !more {break}
		if !group.valid {return false}
	}
	return true
}

// Built from the parser's own limits and example, so the diagnostic cannot describe a grammar the
// parser does not accept.
@(private, require_results)
padding_groups_rules :: proc(buffer: []u8) -> string {
	return fmt.bprintf(
		buffer,
		"Process names cannot be empty or use any of %s. Padding is %d..%d; a value looks like %s.",
		PADDING_NAME_FORBIDDEN,
		int(CONTENT_PADDING_RANGE.minimum),
		int(CONTENT_PADDING_RANGE.maximum),
		PADDING_GROUPS_EXAMPLE,
	)
}

// Names match whole executable basenames. The first listed group wins an overlap.
process_padding :: proc(s: ^Settings, executable: string) -> (int, bool) {
	name := procinfo.executable_stem(executable)
	groups := padding_groups_scan(s.process.padding_groups)
	for {
		group, more := padding_groups_next(&groups)
		if !more {break}
		if !group.valid {continue}
		names := Padding_Processes{rest = group.processes}
		for {
			process, has_name := padding_processes_next(&names)
			if !has_name {break}
			if strings.equal_fold(procinfo.executable_stem(process), name) {return group.padding, true}
		}
	}
	return s.window.padding, false
}
