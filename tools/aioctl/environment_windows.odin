package aioctl

@(private)
environment_is :: proc(entry: []u16, name: string) -> bool {
	if len(entry) <= len(name) || entry[len(name)] != '=' { return false }
	for c, i in name {
		v := entry[i]
		if v >= 'a' && v <= 'z' { v -= 'a'-'A' }
		if v != u16(c) { return false }
	}
	return true
}

@(require_results)
environment_block :: proc(
	parent: []u16, keep_no_color: bool, allocator := context.allocator,
) -> ([]u16, bool) {
	if len(parent) < 2 || parent[len(parent)-1] != 0 || parent[len(parent)-2] != 0 {
		return nil, false
	}
	length := 1
	start := 0
	for start < len(parent) && parent[start] != 0 {
		end := start
		for end < len(parent) && parent[end] != 0 { end += 1 }
		entry := parent[start:end]
		if keep_no_color || !environment_is(entry, "NO_COLOR") {
			length += len(entry)+1
		}
		start = end+1
	}
	if start != len(parent)-1 && !(start == 0 && len(parent) == 2) { return nil, false }
	out, allocation_error := make([]u16, max(2, length), allocator)
	if allocation_error != nil { return nil, false }
	start = 0
	offset := 0
	for parent[start] != 0 {
		end := start
		for parent[end] != 0 { end += 1 }
		entry := parent[start:end]
		start = end+1
		if !keep_no_color && environment_is(entry, "NO_COLOR") {
			continue
		}
		copy(out[offset:], entry)
		offset += len(entry)+1
	}
	return out, true
}
