package turns

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

// One JSON file per segment, named by its id.
SEGMENT_EXTENSION :: ".json"

// A segment file larger than this is not one.
SEGMENT_LIMIT :: 16 * 1024 * 1024

// Bumped when the file's fields change in a way an older reader would misread.
SEGMENT_VERSION :: 1

// How deeply a segment file nests: the segment, its changes, one change.
@(private)
SEGMENT_DEPTH :: 4

@(private)
OID_SHA1 :: 40
@(private)
OID_SHA256 :: 64

// The file name for a segment: its id as 16 lowercase hex digits and the extension.
segment_file_name :: proc(id: u64, allocator := context.allocator) -> string {
	return fmt.aprintf("%016x%s", id, SEGMENT_EXTENSION, allocator = allocator)
}

// Whether `o` is a git object id as this package stores it: empty, or 40 (SHA-1) or 64 (SHA-256)
// lowercase hex digits.
oid_valid :: proc(o: Oid) -> bool {
	if o == "" {return true}
	if len(o) != OID_SHA1 && len(o) != OID_SHA256 {return false}
	for i in 0 ..< len(o) {
		if !lower_hex(o[i]) {return false}
	}
	return true
}

@(private)
lower_hex :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
}

// Text that may be written to or read from a segment file: valid UTF-8 without NUL.
@(private)
text_valid :: proc(s: string) -> bool {
	if !utf8.valid_string(s) {return false}
	for i in 0 ..< len(s) {
		if s[i] == 0 {return false}
	}
	return true
}

@(private)
kind_name :: proc(k: Segment_Kind) -> string {
	switch k {
	case .Turn:
		return "turn"
	case .Between:
		return "between"
	}
	return ""
}

@(private)
end_state_name :: proc(e: End_State) -> string {
	switch e {
	case .Unknown:
		return "unknown"
	case .Done:
		return "done"
	case .Idle:
		return "idle"
	case .Error:
		return "error"
	case .Ended:
		return "ended"
	}
	return ""
}

@(private)
source_name :: proc(s: Signal_Source) -> string {
	switch s {
	case .Status:
		return "status"
	case .Hooks:
		return "hooks"
	}
	return ""
}

// The segment's file text, in `allocator`; false for a segment that could not be read back: a negative
// count, an invalid object id, text that is not UTF-8, a change without a path, or a file past the limit.
@(require_results)
segment_encode :: proc(s: Segment, allocator := context.allocator) -> (string, bool) {
	b := strings.builder_make(0, 512 + 160 * len(s.changes), allocator)
	if !write_segment(&b, s) || strings.builder_len(b) > SEGMENT_LIMIT {
		strings.builder_destroy(&b)
		return "", false
	}
	return strings.to_string(b), true
}

@(private)
write_segment :: proc(b: ^strings.Builder, s: Segment) -> bool {
	if s.added < 0 || s.removed < 0 {return false}
	strings.write_string(b, `{"version":`)
	strings.write_int(b, SEGMENT_VERSION)
	strings.write_string(b, `,"id":"`)
	write_hex_id(b, s.id)
	strings.write_string(b, `","kind":"`)
	strings.write_string(b, kind_name(s.kind))
	strings.write_string(b, `","session":{"pane_key":`)
	write_quoted(b, s.session.pane_key) or_return
	strings.write_string(b, `,"harness":`)
	write_quoted(b, s.session.harness) or_return
	strings.write_string(b, `,"session":`)
	write_quoted(b, s.session.session) or_return
	strings.write_string(b, `},"started":`)
	strings.write_i64(b, s.started)
	strings.write_string(b, `,"ended":`)
	strings.write_i64(b, s.ended)
	strings.write_string(b, `,"end_state":"`)
	strings.write_string(b, end_state_name(s.end_state))
	strings.write_string(b, `","title":`)
	write_quoted(b, s.title) or_return
	strings.write_string(b, `,"sources":[`)
	first := true
	for source in Signal_Source {
		if source not_in s.sources {continue}
		if !first {strings.write_byte(b, ',')}
		first = false
		strings.write_byte(b, '"')
		strings.write_string(b, source_name(source))
		strings.write_byte(b, '"')
	}
	strings.write_string(b, `],"added":`)
	strings.write_int(b, s.added)
	strings.write_string(b, `,"removed":`)
	strings.write_int(b, s.removed)
	strings.write_string(b, `,"changes":[`)
	for c, i in s.changes {
		if c.worktree == "" || c.path == "" || !oid_valid(c.before) || !oid_valid(c.after) {return false}
		if i > 0 {strings.write_byte(b, ',')}
		strings.write_string(b, `{"worktree":`)
		write_quoted(b, c.worktree) or_return
		strings.write_string(b, `,"path":`)
		write_quoted(b, c.path) or_return
		strings.write_string(b, `,"before":"`)
		strings.write_string(b, c.before)
		strings.write_string(b, `","after":"`)
		strings.write_string(b, c.after)
		strings.write_string(b, `","shared":`)
		strings.write_string(b, "true" if c.shared else "false")
		strings.write_byte(b, '}')
	}
	strings.write_string(b, "]}\n")
	return true
}

