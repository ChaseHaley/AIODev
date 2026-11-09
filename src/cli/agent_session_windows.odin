package cli

import "aio:agent"
import "aio:cli_protocol"
import "aio:procinfo"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

AGENT_SESSION_COMMAND :: "agent-session"

// Ancestors past this many are not the hook's agent.
@(private)
ANCESTOR_LIMIT :: 64

// aio agent-session <harness>, run by a Claude Code or Codex SessionStart hook (WORK-361): records the
// session the hook's input names in the pane's record file, which AIODev reads when it saves the pane.
// It needs no control pipe. It prints nothing on standard output, which a hook hands to the model, and
// outside an AIODev pane, or for an agent another agent started, it records nothing and succeeds.
@(private)
agent_session_record :: proc(args: []string) -> cli_protocol.Status {
	harness := len(args) == 1 ? agent.harness_named(args[0]) : .None
	if harness != .Claude && harness != .Codex {
		fmt.eprintln("aio: agent-session takes claude or codex")
		return .Usage
	}
	path, in_pane := os.lookup_env(agent.RECORD_VARIABLE, context.temp_allocator)
	if !in_pane || path == "" {return .Ok}
	input, read_error := os.read_entire_file_from_file(os.stdin, context.temp_allocator)
	if read_error != nil {
		fmt.eprintfln("aio: reading the hook input failed: %v", read_error)
		return .Failed
	}
	session, named := agent.hook_session(input)
	if !named {
		fmt.eprintln("aio: the hook input names no session")
		return .Failed
	}
	processes, snapshot_error := procinfo.process_snapshot(context.temp_allocator)
	if snapshot_error != .None {
		fmt.eprintfln("aio: listing processes failed: %v", snapshot_error)
		return .Failed
	}
	ancestors := hook_ancestors(processes, u32(os.get_pid()))
	if agent.ancestry_nested(ancestors, harness) {return .Ok}
	ids := make([]u32, len(ancestors), context.temp_allocator)
	for ancestor, i in ancestors {ids[i] = ancestor.id}
	names := agent.HARNESS_NAMES
	text, encoded := agent.record_encode({names[harness], session, ids}, context.temp_allocator)
	if !encoded {return .Failed}
	if !record_write(path, text) {return .Failed}
	return .Ok
}

// The processes above `self` up to the AIODev that runs the pane, nearest first, by executable stem;
// an agent that started AIODev itself is not the hook's.
@(private)
hook_ancestors :: proc(processes: []procinfo.Process_Info, self: u32) -> []agent.Ancestor {
	parents := make(map[u32]int, len(processes), context.temp_allocator)
	for p, i in processes {parents[p.id] = i}
	ancestors := make([dynamic]agent.Ancestor, 0, 16, context.temp_allocator)
	index, found := parents[self]
	for found && len(ancestors) < ANCESTOR_LIMIT {
		parent := processes[index].parent
		if parent == 0 || parent == processes[index].id {break}
		index, found = parents[parent]
		if !found {break}
		stem := procinfo.executable_stem(processes[index].executable)
		if len(stem) >= 6 && strings.equal_fold(stem[:6], "aiodev") {break}
		append(&ancestors, agent.Ancestor{parent, stem})
	}
	return ancestors[:]
}

// Replaces the record whole, so AIODev never reads half of one.
@(private)
record_write :: proc(path, text: string) -> bool {
	directory := filepath.dir(path)
	if err := os.mkdir_all(directory); err != nil {
		fmt.eprintfln("aio: creating %s failed: %v", directory, err)
		return false
	}
	f, create_error := os.create_temp_file(directory, ".record-*")
	if create_error != nil {
		fmt.eprintfln("aio: creating the session record failed: %v", create_error)
		return false
	}
	name := strings.clone(os.name(f), context.temp_allocator)
	n, write_error := os.write(f, transmute([]u8)text)
	close_error := os.close(f)
	if write_error != nil || close_error != nil || n != len(text) {
		fmt.eprintfln("aio: writing the session record failed: %v, %v", write_error, close_error)
		_ = os.remove(name)
		return false
	}
	if rename_error := os.rename(name, path); rename_error != nil {
		fmt.eprintfln("aio: replacing the session record failed: %v", rename_error)
		_ = os.remove(name)
		return false
	}
	return true
}
