package main

import "aio:agent"
import "aio:procinfo"
import "aio:program_art"
import "aio:pty"
import "aio:term"
import "core:crypto"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Resuming the coding agent a pane runs (WORK-361, the D-020 amendment). Each terminal pane has a key
// that lasts through reopen and restart. Its shell gets TERM_SESSION_ID set to the key, where omp's
// per-terminal breadcrumb records the pane's session, and AIODEV_AGENT_RECORD, the file that
// `aio agent-session` writes from a Claude Code or Codex SessionStart hook. Saving the layout or
// recording a close turns the pane's session into a resume line, which restoring the pane types into
// its fresh shell.

PANE_KEY_LENGTH :: 32

@(private)
TERM_SESSION_VARIABLE :: "TERM_SESSION_ID"

// A Codex program running longer than this is not matched to a rollout by its start time.
@(private)
ROLLOUT_SEARCH_DAYS :: 7

// Keys are lowercase hexadecimal, so they are safe in file names and environment values.
pane_key_valid :: proc(key: string) -> bool {
	if len(key) != PANE_KEY_LENGTH {return false}
	for i in 0 ..< len(key) {
		switch key[i] {
		case '0' ..= '9', 'a' ..= 'f':
		case:
			return false
		}
	}
	return true
}

// The key a new session takes: `wanted` when it is valid and no open session holds it, else a new one.
@(private, require_results)
pane_key_claim :: proc(app: ^App, wanted: string) -> (string, bool) {
	if pane_key_valid(wanted) {
		held := false
		for &entry in app.sessions {
			if entry.key == wanted {held = true; break}
		}
		if !held {
			key, err := strings.clone(wanted)
			return key, err == nil
		}
	}
	random: [PANE_KEY_LENGTH / 2]u8
	crypto.rand_bytes(random[:])
	key, err := make([]u8, PANE_KEY_LENGTH)
	if err != nil {return "", false}
	digits := "0123456789abcdef"
	for b, i in random {
		key[2 * i], key[2 * i + 1] = digits[b >> 4], digits[b & 15]
	}
	return string(key), true
}

// The variables a pane's shell gets for agent resume, in temporary memory.
@(private)
agent_environment :: proc(app: ^App, key: string, environment: ^[dynamic]pty.Env_Var) {
	append(environment, pty.Env_Var{TERM_SESSION_VARIABLE, key})
	if record := agent_record_path(app, key); record != "" {
		append(environment, pty.Env_Var{agent.RECORD_VARIABLE, record})
	}
}

// The file the pane's agent session hook writes, in temporary memory; empty without an agent record
// directory, as in tests.
@(private)
agent_record_path :: proc(app: ^App, key: string) -> string {
	if app.paths.agents == "" || key == "" {return ""}
	path, err := filepath.join({app.paths.agents, fmt.tprintf("%s.json", key)}, context.temp_allocator)
	return err == nil ? path : ""
}

// The agent a pane runs, as resuming it needs: how it was launched, its process and the pane shell's.
@(private)
Pane_Agent :: struct {
	launch:  agent.Launch,
	program: u32,
	root:    u32,
}

// The command that resumes the agent the pane runs, in temporary memory; empty when resuming is off,
// the pane runs no agent, its launch keeps no session or its session cannot be told.
pane_resume_line :: proc(app: ^App, entry: ^Session_Entry, processes: []procinfo.Process_Info) -> string {
	if !app.settings.pane.resume_agents {return ""}
	running := pane_agent(app, entry, processes)
	if !running.launch.resumable {return ""}
	session, found := agent_session(app, entry, running)
	if !found {return ""}
	return agent.resume_line(running.launch, session, context.temp_allocator)
}

// Types a saved resume line into a restored pane's fresh shell, which reads it once its prompt is up.
@(private)
pane_resume :: proc(app: ^App, entry: ^Session_Entry, line: string) {
	if line == "" || !app.settings.pane.resume_agents {return}
	if !agent.resume_line_valid(line) {
		log.warn("ignoring a saved agent resume line that AIODev did not write")
		return
	}
	if outcome := pane_send(entry, line, true); outcome.status != .Ok {
		log.errorf("typing the agent resume line failed: %s", outcome.message)
	}
}

