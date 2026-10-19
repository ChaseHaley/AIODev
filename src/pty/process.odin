package pty

Process_Info :: struct {
	id, parent: u32,
	executable: string,
}

// Returns the deepest descendant; snapshot order breaks ties between sibling processes.
// Windows has no host-side foreground process API, so detached/background descendants are ambiguous.
process_leaf :: proc(processes: []Process_Info, root: u32) -> int {
	parents := make(map[u32]u32, len(processes), context.temp_allocator)
	for p in processes { parents[p.id] = p.parent }
	best, depth := -1, -1
	for p, index in processes {
		current, steps := p.id, 0
		for steps <= len(processes) {
			if current == root {
				if steps >= depth { best, depth = index, steps }
				break
			}
			parent := parents[current]
			if parent == 0 || parent == current { break }
			current = parent
			steps += 1
		}
	}
	return best
}

// A matched application keeps its padding while helper processes run beneath it.
process_ancestor :: proc(processes: []Process_Info, index: int) -> int {
	if index < 0 || index >= len(processes) { return -1 }
	for p, i in processes {
		if p.id == processes[index].parent && p.id != processes[index].id { return i }
	}
	return -1
}
