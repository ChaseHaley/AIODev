package app_test

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:agent"
import "aio:commands"
import "aio:layout"
import "aio:platform"
import "aio:procinfo"
import "aio:term"

@(private = "file")
SESSION :: "81b3816b-4fce-4b04-b3bf-9f40b8d2172e"

@(private = "file")
invoke :: proc(state: ^app.App, args: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Control_Request{0}, invocation)
}

// Waits until the pane's screen shows `text`, ticking the app meanwhile. Rows are joined, so text the
// narrow pane wraps still matches. A tick frees temporary memory, so the pane id is kept on the heap.
@(private = "file")
screen_shows :: proc(state: ^app.App, pane: u32, text: string) -> bool {
	id := fmt.aprintf("%d", pane)
	defer delete(id)
	for start := time.tick_now(); time.tick_since(start) < 15 * time.Second; {
		app.tick(state)
		read := invoke(state, "pane.read", "--pane", id)
		if read.status == .Ok {
			joined, _ := strings.remove_all(string(read.payload.(app.Outcome_Text)), "\n", context.temp_allocator)
			if strings.contains(joined, text) {return true}
		}
		time.sleep(50 * time.Millisecond)
	}
	return false
}

// Runs a copy of the idle fixture named after an agent in the pane's cmd, and returns its process id.
@(private = "file")
agent_start :: proc(t: ^testing.T, state: ^app.App, entry: ^app.Session_Entry, program, arguments: string) -> u32 {
	sent := invoke(state, "pane.send", "--pane", fmt.tprintf("%d", entry.id), "--enter", fmt.tprintf(`"%s" %s`, program, arguments))
	testing.expectf(t, sent.status == .Ok, "pane.send: %s", sent.message)
	return agent_child(t, entry, filepath.base(program))
}

// The process named `name` that the pane's shell started, once it appears.
@(private = "file")
agent_child :: proc(t: ^testing.T, entry: ^app.Session_Entry, name: string) -> u32 {
	root := term.process_id(entry.session)
	for start := time.tick_now(); time.tick_since(start) < 15 * time.Second; {
		processes, err := procinfo.process_snapshot(context.temp_allocator)
		if err == .None {
			for p in processes {
				if p.parent == root && strings.equal_fold(p.executable, name) {return p.id}
			}
		}
		time.sleep(50 * time.Millisecond)
	}
	testing.expectf(t, false, "%s did not start in the pane", name)
	return 0
}

// The resume line the layout saves for the pane with `key`.
@(private = "file")
saved_resume :: proc(t: ^testing.T, state: ^app.App, key: string) -> string {
	processes, _ := procinfo.process_snapshot(context.temp_allocator)
	text, ok := app.layout_state_encode(state, context.temp_allocator, processes)
	testing.expect(t, ok)
	marker := fmt.tprintf(`"key": "%s"`, key)
	at := strings.index(text, marker)
	if !testing.expect(t, at >= 0) {return ""}
	rest := text[at:]
	end := strings.index(rest, "}")
	if end >= 0 {rest = rest[:end]}
	start := strings.index(rest, `"resume": "`)
	if start < 0 {return ""}
	rest = rest[start + len(`"resume": "`):]
	return rest[:strings.index_byte(rest, '"')]
}

@(private = "file")
write_file :: proc(t: ^testing.T, path, text: string) {
	testing.expect_value(t, os.make_directory_all(filepath.dir(path)), nil)
	testing.expect_value(t, os.write_entire_file(path, text), nil)
}