// The harness a program's name or bundled artwork names.
@(private)
program_harness :: proc(app: ^App, name: string) -> agent.Harness {
	if art, found := program_art_find(app, name); found {
		return agent.harness_named(program_art.canonical(art))
	}
	return agent.harness_named(name)
}

// How an agent program was launched, as resuming it keeps it, with its strings in `allocator`; a zero
// launch for any other program. launch_release frees one kept beyond temporary memory.
@(private)
program_launch :: proc(
	app: ^App,
	arguments: []string,
	stem: string,
	allocator := context.allocator,
) -> agent.Launch {
	name, rest := program_invocation(arguments, stem)
	harness := program_harness(app, name)
	if harness == .None {return {}}
	parsed := agent.launch_parse(harness, rest, context.temp_allocator)
	launch := agent.Launch {
		harness   = parsed.harness,
		resumable = parsed.resumable,
		profile   = strings.clone(parsed.profile, allocator),
	}
	if parsed.flags != nil {
		launch.flags = make([]string, len(parsed.flags), allocator)
		for flag, i in parsed.flags {launch.flags[i] = strings.clone(flag, allocator)}
	}
	return launch
}

@(private)
launch_release :: proc(launch: ^agent.Launch) {
	for flag in launch.flags {delete(flag)}
	delete(launch.flags)
	delete(launch.profile)
	launch^ = {}
}

// The agent the pane runs now: polling's adopted program and the launch read when it was adopted, or
// without polling the program `processes` names, read now.
@(private)
pane_agent :: proc(app: ^App, entry: ^Session_Entry, processes: []procinfo.Process_Info) -> Pane_Agent {
	root := term.process_id(entry.session)
	if program_polling(app) {
		adopted := program_adopted(entry)
		if adopted == nil || adopted.id != program_polled(entry) {return {}}
		return {launch = adopted.launch, program = adopted.id, root = root}
	}
	program, _ := pane_running(app, entry, processes)
	if program == 0 {return {}}
	stem: string
	for p in processes {
		if p.id == program {stem = procinfo.executable_stem(p.executable); break}
	}
	arguments, read := procinfo.process_arguments(program, root, context.temp_allocator)
	if !read {return {}}
	launch := program_launch(app, arguments, stem, context.temp_allocator)
	return {launch = launch, program = program, root = root}
}

// The session the pane's agent is in. omp's breadcrumb names it; for Claude Code and Codex the hook's
// record does, else a source that names exactly one session.
@(private)
agent_session :: proc(app: ^App, entry: ^Session_Entry, running: Pane_Agent) -> (string, bool) {
	switch running.launch.harness {
	case .Omp:
		return omp_session(entry.key, running.launch.profile)
	case .Claude, .Codex:
		if session, found := hooked_session(app, entry.key, running); found {return session, true}
		if running.launch.harness == .Claude {return claude_registered_session(running.program)}
		return codex_rollout_session(entry, running)
	case .None:
	}
	return "", false
}

@(private)
hooked_session :: proc(app: ^App, key: string, running: Pane_Agent) -> (string, bool) {
	path := agent_record_path(app, key)
	if path == "" {return "", false}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return "", false}
	record, ok := agent.record_parse(data)
	if !ok || !agent.record_owned(record, running.launch.harness, running.program) {return "", false}
	return record.session, true
}

// The user's home directory, in temporary memory; empty when unknown.
@(private)
home_directory :: proc() -> string {
	return os.get_env("USERPROFILE", context.temp_allocator)
}

