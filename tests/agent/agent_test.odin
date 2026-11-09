package agent_test

import "aio:agent"
import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
harnesses_are_named_by_canonical_program_name :: proc(t: ^testing.T) {
	testing.expect_value(t, agent.harness_named("claude"), agent.Harness.Claude)
	testing.expect_value(t, agent.harness_named("Codex"), agent.Harness.Codex)
	testing.expect_value(t, agent.harness_named("omp"), agent.Harness.Omp)
	testing.expect_value(t, agent.harness_named("pwsh"), agent.Harness.None)
	testing.expect_value(t, agent.harness_named(""), agent.Harness.None)
}

@(test)
session_ids_are_plain_tokens :: proc(t: ^testing.T) {
	testing.expect(t, agent.session_id_valid("81b3816b-4fce-4b04-b3bf-9f40b8d2172e"))
	testing.expect(t, agent.session_id_valid("01a1bd8b_d33b"))
	for id in ([?]string{"", "a b", "a;b", "$x", "a\"b", strings.repeat("a", 129, context.temp_allocator)}) {
		testing.expectf(t, !agent.session_id_valid(id), "%q should be refused", id)
	}
}

@(private)
Launch_Case :: struct {
	harness:   agent.Harness,
	arguments: []string,
	resumable: bool,
	flags:     []string,
}

@(test)
launches_keep_their_options_and_drop_prompts_and_session_choices :: proc(t: ^testing.T) {
	cases := [?]Launch_Case {
		{.Claude, {"--dangerously-skip-permissions", "--model", "opus", "fix the tests"}, true,
			{"--dangerously-skip-permissions", "--model", "opus"}},
		// A pane already resumed keeps its options through the next close.
		{.Claude, {"--dangerously-skip-permissions", "--resume", "81b3816b"}, true,
			{"--dangerously-skip-permissions"}},
		{.Claude, {"-c", "--model=sonnet"}, true, {"--model=sonnet"}},
		{.Claude, {"--add-dir", `C:\work`, `C:\notes`, "--verbose"}, true,
			{"--add-dir", `C:\work`, `C:\notes`, "--verbose"}},
		{.Claude, {"--session-id", "abc", "--fork-session", "hello"}, true, nil},
		{.Claude, {"--debug", "--model", "opus"}, true, {"--debug", "--model", "opus"}},
		{.Claude, {"--model", "opus", "--", "--literal prompt"}, true, {"--model", "opus"}},
		{.Codex, {"-m", "gpt-5", "do the thing"}, true, {"-m", "gpt-5"}},
		{.Codex, {"resume", "01a1bd97-e43e", "--dangerously-bypass-approvals-and-sandbox"}, true,
			{"--dangerously-bypass-approvals-and-sandbox"}},
		{.Codex, {"resume", "--last"}, true, nil},
		{.Codex, {"fork", "--last", "-s", "workspace-write", "and continue"}, true, {"-s", "workspace-write"}},
		{.Omp, {"-c"}, true, nil},
		{.Omp, {"--model", "opus", "--thinking", "high", "explain this"}, true,
			{"--model", "opus", "--thinking", "high"}},
		{.Omp, {"--resume", "01a1bd8b"}, true, nil},
	}
	for c in cases {
		launch := agent.launch_parse(c.harness, c.arguments, context.temp_allocator)
		testing.expectf(t, launch.resumable == c.resumable, "%v: resumable %v", c.arguments, launch.resumable)
		testing.expectf(t, slice.equal(launch.flags, c.flags), "%v: kept %v, want %v", c.arguments, launch.flags, c.flags)
	}
}

@(test)
launches_without_an_interactive_session_are_not_resumed :: proc(t: ^testing.T) {
	cases := [?]struct {
		harness:   agent.Harness,
		arguments: []string,
	} {
		{.Claude, {"-p", "summarize"}},
		{.Claude, {"--model", "opus", "--print", "x"}},
		{.Claude, {"--no-session-persistence"}},
		{.Claude, {"doctor"}},
		{.Claude, {"--bg"}},
		{.Codex, {"exec", "run the tests"}},
		{.Codex, {"-m", "gpt-5", "review"}},
		{.Omp, {"-p", "hi"}},
		{.Omp, {"--no-session"}},
		{.Omp, {"config", "list"}},
		{.Omp, {"--mode", "rpc"}},
		{.None, {}},
	}
	for c in cases {
		launch := agent.launch_parse(c.harness, c.arguments, context.temp_allocator)
		testing.expectf(t, !launch.resumable, "%v %v should not be resumed", c.harness, c.arguments)
		testing.expect(t, launch.flags == nil)
	}
}

