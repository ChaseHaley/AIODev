package settings

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

@(private)
PADDING_MIN :: 0
@(private)
PADDING_MAX :: 1024
@(private)
PADDING_NAME_FORBIDDEN :: ":/\\*?\""

// One `group:padding:process,process` entry. `valid` carries the parser's verdict so validation
// rejects the file value and lookup skips only the group it cannot trust.
@(private)
Padding_Group :: struct {
	name:      string,
	padding:   int,
	processes: string,
	valid:     bool,
}

// A cursor over the `;`-separated groups. A blank value has no groups; anywhere else an empty item
// is malformed, which makes a trailing or doubled separator follow the same rule as an empty name.
@(private)
Padding_Groups :: struct {
	rest: string,
	done: bool,
}

@(private, require_results)
padding_groups_scan :: proc(text: string) -> Padding_Groups {
	if strings.trim_space(text) == "" {return {done = true}}
	return {rest = text}
}

@(private, require_results)
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

@(private)
Padding_Processes :: struct {
	rest: string,
	done: bool,
}

@(private, require_results)
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
	padding, parsed := strconv.parse_int(strings.trim_space(rest[:second]), 10)
	if !parsed || padding < PADDING_MIN || padding > PADDING_MAX {return}
	group.name = strings.trim_space(text[:first])
	group.processes = strings.trim_space(rest[second + 1:])
	if group.name == "" || group.processes == "" {return}
	names := Padding_Processes{rest = group.processes}
	for {
		name, more := padding_processes_next(&names)
		if !more {break}
		if name == "" || strings.contains_any(name, PADDING_NAME_FORBIDDEN) {return}
	}
	group.padding = padding
	group.valid = true
	return
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
		PADDING_MIN,
		PADDING_MAX,
		PADDING_GROUPS_EXAMPLE,
	)
}

// Padding-group names and shell command lines both identify an executable by a case-insensitive name
// without a trailing ".exe".
@(private, require_results)
executable_stem :: proc(name: string) -> string {
	text := strings.trim_space(name)
	if len(text) > 4 && strings.equal_fold(text[len(text) - 4:], ".exe") {
		return text[:len(text) - 4]
	}
	return text
}

// Names match whole executable basenames. The first listed group wins an overlap.
process_padding :: proc(s: ^Settings, executable: string) -> (int, bool) {
	name := executable_stem(executable)
	groups := padding_groups_scan(s.process.padding_groups)
	for {
		group, more := padding_groups_next(&groups)
		if !more {break}
		if !group.valid {continue}
		names := Padding_Processes{rest = group.processes}
		for {
			process, has_name := padding_processes_next(&names)
			if !has_name {break}
			if strings.equal_fold(executable_stem(process), name) {return group.padding, true}
		}
	}
	return s.window.padding, false
}