// omp keeps a profile's sessions under ~/.omp/profiles/<name>/agent, and the default profile's under
// PI_CODING_AGENT_DIR or ~/.omp/agent.
@(private)
omp_agent_directory :: proc(profile: string) -> string {
	home := home_directory()
	if profile != "" {
		if home == "" || strings.contains(profile, "..") || strings.index_any(profile, `\/:`) >= 0 {return ""}
		path, _ := filepath.join({home, ".omp", "profiles", profile, "agent"}, context.temp_allocator)
		return path
	}
	if custom := os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator); custom != "" {return custom}
	if home == "" {return ""}
	path, _ := filepath.join({home, ".omp", "agent"}, context.temp_allocator)
	return path
}

@(private)
omp_session :: proc(key, profile: string) -> (string, bool) {
	directory := omp_agent_directory(profile)
	if directory == "" || key == "" {return "", false}
	name := agent.breadcrumb_name(key, context.temp_allocator)
	path, _ := filepath.join({directory, "terminal-sessions", name}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return "", false}
	id, file, ok := agent.breadcrumb_session(string(data))
	// A fresh session that has not written its file yet has nothing to resume.
	return id, ok && os.exists(file)
}

// Claude Code's registry of running sessions, one file per process; read only without a hook record.
@(private)
claude_registered_session :: proc(program: u32) -> (string, bool) {
	directory := os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator)
	if directory == "" {
		home := home_directory()
		if home == "" {return "", false}
		directory, _ = filepath.join({home, ".claude"}, context.temp_allocator)
	}
	path, _ := filepath.join({directory, "sessions", fmt.tprintf("%d.json", program)}, context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {return "", false}
	return agent.claude_registry_session(data)
}

// The Codex rollout begun in the program's directory since it started, read only without a hook
// record. Rollouts are filed by local date, so the days around the start are searched.
@(private)
codex_rollout_session :: proc(entry: ^Session_Entry, running: Pane_Agent) -> (string, bool) {
	started, known := procinfo.process_started(running.program, running.root)
	if !known {return "", false}
	now := time.now()
	if time.diff(started, now) > ROLLOUT_SEARCH_DAYS * 24 * time.Hour {return "", false}
	directory, _ := pane_directory_of(entry, running.program)
	if directory == "" {return "", false}
	home := os.get_env("CODEX_HOME", context.temp_allocator)
	if home == "" {
		user := home_directory()
		if user == "" {return "", false}
		home, _ = filepath.join({user, ".codex"}, context.temp_allocator)
	}
	rollouts := make([dynamic]agent.Rollout, 0, 16, context.temp_allocator)
	for day := time.time_add(started, -24 * time.Hour);
	    time.diff(day, time.time_add(now, 24 * time.Hour)) >= 0;
	    day = time.time_add(day, 24 * time.Hour) {
		year, month, date := time.date(day)
		folder, _ := filepath.join(
			{home, "sessions", fmt.tprintf("%04d", year), fmt.tprintf("%02d", int(month)), fmt.tprintf("%02d", date)},
			context.temp_allocator,
		)
		files, list_error := os.read_all_directory_by_path(folder, context.temp_allocator)
		if list_error != nil {continue}
		for file in files {
			if !strings.has_prefix(file.name, "rollout-") || !strings.has_suffix(file.name, ".jsonl") {continue}
			if rollout, ok := rollout_first_line(file.fullpath); ok {append(&rollouts, rollout)}
		}
	}
	return agent.rollout_pick(rollouts[:], directory, started)
}

@(private)
rollout_first_line :: proc(path: string) -> (agent.Rollout, bool) {
	f, err := os.open(path)
	if err != nil {return {}, false}
	defer os.close(f)
	buffer := make([]u8, agent.RECORD_LIMIT, context.temp_allocator)
	n, _ := os.read(f, buffer)
	line := buffer[:n]
	if newline := strings.index_byte(string(line), '\n'); newline >= 0 {line = line[:newline]}
	return agent.rollout_parse(line)
}