// An option the table does not know, or a value a shell would read differently, leaves only the
// session id: the next argument could be its value or a prompt.
@(test)
unclassified_or_unsafe_arguments_fall_back_to_the_session_alone :: proc(t: ^testing.T) {
	cases := [?]struct {
		harness:   agent.Harness,
		arguments: []string,
	} {
		{.Claude, {"--model", "opus", "--brand-new-option", "value"}},
		{.Claude, {"--settings", `{"a":1}`}},
		{.Claude, {"--append-system-prompt", "use $HOME"}},
		{.Claude, {"--add-dir", `C:\trailing\`}},
		{.Codex, {"--full-auto"}},
		{.Codex, {"-c", `model="o3"`}},
		{.Omp, {"--verbose=yes"}},
	}
	for c in cases {
		launch := agent.launch_parse(c.harness, c.arguments, context.temp_allocator)
		testing.expectf(t, launch.resumable, "%v should still resume", c.arguments)
		testing.expectf(t, launch.flags == nil, "%v kept %v", c.arguments, launch.flags)
	}
}

@(test)
omp_profile_is_read_even_when_only_the_session_is_kept :: proc(t: ^testing.T) {
	launch := agent.launch_parse(.Omp, {"--profile", "work", "--odd"}, context.temp_allocator)
	testing.expect_value(t, launch.profile, "work")
	testing.expect(t, launch.flags == nil)
	launch = agent.launch_parse(.Omp, {"--profile=home"}, context.temp_allocator)
	testing.expect_value(t, launch.profile, "home")
}

@(test)
resume_lines_follow_each_harness :: proc(t: ^testing.T) {
	claude := agent.Launch {
		harness   = .Claude,
		resumable = true,
		flags     = {"--dangerously-skip-permissions", "--add-dir", `C:\My Work`, "--tools", "Bash,Edit"},
	}
	testing.expect_value(
		t,
		agent.resume_line(claude, "81b3", context.temp_allocator),
		`claude --dangerously-skip-permissions --add-dir "C:\My Work" --tools "Bash,Edit" --resume 81b3`,
	)
	codex := agent.Launch {
		harness   = .Codex,
		resumable = true,
		flags     = {"-m", "gpt-5"},
	}
	testing.expect_value(t, agent.resume_line(codex, "01a1", context.temp_allocator), "codex resume -m gpt-5 01a1")
	omp := agent.Launch {
		harness   = .Omp,
		resumable = true,
	}
	testing.expect_value(t, agent.resume_line(omp, "01a1", context.temp_allocator), "omp --resume 01a1")
}

@(test)
saved_resume_lines_must_be_ones_resume_line_writes :: proc(t: ^testing.T) {
	for line in ([?]string {
		`claude --dangerously-skip-permissions --add-dir "C:\My Work" --resume 81b3`,
		"codex resume -m gpt-5 01a1",
		"codex resume 01a1",
		"omp --resume 01a1",
	}) {
		testing.expectf(t, agent.resume_line_valid(line), "%q should be accepted", line)
	}
	for line in ([?]string {
		"",
		"claude --resume",
		"claude --resume 81b3; del x",
		"claude --resume 81b3 & calc",
		"pwsh -c calc --resume 81b3",
		"Claude --resume 81b3",
		"codex 01a1 x",
		`claude --model "unterminated --resume 81b3`,
		"claude --append-system-prompt $env:x --resume 81b3",
		"omp --resume 01a1 --model x",
	}) {
		testing.expectf(t, !agent.resume_line_valid(line), "%q should be refused", line)
	}
}

@(test)
hook_payloads_name_their_session :: proc(t: ^testing.T) {
	claude := `{"session_id":"81b3816b-4fce-4b04-b3bf-9f40b8d2172e","transcript_path":"C:\\x.jsonl",` +
		`"cwd":"C:\\w","hook_event_name":"SessionStart","source":"startup"}`
	id, ok := agent.hook_session(transmute([]u8)claude)
	testing.expect(t, ok)
	testing.expect_value(t, id, "81b3816b-4fce-4b04-b3bf-9f40b8d2172e")
	codex := `{"session_id":"01a1bd97-e43e-7a83-9f90-64c7b64ff0f2","model":"gpt","source":"resume"}` + "\r\n"
	id, ok = agent.hook_session(transmute([]u8)codex)
	testing.expect(t, ok)
	testing.expect_value(t, id, "01a1bd97-e43e-7a83-9f90-64c7b64ff0f2")
	for bad in ([?]string{"", "{}", `{"session_id":"a b"}`, "not json", `{"session_id":7}`}) {
		_, ok = agent.hook_session(transmute([]u8)bad)
		testing.expectf(t, !ok, "%q should name no session", bad)
	}
}

@(test)
records_round_trip_and_count_only_for_their_agent :: proc(t: ^testing.T) {
	text, encoded := agent.record_encode({"claude", "81b3", {4120, 4100, 900}}, context.temp_allocator)
	testing.expect(t, encoded)
	record, ok := agent.record_parse(transmute([]u8)text)
	testing.expect(t, ok)
	testing.expect_value(t, record.session, "81b3")
	testing.expect(t, agent.record_owned(record, .Claude, 4100))
	testing.expect(t, !agent.record_owned(record, .Claude, 5000))
	testing.expect(t, !agent.record_owned(record, .Codex, 4100))
	testing.expect(t, !agent.record_owned(record, .Claude, 0))
	for bad in ([?]string{"", `{"harness":"vim","session":"x"}`, `{"harness":"claude","session":"a;b"}`}) {
		_, ok = agent.record_parse(transmute([]u8)bad)
		testing.expectf(t, !ok, "%q should be refused", bad)
	}
}

@(test)
nested_agents_are_told_from_launcher_chains :: proc(t: ^testing.T) {
	// The hook's own shell, then the agent and what launched it, then the pane's shell.
	direct := []agent.Ancestor{{1, "bash"}, {2, "bash"}, {3, "claude"}, {4, "pwsh"}, {5, "aiodev"}}
	testing.expect(t, !agent.ancestry_nested(direct, .Claude))
	launcher := []agent.Ancestor{{1, "pwsh"}, {2, "codex-x86_64-pc-windows-msvc"}, {3, "codex"}, {4, "pwsh"}}
	testing.expect(t, !agent.ancestry_nested(launcher, .Codex))
	nested := []agent.Ancestor{{1, "bash"}, {2, "claude"}, {3, "bash"}, {4, "claude"}, {5, "pwsh"}}
	testing.expect(t, agent.ancestry_nested(nested, .Claude))
	other := []agent.Ancestor{{1, "bash"}, {2, "claude"}, {3, "bash"}, {4, "omp"}, {5, "pwsh"}}
	testing.expect(t, !agent.ancestry_nested(other, .Claude))
	testing.expect(t, !agent.ancestry_nested([]agent.Ancestor{{1, "codexx"}, {2, "pwsh"}, {3, "codexx"}}, .Codex))
}

@(test)
omp_breadcrumbs_name_the_session_file :: proc(t: ^testing.T) {
	text := "C:\\work\nC:\\Users\\me\\.omp\\agent\\sessions\\-work\\2026-11-08T23-43-39-835Z_01a1bd8b-d33b-7662.jsonl\n" +
		"cwdstat 1 2\n"
	id, file, ok := agent.breadcrumb_session(text)
	testing.expect(t, ok)
	testing.expect_value(t, id, "01a1bd8b-d33b-7662")
	testing.expect(t, strings.has_suffix(file, ".jsonl"))
	for bad in ([?]string{"", "C:\\work", "C:\\work\nC:\\x\\notes.txt", "C:\\w\nC:\\x\\nounderscore.jsonl"}) {
		_, _, ok = agent.breadcrumb_session(bad)
		testing.expectf(t, !ok, "%q should name no session", bad)
	}
	testing.expect_value(t, agent.breadcrumb_name("k-1", context.temp_allocator), "apple-k-1")
}

@(test)
claude_registry_entries_name_their_session :: proc(t: ^testing.T) {
	id, ok := agent.claude_registry_session(transmute([]u8)string(`{"pid":46400,"sessionId":"81b3","cwd":"C:\\w"}`))
	testing.expect(t, ok)
	testing.expect_value(t, id, "81b3")
	_, ok = agent.claude_registry_session(transmute([]u8)string(`{"pid":1}`))
	testing.expect(t, !ok)
}

@(private)
rollout_line :: proc(id, cwd, stamp, originator, source: string) -> []u8 {
	cwd_json, _ := json.marshal(cwd, {}, context.temp_allocator)
	return transmute([]u8)strings.concatenate(
		{
			`{"type":"session_meta","payload":{"id":"`, id, `","cwd":`, string(cwd_json),
			`,"timestamp":"`, stamp, `","originator":"`, originator, `","source":`, source, `}}`,
		},
		context.temp_allocator,
	)
}

@(test)
codex_rollouts_are_picked_only_when_one_matches :: proc(t: ^testing.T) {
	started, _ := time.rfc3339_to_time_utc("2026-11-08T10:00:00Z")
	lines := [?][]u8 {
		rollout_line("a1", `C:\Work`, "2026-11-08T10:00:01.250Z", "codex-tui", `"cli"`),
		rollout_line("old", `C:\Work`, "2026-11-08T09:00:00Z", "codex-tui", `"cli"`),
		rollout_line("sub", `C:\Work`, "2026-11-08T10:02:00Z", "codex-tui", `{"subagent":{}}`),
		rollout_line("exec", `C:\Work`, "2026-11-08T10:03:00Z", "codex_exec", `"exec"`),
		rollout_line("there", `C:\Elsewhere`, "2026-11-08T10:04:00Z", "codex-tui", `"cli"`),
	}
	rollouts := make([dynamic]agent.Rollout, 0, len(lines), context.temp_allocator)
	for line in lines {
		rollout, ok := agent.rollout_parse(line)
		testing.expect(t, ok)
		append(&rollouts, rollout)
	}
	id, ok := agent.rollout_pick(rollouts[:], "c:/work/", started)
	testing.expect(t, ok)
	testing.expect_value(t, id, "a1")
	second, _ := agent.rollout_parse(rollout_line("a2", `C:\Work`, "2026-11-08T10:05:00Z", "codex-tui", `"vscode"`))
	append(&rollouts, second)
	_, ok = agent.rollout_pick(rollouts[:], `C:\Work`, started)
	testing.expect(t, !ok)
	_, ok = agent.rollout_parse(transmute([]u8)string(`{"type":"turn_context"}`))
	testing.expect(t, !ok)
}

COMMAND :: `"C:/Program Files/AIODev/aio.exe" agent-session claude`

@(test)
hooks_install_into_a_missing_or_empty_file :: proc(t: ^testing.T) {
	for text in ([?]string{"", "  \n", "{}"}) {
		result, change := agent.hooks_install(text, COMMAND, 10, context.temp_allocator)
		testing.expect_value(t, change, agent.Hook_Install.Added)
		_, present := agent.hooks_install(result, COMMAND, 10, context.temp_allocator)
		testing.expect_value(t, present, agent.Hook_Install.Present)
	}
}

@(test)
hooks_install_keeps_the_rest_of_the_file_as_written :: proc(t: ^testing.T) {
	original := "{\n  \"statusLine\": {\"type\": \"command\", \"command\": \"node x.js\"},\n  \"model\": \"opus\"\n}\n"
	result, change := agent.hooks_install(original, COMMAND, 10, context.temp_allocator)
	testing.expect_value(t, change, agent.Hook_Install.Added)
	testing.expect(t, strings.contains(result, "\"statusLine\": {\"type\": \"command\", \"command\": \"node x.js\"},\n"))
	testing.expect(t, strings.has_suffix(result, "\"model\": \"opus\"\n}\n"))
	value, err := json.parse_string(result, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	root := value.(json.Object)
	groups := root["hooks"].(json.Object)["SessionStart"].(json.Array)
	handler := groups[0].(json.Object)["hooks"].(json.Array)[0].(json.Object)
	testing.expect_value(t, string(handler["command"].(json.String)), COMMAND)
	testing.expect_value(t, handler["timeout"].(json.Float), 10)
}

@(test)
hooks_install_beside_existing_hooks :: proc(t: ^testing.T) {
	other_event := `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}`
	result, change := agent.hooks_install(other_event, COMMAND, 10, context.temp_allocator)
	testing.expect_value(t, change, agent.Hook_Install.Added)
	testing.expect(t, strings.contains(result, `"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]`))
	other_start := `{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"load"}]}]}}`
	result, change = agent.hooks_install(other_start, COMMAND, 10, context.temp_allocator)
	testing.expect_value(t, change, agent.Hook_Install.Added)
	value, _ := json.parse_string(result, allocator = context.temp_allocator)
	groups := value.(json.Object)["hooks"].(json.Object)["SessionStart"].(json.Array)
	testing.expect_value(t, len(groups), 2)
	testing.expect(t, strings.contains(result, `{"matcher":"startup","hooks":[{"type":"command","command":"load"}]}`))
	empty := `{"hooks":{"SessionStart":[ ]}}`
	result, change = agent.hooks_install(empty, COMMAND, 10, context.temp_allocator)
	testing.expect_value(t, change, agent.Hook_Install.Added)
	_, err := json.parse_string(result, allocator = context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
}

@(test)
hooks_install_leaves_unexpected_files_alone :: proc(t: ^testing.T) {
	for text in ([?]string {
		"[]",
		`{"hooks":[]}`,
		`{"hooks":{"SessionStart":{}}}`,
		"{ // comment\n}",
		`{"a":`,
	}) {
		_, change := agent.hooks_install(text, COMMAND, 10, context.temp_allocator)
		testing.expectf(t, change == .Invalid, "%q gave %v", text, change)
	}
}

@(test)
hooks_install_keeps_a_byte_order_mark :: proc(t: ^testing.T) {
	result, change := agent.hooks_install(agent.UTF8_BOM + `{"model":"opus"}`, COMMAND, 10, context.temp_allocator)
	testing.expect_value(t, change, agent.Hook_Install.Added)
	testing.expect(t, strings.has_prefix(result, agent.UTF8_BOM + "{"))
	testing.expect(t, strings.has_suffix(result, `"model":"opus"}`))
}