@(test)
agent_panes_resume_their_session_on_reopen :: proc(t: ^testing.T) {
	// App ticks free temporary memory, so strings the test keeps across them live in this arena.
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) {return}
	defer virtual.arena_destroy(&arena)
	keep := virtual.arena_allocator(&arena)
	directory, directory_error := os.make_directory_temp("", "aio-agent-*", keep)
	if !testing.expect_value(t, directory_error, nil) {return}
	defer testing.expect_value(t, os.remove_all(directory), nil)
	fixture, _ := os.get_executable_directory(context.temp_allocator)
	idle, _ := os.read_entire_file(fmt.tprintf("%s/idle-shell.exe", fixture), context.temp_allocator)
	programs := fmt.aprintf(`%s\bin`, directory, allocator = keep)
	for name in ([?]string{"claude", "codex", "omp"}) {
		write_file(t, fmt.tprintf(`%s\%s.exe`, programs, name), string(idle))
	}
	// The harnesses' own folders, redirected into the test directory, and a PATH holding only the
	// fixtures and cmd's folder, so a typed resume line never starts a real agent.
	system := os.get_env("SystemRoot", context.temp_allocator)
	claude_home := fmt.aprintf(`%s\claude`, directory, allocator = keep)
	codex_home := fmt.aprintf(`%s\codex`, directory, allocator = keep)
	omp_home := fmt.aprintf(`%s\omp`, directory, allocator = keep)
	redirected := [?][2]string {
		{"CLAUDE_CONFIG_DIR", claude_home},
		{"CODEX_HOME", codex_home},
		{"PI_CODING_AGENT_DIR", omp_home},
		{"PATH", fmt.aprintf(`%s;%s\System32`, programs, system, allocator = keep)},
	}
	previous: [len(redirected)]Maybe(string)
	for pair, i in redirected {
		if value, found := os.lookup_env(pair[0], keep); found {previous[i] = value}
		testing.expect_value(t, os.set_env(pair[0], pair[1]), nil)
	}
	defer for pair, i in redirected {
		if value, found := previous[i].?; found {_ = os.set_env(pair[0], value)} else {os.unset_env(pair[0])}
	}
	settings := "shell.command = cmd.exe /d\ntabs.program_icons = false\n" +
		"interface.confirm = shell_switch, multiline_paste\ncursor.blink = false\n"
	write_file(t, fmt.tprintf("%s/settings.ini", directory), settings)
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.AgentResume.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	testing.expect(t, state.settings.pane.resume_agents, "resuming agents is on by default")
	w := state.windows[0]
	workspace := w.workspace
	entry := &state.sessions[0]
	key := strings.clone(entry.key, keep)
	testing.expect(t, app.pane_key_valid(key))
	record_path, _ := filepath.join({state.paths.agents, fmt.tprintf("%s.json", key)}, keep)

	// The shell learns the pane's key and record file.
	shown := fmt.aprintf("[%s] [%s]", key, record_path, allocator = keep)
	invoke(&state, "pane.send", "--pane", fmt.tprintf("%d", entry.id), "--enter", "echo [%TERM_SESSION_ID%] [%AIODEV_AGENT_RECORD%]")
	testing.expect(t, screen_shows(&state, entry.id, shown))
	original := entry.id
	app.pane_split(&state, w, .Right, 0.5)
	entry = app.session_find(&state, original)
	if !testing.expect(t, entry != nil && entry.key == key) {return}

	// Claude Code: its hook's record names the session, but only for the process that wrote it.
	claude := agent_start(t, &state, entry, fmt.tprintf(`%s\claude.exe`, programs), `--model opus "fix the tests"`)
	testing.expect_value(t, saved_resume(t, &state, key), "")
	other, _ := agent.record_encode({"claude", SESSION, {claude + 1}}, context.temp_allocator)
	write_file(t, record_path, other)
	testing.expect_value(t, saved_resume(t, &state, key), "")
	owned, _ := agent.record_encode({"claude", SESSION, {4, claude, 8}}, keep)
	write_file(t, record_path, owned)
	want := "claude --model opus --resume " + SESSION
	testing.expect_value(t, saved_resume(t, &state, key), want)
	state.settings.pane.resume_agents = false
	testing.expect_value(t, saved_resume(t, &state, key), "")
	state.settings.pane.resume_agents = true
	// Without a record, Claude Code's own registry entry for the process names it.
	testing.expect_value(t, os.remove(record_path), nil)
	write_file(t, fmt.tprintf(`%s\sessions\%d.json`, claude_home, claude), `{"pid":1,"sessionId":"c1a0"}`)
	testing.expect_value(t, saved_resume(t, &state, key), "claude --model opus --resume c1a0")
	write_file(t, record_path, owned)

	// Closing and reopening the pane brings it back with its key, typing the resume line into the shell.
	app.pane_close_at(&state, workspace, 0, layout.Node_Id(0))
	if !testing.expect_value(t, len(state.closed), 1) {return}
	testing.expect(t, strings.contains(state.closed[0].text, fmt.tprintf(`"resume":"%s"`, want)))
	app.closed_reopen(&state, w)
	reopened: ^app.Session_Entry
	for &candidate in state.sessions {
		if candidate.key == key {reopened = &candidate}
	}
	if !testing.expect(t, reopened != nil, "the reopened pane keeps its key") {return}
	testing.expect(t, screen_shows(&state, reopened.id, want))
	// The typed line started the fixture again, resuming the recorded session.
	resumed := agent_child(t, reopened, "claude.exe")
	arguments, _ := procinfo.process_arguments(resumed, term.process_id(reopened.session), context.temp_allocator)
	testing.expectf(t, len(arguments) == 5 && arguments[3] == "--resume" && arguments[4] == SESSION, "%v", arguments)

	// omp: its breadcrumb for the pane's key names the session file.
	other_pane := &state.sessions[0]
	other_key := strings.clone(other_pane.key, keep)
	omp := agent_start(t, &state, other_pane, fmt.tprintf(`%s\omp.exe`, programs), "--thinking high explain")
	testing.expect(t, omp != 0)
	testing.expect_value(t, saved_resume(t, &state, other_key), "")
	session_file := fmt.tprintf(`%s\sessions\-w\2026-11-08T23-43-39-835Z_01a1bd8b-d33b.jsonl`, omp_home)
	write_file(t, session_file, "{}\n")
	crumb := fmt.tprintf(`%s\terminal-sessions\apple-%s`, omp_home, other_key)
	write_file(t, crumb, fmt.tprintf("C:\\w\n%s\n", session_file))
	testing.expect_value(t, saved_resume(t, &state, other_key), "omp --thinking high --resume 01a1bd8b-d33b")
	testing.expect_value(t, os.remove(session_file), nil)
	testing.expect_value(t, saved_resume(t, &state, other_key), "") // the breadcrumb's session file is gone

	// Codex without a hook record: the one interactive rollout begun in its directory since it started.
	split := invoke(&state, "pane.split", "--pane", fmt.tprintf("%d", other_pane.id))
	if !testing.expect(t, split.status == .Ok) {return}
	codex_pane := app.session_find(&state, split.payload.(app.Outcome_Created).pane)
	codex_key := strings.clone(codex_pane.key, keep)
	codex := agent_start(t, &state, codex_pane, fmt.tprintf(`%s\codex.exe`, programs), "-m gpt-5")
	codex_directory, _ := procinfo.process_directory(codex, term.process_id(codex_pane.session), context.temp_allocator)
	year, month, day := time.date(time.now())
	folder := fmt.tprintf(`%s\sessions\%04d\%02d\%02d`, codex_home, year, int(month), day)
	stamp, _ := time.time_to_rfc3339(time.now(), 0, true, context.temp_allocator)
	cwd, _ := strings.replace_all(codex_directory, `\`, `\\`, context.temp_allocator)
	rollout := strings.concatenate({`{"type":"session_meta","payload":{"id":"01a1c0de","cwd":"`, cwd, `","timestamp":"`, stamp, `","originator":"codex-tui","source":"cli"}}`, "\n"}, context.temp_allocator)
	write_file(t, fmt.tprintf(`%s\rollout-a.jsonl`, folder), rollout)
	testing.expect_value(t, saved_resume(t, &state, codex_key), "codex resume -m gpt-5 01a1c0de")
	second, _ := strings.replace_all(rollout, "01a1c0de", "01a1beef", context.temp_allocator)
	write_file(t, fmt.tprintf(`%s\rollout-b.jsonl`, folder), second)
	testing.expect_value(t, saved_resume(t, &state, codex_key), "") // two candidates name no session
}