// Removes the records of panes that did not come back, once startup has restored the layout. The
// directory itself is made by the first hook that writes a record.
agent_records_prune :: proc(app: ^App) {
	if app.paths.agents == "" || !os.is_dir(app.paths.agents) {return}
	files, err := os.read_all_directory_by_path(app.paths.agents, context.temp_allocator)
	if err != nil {
		log.errorf("listing the agent session records failed: %v", err)
		return
	}
	for file in files {
		key := strings.trim_suffix(file.name, ".json")
		held := false
		for &entry in app.sessions {
			if entry.key == key {held = true; break}
		}
		if held {continue}
		if remove_error := os.remove(file.fullpath); remove_error != nil {
			log.errorf("removing the agent session record %s failed: %v", file.name, remove_error)
		}
	}
}

// Seconds a SessionStart hook may take; recording a session takes milliseconds.
@(private)
HOOK_TIMEOUT_SECONDS :: 10

// How installing one harness's hook went.
@(private)
Hook_Outcome :: enum u8 {
	Added,
	Present,
	// The harness's settings directory does not exist, so it is not installed.
	Absent,
	// Its settings file is not JSON of the expected shape, so it was left alone.
	Unreadable,
	Failed,
}

// Adds a SessionStart hook running `aio agent-session` to Claude Code's settings.json and Codex's
// hooks.json, for each harness whose settings directory exists. Claude Code runs hooks in Git Bash and
// Codex in PowerShell, so the two commands quote aio's path for those shells.
agent_hooks_install :: proc(app: ^App) {
	if app.cli_directory == "" {
		notify(app, .Error, "aio.exe is not beside AIODev, so the agent session hooks cannot run it.")
		return
	}
	aio, _ := filepath.join({app.cli_directory, CLI_EXECUTABLE}, context.temp_allocator)
	aio, _ = strings.replace_all(aio, `\`, "/", context.temp_allocator)
	if strings.index_any(aio, "\"$`'%") >= 0 {
		notify(app, .Error, "AIODev's folder name has characters a hook command cannot quote.")
		return
	}
	claude := hook_install_file(
		harness_directory("CLAUDE_CONFIG_DIR", ".claude"),
		"settings.json",
		fmt.tprintf(`"%s" agent-session claude`, aio),
	)
	codex := hook_install_file(
		harness_directory("CODEX_HOME", ".codex"),
		"hooks.json",
		fmt.tprintf(`& "%s" agent-session codex`, aio),
	)
	text := fmt.tprintf("Claude Code: %s. Codex: %s.", hook_outcome_text(claude), hook_outcome_text(codex))
	if codex == .Added {
		text = fmt.tprintf("%s Approve the new hook once with /hooks in Codex.", text)
	}
	failed := claude == .Failed || claude == .Unreadable || codex == .Failed || codex == .Unreadable
	notify(app, failed ? .Error : .Info, text)
}

// A harness's settings directory: the variable that moves it, else the named folder in the user's home;
// in temporary memory, empty when unknown.
@(private)
harness_directory :: proc(variable, folder: string) -> string {
	if custom := os.get_env(variable, context.temp_allocator); custom != "" {return custom}
	home := home_directory()
	if home == "" {return ""}
	path, _ := filepath.join({home, folder}, context.temp_allocator)
	return path
}

@(private)
hook_install_file :: proc(directory, file, command: string) -> Hook_Outcome {
	if directory == "" || !os.is_dir(directory) {return .Absent}
	path, _ := filepath.join({directory, file}, context.temp_allocator)
	text: string
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			log.errorf("reading %s failed: %v", path, err)
			return .Failed
		}
		text = string(data)
	}
	result, change := agent.hooks_install(text, command, HOOK_TIMEOUT_SECONDS, context.temp_allocator)
	switch change {
	case .Present:
		return .Present
	case .Invalid:
		return .Unreadable
	case .Added:
	}
	if !file_replace(path, result) {return .Failed}
	return .Added
}

@(private)
hook_outcome_text :: proc(outcome: Hook_Outcome) -> string {
	switch outcome {
	case .Added:
		return "hook added"
	case .Present:
		return "hook already installed"
	case .Absent:
		return "not installed for this user"
	case .Unreadable:
		return "settings file left unchanged because it could not be read as JSON"
	case .Failed:
		return "could not write its settings file"
	}
	return ""
}
