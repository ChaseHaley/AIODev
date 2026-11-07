package procinfo

import "core:strings"

Process_Info :: struct {
	id, parent: u32,
	executable: string,
}

Error :: enum {
	None,
	Read,
	Out_Of_Memory,
}

// Returns the deepest descendant; snapshot order breaks ties between sibling processes.
// Windows has no host-side foreground process API, so detached/background descendants are ambiguous.
process_leaf :: proc(processes: []Process_Info, root: u32) -> int {
	parents := make(map[u32]u32, len(processes), context.temp_allocator)
	for p in processes {parents[p.id] = p.parent}
	best, depth := -1, -1
	for p, index in processes {
		current, steps := p.id, 0
		for steps <= len(processes) {
			if current == root {
				if steps >= depth {best, depth = index, steps}
				break
			}
			parent := parents[current]
			if parent == 0 || parent == current {break}
			current = parent
			steps += 1
		}
	}
	return best
}

// A matched application keeps its padding while helper processes run beneath it.
process_ancestor :: proc(processes: []Process_Info, index: int) -> int {
	if index < 0 || index >= len(processes) {return -1}
	for p, i in processes {
		if p.id == processes[index].parent && p.id != processes[index].id {return i}
	}
	return -1
}

// The program a pane's icon names. A process whose executable matches a reporting app wins, in the
// order given, at any depth below the shell, so a reporter started through a launcher still counts.
// Otherwise the shell's direct child is chosen; `current` keeps a sibling choice stable, and the
// last in snapshot order is taken when none is current. Console hosts are not programs.
process_program :: proc(processes: []Process_Info, root: u32, apps: []string, current: u32) -> int {
	parents := make(map[u32]u32, len(processes), context.temp_allocator)
	for p in processes {parents[p.id] = p.parent}
	for app in apps {
		best, best_depth := -1, len(processes) + 1
		for p, index in processes {
			if p.id == root || !process_stem_is(p.executable, app) {continue}
			depth := process_depth(parents, p.id, root, len(processes))
			if depth > 0 && depth < best_depth {best, best_depth = index, depth}
		}
		if best >= 0 {return best}
	}
	child := -1
	for p, index in processes {
		if p.parent != root || p.id == root {continue}
		if process_stem_is(p.executable, "conhost") || process_stem_is(p.executable, "OpenConsole") {
			continue
		}
		child = index
		if p.id == current {break}
	}
	return child
}

// Steps from id up to root, or 0 when root is not an ancestor.
@(private)
process_depth :: proc(parents: map[u32]u32, id, root: u32, limit: int) -> int {
	current := id
	for steps := 0; steps <= limit; steps += 1 {
		if current == root {return steps}
		parent := parents[current]
		if parent == 0 || parent == current {return 0}
		current = parent
	}
	return 0
}

@(private)
process_stem_is :: proc(executable, name: string) -> bool {
	stem := executable
	if len(stem) > 4 && strings.equal_fold(stem[len(stem) - 4:], ".exe") {stem = stem[:len(stem) - 4]}
	return name != "" && strings.equal_fold(stem, name)
}

// The program a launcher such as Node or cmd runs, named from its arguments: the package of a
// script under node_modules (without its scope), otherwise the file stem of the first argument
// that is not an option. Empty when the arguments name nothing.
process_script :: proc(arguments: []string) -> string {
	for argument, i in arguments {
		if i == 0 || argument == "" || argument[0] == '-' || argument[0] == '/' && len(argument) <= 3 {
			continue
		}
		text := strings.trim(argument, "\" ")
		if at := strings.last_index(text, "node_modules"); at >= 0 && at + 13 <= len(text) {
			parts := strings.split_multi(text[at + 13:], {"\\", "/"}, context.temp_allocator)
			if len(parts) > 1 && strings.has_prefix(parts[0], "@") {return parts[1]}
			return parts[0]
		}
		// cmd receives a whole quoted command as one argument: keep up to the script's extension.
		lower := strings.to_lower(text, context.temp_allocator)
		end := -1
		for extension in ([]string{".cmd", ".bat", ".exe", ".js", ".mjs", ".cjs", ".py", ".ps1"}) {
			if at := strings.index(lower, extension); at >= 0 && (end < 0 || at < end) {
				end = at
			}
		}
		if end < 0 {end = strings.index_any(text, " \"")}
		if end >= 0 {text = text[:end]}
		if slash := strings.last_index_any(text, "\\/"); slash >= 0 {text = text[slash + 1:]}
		return text
	}
	return ""
}
