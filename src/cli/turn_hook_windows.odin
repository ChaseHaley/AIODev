package cli

import "aio:agent"
import "aio:cli_protocol"
import "aio:procinfo"
import "aio:turns"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import w "core:sys/windows"
import "core:time"

TURN_HOOK_COMMAND :: "turn-hook"

// The variable naming the pane's key, which AIODev sets and omp's breadcrumb reads too.
@(private)
PANE_KEY_VARIABLE :: "TERM_SESSION_ID"
// GetExitCodeProcess's answer for a process that has not ended.
@(private)
STILL_ACTIVE :: 259
// How long a prompt or edit hook waits for AIODev to take its event, and how often it looks.
@(private)
TURN_HOOK_WAIT :: 2000 * time.Millisecond
@(private)
TURN_HOOK_POLL :: 10 * time.Millisecond

// aio turn-hook <claude|codex> <prompt|stop|edit>, run by a Claude Code or Codex UserPromptSubmit, Stop
// or PreToolUse hook (WORK-487): hands the turn boundary or the paths about to be edited to AIODev
// through a file in its turns directory, because the control pipe is off by default. Whatever a hook
// prints on standard output reaches the model, so this prints nothing there on any path, and it exits 0
// whenever the hook is not for a recording AIODev pane or anything goes wrong, so an agent is never held
// up or blocked by it. A prompt or edit hook waits until AIODev has taken the event, so the files it
// snapshots are the ones from before the tool runs.
@(private, require_results)
turn_hook_run :: proc(args: []string) -> cli_protocol.Status {
	harness := len(args) == 2 ? agent.harness_named(args[0]) : .None
	kind, kind_named := turn_hook_kind(len(args) == 2 ? args[1] : "")
	if harness != .Claude && harness != .Codex || !kind_named {
		fmt.eprintln("aio: turn-hook takes claude or codex, then prompt, stop or edit")
		return .Ok
	}
	directory, in_pane := os.lookup_env(turns.TURNS_VARIABLE, context.temp_allocator)
	if !in_pane || directory == "" {return .Ok}
	pane_key, has_key := os.lookup_env(PANE_KEY_VARIABLE, context.temp_allocator)
	if !has_key || pane_key == "" {return .Ok}
	if !recording_live(directory) {return .Ok}
	processes, snapshot_error := procinfo.process_snapshot(context.temp_allocator)
	if snapshot_error != .None {return .Ok}
	if agent.ancestry_nested(hook_ancestors(processes, u32(os.get_pid()))) {return .Ok}
	input, read_error := os.read_entire_file_from_file(os.stdin, context.temp_allocator)
	if read_error != nil {return .Ok}
	payload, parsed := agent.turn_payload(harness, kind, input, context.temp_allocator)
	if !parsed {return .Ok}
	// An edit that names no path has nothing to snapshot.
	if kind == .Edit && len(payload.paths) == 0 {return .Ok}
	now := time.now()
	names := agent.HARNESS_NAMES
	text, encoded := turns.hook_event_encode(
		{
			pane_key = pane_key,
			harness = names[harness],
			session = payload.session,
			cwd = payload.cwd,
			prompt = payload.prompt,
			kind = kind,
			paths = payload.paths,
			written = time.to_unix_nanoseconds(now) / i64(time.Millisecond),
		},
		context.temp_allocator,
	)
	if !encoded {return .Ok}
	name := fmt.tprintf("%s-%020d.json", pane_key, time.to_unix_nanoseconds(now))
	inbox, join_error := filepath.join({directory, turns.INBOX_DIRECTORY}, context.temp_allocator)
	if join_error != nil {return .Ok}
	path, path_error := filepath.join({inbox, name}, context.temp_allocator)
	if path_error != nil {return .Ok}
	if !event_write(inbox, path, text) {return .Ok}
	if kind == .Stop {return .Ok}
	started := time.tick_now()
	for os.exists(path) && time.tick_since(started) < TURN_HOOK_WAIT {time.sleep(TURN_HOOK_POLL)}
	return .Ok
}

@(private, require_results)
turn_hook_kind :: proc(word: string) -> (turns.Hook_Kind, bool) {
	switch word {
	case "prompt":
		return .Prompt, true
	case "stop":
		return .Stop, true
	case "edit":
		return .Edit, true
	}
	return .Prompt, false
}

// Whether the recording marker names an AIODev process that is still running.
@(private, require_results)
recording_live :: proc(directory: string) -> bool {
	marker, join_error := filepath.join({directory, turns.RECORDING_MARKER}, context.temp_allocator)
	if join_error != nil {return false}
	data, read_error := os.read_entire_file(marker, context.temp_allocator)
	if read_error != nil {return false}
	pid, decoded := turns.marker_decode(data)
	return decoded && process_alive(pid)
}

@(private, require_results)
process_alive :: proc(pid: u32) -> bool {
	process := w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if process == nil {return false}
	defer w.CloseHandle(process)
	code: w.DWORD
	return bool(w.GetExitCodeProcess(process, &code)) && code == STILL_ACTIVE
}

// Writes the event whole under a name AIODev does not read, then renames it, so AIODev never reads half
// of one. Silent on failure: there is nowhere to report it that the model does not see.
@(private, require_results)
event_write :: proc(inbox, path, text: string) -> bool {
	if os.mkdir_all(inbox) != nil {return false}
	temp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(temp, text) != nil {
		_ = os.remove(temp)
		return false
	}
	if os.rename(temp, path) != nil {
		_ = os.remove(temp)
		return false
	}
	return true
}
