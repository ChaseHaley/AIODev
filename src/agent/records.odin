package agent

import "core:encoding/json"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Where a pane's session id comes from. A SessionStart hook writes a record for the pane; omp keeps
// a breadcrumb per terminal; without either, Claude Code's process registry or a Codex rollout may
// name it.

// What a hook wrote for the pane: the harness, its session and the processes the hook ran under, so
// the record counts only for the agent process that wrote it.
Record :: struct {
	harness:   string,
	session:   string,
	processes: []u32,
}

// A record or hook payload larger than this is not one.
RECORD_LIMIT :: 64 * 1024

// The session a SessionStart hook's input names; Claude Code and Codex both send session_id.
hook_session :: proc(payload: []u8) -> (string, bool) {
	if len(payload) > RECORD_LIMIT {return "", false}
	input: struct {
		session_id: string,
	}
	if json.unmarshal(payload, &input, allocator = context.temp_allocator) != nil {return "", false}
	return input.session_id, session_id_valid(input.session_id)
}

// The record's file text, in `allocator`.
record_encode :: proc(record: Record, allocator := context.allocator) -> (string, bool) {
	data, err := json.marshal(record, {}, allocator)
	return string(data), err == nil
}

// A record read back, its strings in temporary memory; false for one that is damaged or names no
// known harness and valid session.
record_parse :: proc(data: []u8) -> (Record, bool) {
	record: Record
	if len(data) > RECORD_LIMIT {return {}, false}
	if json.unmarshal(data, &record, allocator = context.temp_allocator) != nil {return {}, false}
	return record, harness_named(record.harness) != .None && session_id_valid(record.session)
}

// Whether the record was written under the pane's agent process `program`.
record_owned :: proc(record: Record, harness: Harness, program: u32) -> bool {
	if harness_named(record.harness) != harness || program == 0 {return false}
	for id in record.processes {
		if id == program {return true}
	}
	return false
}

// A process as the hook command sees its ancestors: a launcher such as node is named by the script it
// runs, so an npm install of Claude Code reads as claude-code.
Ancestor :: struct {
	id:   u32,
	stem: string,
}

// Whether a hook running under `ancestors`, nearest first, belongs to a nested agent: one started by
// another agent, such as `claude -p` or `codex exec` run from an agent's shell tool, whose session is
// not the pane's. Directly chained processes of one harness, a launcher and the program it starts,
// count as one agent.
ancestry_nested :: proc(ancestors: []Ancestor) -> bool {
	agents := 0
	previous := Harness.None
	for ancestor in ancestors {
		harness := stem_harness(ancestor.stem)
		if harness != .None && harness != previous {agents += 1}
		previous = harness
	}
	return agents > 1
}

// The harness an executable stem is, counting platform builds such as codex-x86_64-pc-windows-msvc and
// packages such as claude-code.
@(private)
stem_harness :: proc(stem: string) -> Harness {
	names := HARNESS_NAMES
	for harness in Harness {
		name := names[harness]
		if harness == .None || len(stem) < len(name) || !strings.equal_fold(stem[:len(name)], name) {continue}
		if len(stem) == len(name) || stem[len(name)] == '-' {return harness}
	}
	return .None
}

// The session omp's breadcrumb for a terminal names: its second line is the session file,
// <timestamp>_<id>.jsonl. Returns the file too, borrowed from `text`.
breadcrumb_session :: proc(text: string) -> (id, file: string, ok: bool) {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) < 2 {return}
	file = strings.trim_space(lines[1])
	base := filepath.base(file)
	if !strings.has_suffix(base, ".jsonl") {return}
	base = base[:len(base) - len(".jsonl")]
	underscore := strings.last_index_byte(base, '_')
	if underscore < 0 {return}
	id = base[underscore + 1:]
	return id, file, session_id_valid(id)
}

// The file name of omp's breadcrumb for a terminal whose TERM_SESSION_ID is `key`.
breadcrumb_name :: proc(key: string, allocator := context.allocator) -> string {
	return strings.concatenate({"apple-", key}, allocator)
}

// The session Claude Code's live registry entry for one process names.
claude_registry_session :: proc(data: []u8) -> (string, bool) {
	if len(data) > RECORD_LIMIT {return "", false}
	entry: struct {
		sessionId: string,
	}
	if json.unmarshal(data, &entry, allocator = context.temp_allocator) != nil {return "", false}
	return entry.sessionId, session_id_valid(entry.sessionId)
}

// A Codex rollout as its first line describes it.
Rollout :: struct {
	id, directory: string,
	started:       time.Time,
	// Codex's interactive terminal session, not exec, a subagent or another client.
	interactive:   bool,
}

// Reads a rollout's first line; strings in temporary memory.
rollout_parse :: proc(line: []u8) -> (Rollout, bool) {
	if len(line) > RECORD_LIMIT {return {}, false}
	meta: struct {
		type:    string,
		payload: struct {
			id, cwd, timestamp, originator: string,
			source:                         json.Value,
		},
	}
	if json.unmarshal(line, &meta, allocator = context.temp_allocator) != nil {return {}, false}
	if meta.type != "session_meta" || !session_id_valid(meta.payload.id) {return {}, false}
	started, consumed := time.rfc3339_to_time_utc(meta.payload.timestamp)
	if consumed == 0 {return {}, false}
	_, from_subagent := meta.payload.source.(json.Object)
	return {
			id = meta.payload.id,
			directory = meta.payload.cwd,
			started = started,
			interactive = meta.payload.originator == "codex-tui" && !from_subagent,
		},
		true
}

// The one interactive rollout begun in `directory` since the program started; none when there are
// several, which could belong to another pane.
rollout_pick :: proc(rollouts: []Rollout, directory: string, program_started: time.Time) -> (string, bool) {
	found := ""
	count := 0
	for rollout in rollouts {
		if !rollout.interactive || !path_same(rollout.directory, directory) {continue}
		if time.diff(program_started, rollout.started) < 0 {continue}
		found = rollout.id
		count += 1
	}
	return found, count == 1
}

// Windows paths compare without case, separator style or a trailing separator.
@(private)
path_same :: proc(a, b: string) -> bool {
	x := strings.trim_right(a, `\/`)
	y := strings.trim_right(b, `\/`)
	if len(x) != len(y) || x == "" {return false}
	for i in 0 ..< len(x) {
		c, d := x[i], y[i]
		if c == '/' {c = '\\'}
		if d == '/' {d = '\\'}
		if c >= 'A' && c <= 'Z' {c += 'a' - 'A'}
		if d >= 'A' && d <= 'Z' {d += 'a' - 'A'}
		if c != d {return false}
	}
	return true
}
