package settings

import "core:fmt"
import "core:strings"

PROGRAM_ICON_FILES_KEY :: "tabs.program_icon_files"

// The documented shape of the value, shown by the description and the diagnostic alike.
PROGRAM_ICON_FILES_EXAMPLE :: `codex=~/icons/codex.png; nvim=D:\icons\nvim.png`

@(private)
PROGRAM_NAME_FORBIDDEN :: `=;:/\*?"`

// The PNG configured for `program`, an executable stem or reported app key, as written in the
// file. The first entry naming it wins; malformed entries are skipped.
@(require_results)
program_icon_file :: proc(s: ^Settings, program: string) -> (path: string, found: bool) {
	name := executable_stem(program)
	if name == "" {return}
	items := Program_Icon_Items {
		rest = s.tabs.program_icon_files,
	}
	for {
		item := program_icon_next(&items) or_break
		entry, entry_path, ok := program_icon_entry(item)
		if ok && strings.equal_fold(executable_stem(entry), name) {return entry_path, true}
	}
	return
}

// A cursor over the `;`-separated items, where a trailing separator leaves an empty last item.
@(private)
Program_Icon_Items :: struct {
	rest: string,
	done: bool,
}

@(private)
program_icon_next :: proc(items: ^Program_Icon_Items) -> (item: string, more: bool) {
	if items.done {return}
	end := strings.index_byte(items.rest, ';')
	if end < 0 {
		item, items.done = items.rest, true
	} else {
		item, items.rest = items.rest[:end], items.rest[end + 1:]
	}
	return item, true
}

@(private, require_results)
program_icon_entry :: proc(item: string) -> (name, path: string, ok: bool) {
	equal := strings.index_byte(item, '=')
	if equal < 0 {return}
	name = strings.trim_space(item[:equal])
	path = strings.trim(strings.trim_space(item[equal + 1:]), "\"")
	ok = name != "" && path != "" && !strings.contains_any(name, PROGRAM_NAME_FORBIDDEN)
	return
}

@(private, require_results)
program_icon_files_valid :: proc(text: string) -> bool {
	if strings.trim_space(text) == "" {return true}
	items := Program_Icon_Items {
		rest = text,
	}
	for {
		item := program_icon_next(&items) or_break
		if _, _, ok := program_icon_entry(item); !ok {return false}
	}
	return true
}

@(private, require_results)
program_icon_files_rules :: proc(buffer: []u8) -> string {
	return fmt.bprintf(
		buffer,
		"Each entry is program=path, separated by semicolons; names cannot use any of %s. A value " +
		"looks like %s.",
		PROGRAM_NAME_FORBIDDEN,
		PROGRAM_ICON_FILES_EXAMPLE,
	)
}
