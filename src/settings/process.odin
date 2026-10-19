package settings

import "core:strconv"
import "core:strings"

Process_Settings :: struct { padding_groups: string }

@(private)
padding_group :: proc(text: string) -> (name, processes: string, padding: int, ok: bool) {
	first := strings.index_byte(text, ':')
	if first < 1 { return }
	name = strings.trim_space(text[:first])
	rest := text[first+1:]
	second := strings.index_byte(rest, ':')
	if second < 1 { return }
	padding, ok = strconv.parse_int(strings.trim_space(rest[:second]), 10)
	processes = strings.trim_space(rest[second+1:])
	ok = ok && name != "" && processes != "" && padding >= 0 && padding <= 1024
	return
}

@(private)
process_groups_valid :: proc(text: string) -> bool {
	if strings.trim_space(text) == "" { return true }
	rest := text
	for group in strings.split_by_byte_iterator(&rest, ';') {
		_, names, _, ok := padding_group(group)
		if !ok { return false }
		if strings.has_suffix(names, ",") { return false }
		for raw in strings.split_by_byte_iterator(&names, ',') {
			name := strings.trim_space(raw)
			if name == "" || strings.contains_any(name, ":/\\*?\"") { return false }
		}
	}
	return !strings.has_suffix(strings.trim_space(text), ";")
}

@(private)
process_stem :: proc(raw: string) -> string {
	name := strings.trim_space(raw)
	if len(name) > 4 && strings.equal_fold(name[len(name)-4:], ".exe") { return name[:len(name)-4] }
	return name
}

// Names match whole executable basenames. The first listed group wins an overlap.
process_padding :: proc(s: ^Settings, executable: string) -> (int, bool) {
	groups := s.process.padding_groups
	for group in strings.split_by_byte_iterator(&groups, ';') {
		_, names, padding, ok := padding_group(group)
		if !ok { continue }
		for name in strings.split_by_byte_iterator(&names, ',') {
			if strings.equal_fold(process_stem(name), process_stem(executable)) { return padding, true }
		}
	}
	return s.window.padding, false
}