@(private)
write_hex_id :: proc(b: ^strings.Builder, id: u64) {
	digits := "0123456789abcdef"
	for shift := 60; shift >= 0; shift -= 4 {
		strings.write_byte(b, digits[(id >> uint(shift)) & 0xf])
	}
}

@(private)
write_quoted :: proc(b: ^strings.Builder, s: string) -> bool {
	if !text_valid(s) {return false}
	digits := "0123456789abcdef"
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c == '"':
			strings.write_string(b, `\"`)
		case c == '\\':
			strings.write_string(b, `\\`)
		case c < 0x20:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, digits[c >> 4])
			strings.write_byte(b, digits[c & 0xf])
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
	return true
}

// A segment read back, its strings in `allocator` (free with segment_destroy); false for a file that is
// damaged, oversize (> 16 MiB), not UTF-8, or holds an invalid object id or an unknown kind, end state
// or source.
@(require_results)
segment_decode :: proc(data: []u8, allocator := context.allocator) -> (Segment, bool) {
	if len(data) > SEGMENT_LIMIT || !utf8.valid_string(string(data)) || !depth_ok(data) {
		return {}, false
	}
	// The parser's tree is one arena, so every early return below leaves nothing to free.
	arena: vmem.Arena
	if vmem.arena_init_growing(&arena) != nil {return {}, false}
	defer vmem.arena_destroy(&arena)
	value, err := json.parse(data, .JSON, true, vmem.arena_allocator(&arena))
	if err != nil {return {}, false}
	root, is_object := value.(json.Object)
	if !is_object {return {}, false}
	s: Segment
	if !fill_segment(&s, root, allocator) {
		segment_destroy(&s, allocator)
		return {}, false
	}
	return s, true
}

// Whether brackets nest no deeper than a segment file does, so the parser's recursion stays small
// whatever the file holds.
@(private)
depth_ok :: proc(data: []u8) -> bool {
	depth := 0
	in_string := false
	for i := 0; i < len(data); i += 1 {
		c := data[i]
		switch {
		case in_string && c == '\\':
			i += 1
		case c == '"':
			in_string = !in_string
		case in_string:
		case c == '{' || c == '[':
			depth += 1
			if depth > SEGMENT_DEPTH {return false}
		case c == '}' || c == ']':
			depth -= 1
		}
	}
	return true
}

@(private)
fill_segment :: proc(s: ^Segment, root: json.Object, allocator := context.allocator) -> bool {
	version := get_integer(root, "version") or_return
	if version != SEGMENT_VERSION {return false}
	s.id = hex_id(get_string(root, "id") or_return) or_return
	switch get_string(root, "kind") or_return {
	case "turn":
		s.kind = .Turn
	case "between":
		s.kind = .Between
	case:
		return false
	}
	session := get_object(root, "session") or_return
	s.session.pane_key = get_copy(session, "pane_key", allocator) or_return
	s.session.harness = get_copy(session, "harness", allocator) or_return
	s.session.session = get_copy(session, "session", allocator) or_return
	s.started = get_integer(root, "started") or_return
	s.ended = get_integer(root, "ended") or_return
	switch get_string(root, "end_state") or_return {
	case "unknown":
		s.end_state = .Unknown
	case "done":
		s.end_state = .Done
	case "idle":
		s.end_state = .Idle
	case "error":
		s.end_state = .Error
	case "ended":
		s.end_state = .Ended
	case:
		return false
	}
	s.title = get_copy(root, "title", allocator) or_return
	sources := get_array(root, "sources") or_return
	for item in sources {
		name, is_string := item.(json.String)
		if !is_string {return false}
		switch name {
		case "status":
			s.sources += {.Status}
		case "hooks":
			s.sources += {.Hooks}
		case:
			return false
		}
	}
	added := get_integer(root, "added") or_return
	removed := get_integer(root, "removed") or_return
	if added < 0 || removed < 0 {return false}
	s.added, s.removed = int(added), int(removed)
	changes := get_array(root, "changes") or_return
	s.changes = make([]Change, len(changes), allocator)
	if len(changes) > 0 && s.changes == nil {return false}
	for item, i in changes {
		change, is_object := item.(json.Object)
		if !is_object {return false}
		c := &s.changes[i]
		c.worktree = get_copy(change, "worktree", allocator) or_return
		c.path = get_copy(change, "path", allocator) or_return
		if c.worktree == "" || c.path == "" {return false}
		c.before = get_copy(change, "before", allocator) or_return
		c.after = get_copy(change, "after", allocator) or_return
		if !oid_valid(c.before) || !oid_valid(c.after) {return false}
		shared, has_shared := change["shared"]
		flag, is_bool := shared.(json.Boolean)
		if !has_shared || !is_bool {return false}
		c.shared = bool(flag)
	}
	return true
}

@(private)
get_integer :: proc(o: json.Object, key: string) -> (i64, bool) {
	value, found := o[key]
	n, is_integer := value.(json.Integer)
	return i64(n), found && is_integer
}

@(private)
get_string :: proc(o: json.Object, key: string) -> (string, bool) {
	value, found := o[key]
	s, is_string := value.(json.String)
	return string(s), found && is_string && text_valid(string(s))
}

@(private)
get_object :: proc(o: json.Object, key: string) -> (json.Object, bool) {
	value, found := o[key]
	inner, is_object := value.(json.Object)
	return inner, found && is_object
}

@(private)
get_array :: proc(o: json.Object, key: string) -> (json.Array, bool) {
	value, found := o[key]
	list, is_array := value.(json.Array)
	return list, found && is_array
}

@(private)
get_copy :: proc(o: json.Object, key: string, allocator := context.allocator) -> (value: string, ok: bool) {
	s := get_string(o, key) or_return
	if s == "" {return "", true}
	cloned, err := strings.clone(s, allocator)
	return cloned, err == nil
}

@(private)
hex_id :: proc(text: string) -> (id: u64, ok: bool) {
	if len(text) != 16 {return 0, false}
	for i in 0 ..< 16 {
		c := text[i]
		if !lower_hex(c) {return 0, false}
		id = id << 4 | u64(c - '0' if c <= '9' else c - 'a' + 10)
	}
	return id, true
}

// Frees what segment_decode allocated; accepts a partly filled segment.
segment_destroy :: proc(s: ^Segment, allocator := context.allocator) {
	delete(s.session.pane_key, allocator)
	delete(s.session.harness, allocator)
	delete(s.session.session, allocator)
	delete(s.title, allocator)
	for c in s.changes {
		delete(c.worktree, allocator)
		delete(c.path, allocator)
		delete(c.before, allocator)
		delete(c.after, allocator)
	}
	delete(s.changes, allocator)
	s^ = {}
}
