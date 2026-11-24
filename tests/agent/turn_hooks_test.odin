package agent_test

import "aio:agent"
import "core:slice"
import "core:strings"
import "core:testing"

@(private)
expect_paths :: proc(t: ^testing.T, p: agent.Turn_Payload, want: []string, loc := #caller_location) {
	testing.expect_value(t, len(p.paths), len(want), loc)
	if len(p.paths) != len(want) {return}
	for path, i in p.paths {testing.expect_value(t, path, want[i], loc)}
}

@(test)
claude_prompt_payload :: proc(t: ^testing.T) {
	input := `{"session_id":"abc-1","cwd":"C:\\work","hook_event_name":"UserPromptSubmit","prompt":"fix the bug"}`
	p, ok := agent.turn_payload(.Claude, .Prompt, transmute([]u8)string(input))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	testing.expect_value(t, p.session, "abc-1")
	testing.expect_value(t, p.cwd, `C:\work`)
	testing.expect_value(t, p.prompt, "fix the bug")
	testing.expect_value(t, len(p.paths), 0)
}

@(test)
claude_stop_payload_has_no_prompt_or_paths :: proc(t: ^testing.T) {
	input := `{"session_id":"abc-1","cwd":"C:\\work","hook_event_name":"Stop","prompt":"ignored"}`
	p, ok := agent.turn_payload(.Claude, .Stop, transmute([]u8)string(input))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	testing.expect_value(t, p.session, "abc-1")
	testing.expect_value(t, p.prompt, "")
	testing.expect_value(t, len(p.paths), 0)
}

@(test)
claude_edit_tools_name_their_file :: proc(t: ^testing.T) {
	Case :: struct {
		input: string,
		want:  string,
	}
	for item in ([]Case {
			{`{"cwd":"C:\\work","tool_name":"Edit","tool_input":{"file_path":"C:\\work\\src\\a.odin"}}`, "C:/work/src/a.odin"},
			{`{"cwd":"C:\\work","tool_name":"Write","tool_input":{"file_path":"C:/other/b.txt","content":"x"}}`, "C:/other/b.txt"},
			{`{"cwd":"C:\\work","tool_name":"MultiEdit","tool_input":{"file_path":"src\\c.odin","edits":[]}}`, "C:/work/src/c.odin"},
			{`{"cwd":"C:\\work\\","tool_name":"NotebookEdit","tool_input":{"notebook_path":"nb/d.ipynb"}}`, "C:/work/nb/d.ipynb"},
			{`{"cwd":"C:\\work\\sub","tool_name":"Edit","tool_input":{"file_path":"..\\.\\e.txt"}}`, "C:/work/e.txt"},
			{`{"cwd":"/home/me","tool_name":"Edit","tool_input":{"file_path":"f.txt"}}`, "/home/me/f.txt"},
		}) {
		p, ok := agent.turn_payload(.Claude, .Edit, transmute([]u8)item.input)
		testing.expectf(t, ok, "%s", item.input)
		expect_paths(t, p, {item.want})
		agent.turn_payload_destroy(&p)
	}
}

@(test)
claude_edit_without_a_path_is_empty :: proc(t: ^testing.T) {
	for input in ([]string{`{"cwd":"C:\\work"}`, `{"cwd":"C:\\work","tool_input":{}}`, `{"tool_input":"x"}`}) {
		p, ok := agent.turn_payload(.Claude, .Edit, transmute([]u8)input)
		testing.expectf(t, ok, "%s", input)
		testing.expect_value(t, len(p.paths), 0)
		agent.turn_payload_destroy(&p)
	}
}

@(test)
codex_prompt_payload :: proc(t: ^testing.T) {
	input := `{"session_id":"019a-x","cwd":"C:\\repo","turn_id":"t1","hook_event_name":"UserPromptSubmit","prompt":"add a test"}`
	p, ok := agent.turn_payload(.Codex, .Prompt, transmute([]u8)string(input))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	testing.expect_value(t, p.session, "019a-x")
	testing.expect_value(t, p.cwd, `C:\repo`)
	testing.expect_value(t, p.prompt, "add a test")
}

@(test)
codex_apply_patch_names_every_path :: proc(t: ^testing.T) {
	input :=
		`{"session_id":"s","cwd":"C:\\repo","tool_name":"apply_patch","tool_input":{"command":` +
		`"*** Begin Patch\n*** Add File: new.txt\n+*** Add File: not-a-path\n+hello\n` +
		`*** Update File: src/a.odin\n*** Move to: src/b.odin\n@@\n-old\n+new\n` +
		`*** Delete File: C:\\repo\\old.txt\n*** Update File: new.txt\n*** Delete File: ..\\up.txt\n*** End Patch"}}`
	p, ok := agent.turn_payload(.Codex, .Edit, transmute([]u8)string(input))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	// Added content lines never count, and a path named twice is listed once.
	expect_paths(
		t,
		p,
		{"C:/repo/new.txt", "C:/repo/src/a.odin", "C:/repo/src/b.odin", "C:/repo/old.txt", "C:/up.txt"},
	)
}

@(test)
codex_apply_patch_reads_crlf_lines :: proc(t: ^testing.T) {
	input :=
		`{"cwd":"C:\\repo","tool_input":{"command":"*** Begin Patch\r\n*** Update File: a.txt\r\n` +
		`@@\r\n-x\r\n+y\r\n*** End Patch\r\n"}}`
	p, ok := agent.turn_payload(.Codex, .Edit, transmute([]u8)string(input))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	expect_paths(t, p, {"C:/repo/a.txt"})
}

// agy 1.5.15's hook inputs, as observed on Windows (WORK-521), less the fields AIODev does not read.
@(test)
agy_prompt_is_the_first_model_call_of_a_turn :: proc(t: ^testing.T) {
	first := `{"conversationId":"40bf0ec5-5a49-4015-a4c1-d1709000e1e7","cwd":"C:\\work",` +
		`"hookEventName":"PreInvocation","initialNumSteps":1,"invocationNum":0,"lastUserInput":"fix the tests"}`
	p, ok := agent.turn_payload(.Agy, .Prompt, transmute([]u8)string(first))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok && !p.skip)
	testing.expect_value(t, p.session, "40bf0ec5-5a49-4015-a4c1-d1709000e1e7")
	testing.expect_value(t, p.cwd, `C:\work`)
	testing.expect_value(t, p.prompt, "fix the tests")
	later := `{"conversationId":"40bf","cwd":"C:\\work","invocationNum":1,"lastUserInput":"fix the tests"}`
	q, later_ok := agent.turn_payload(.Agy, .Prompt, transmute([]u8)string(later))
	defer agent.turn_payload_destroy(&q)
	testing.expect(t, later_ok && q.skip)
}

@(test)
agy_stop_ends_the_turn_only_when_fully_idle :: proc(t: ^testing.T) {
	idle := `{"conversationId":"40bf","cwd":"C:\\work","hookEventName":"Stop","fullyIdle":true,"terminationReason":"model_stop"}`
	p, ok := agent.turn_payload(.Agy, .Stop, transmute([]u8)string(idle))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok && !p.skip)
	busy := `{"conversationId":"40bf","cwd":"C:\\work","hookEventName":"Stop","fullyIdle":false}`
	q, busy_ok := agent.turn_payload(.Agy, .Stop, transmute([]u8)string(busy))
	defer agent.turn_payload_destroy(&q)
	testing.expect(t, busy_ok && q.skip)
}

@(test)
agy_edit_tools_name_their_file :: proc(t: ^testing.T) {
	Case :: struct {
		input: string,
		want:  string,
	}
	for item in ([]Case {
			{`{"cwd":"C:\\work","toolCall":{"name":"write_file","args":{"Content":"hi","Overwrite":true,"Path":"C:\\work\\a.txt"}}}`, "C:/work/a.txt"},
			{`{"cwd":"C:\\work","toolCall":{"name":"edit_file","args":{"Path":"src\\b.odin","Target":"x","Replacement":"y"}}}`, "C:/work/src/b.odin"},
			{`{"cwd":"C:\\work","toolCall":{"name":"replace_file_content","args":{"TargetFile":"C:/other/c.md"}}}`, "C:/other/c.md"},
		}) {
		p, ok := agent.turn_payload(.Agy, .Edit, transmute([]u8)item.input)
		testing.expectf(t, ok, "%s", item.input)
		expect_paths(t, p, {item.want})
		agent.turn_payload_destroy(&p)
	}
	// Claude's field names are not agy's.
	p, ok := agent.turn_payload(.Agy, .Edit, transmute([]u8)string(`{"cwd":"C:\\w","tool_input":{"file_path":"a"}}`))
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	testing.expect_value(t, len(p.paths), 0)
}

@(test)
turn_payload_rejects_unusable_input :: proc(t: ^testing.T) {
	for input in ([]string{"", "{", "[]", `"text"`, `{"cwd":}`, "null"}) {
		p, ok := agent.turn_payload(.Claude, .Prompt, transmute([]u8)input)
		testing.expectf(t, !ok, "%q should be rejected", input)
		testing.expect(t, p.session == "" && p.cwd == "" && p.prompt == "" && p.paths == nil)
	}
	p, ok := agent.turn_payload(.None, .Prompt, transmute([]u8)string("{}"))
	testing.expect(t, !ok)
	testing.expect(t, p.session == "" && p.paths == nil)
	oversize := make([]u8, agent.PAYLOAD_LIMIT + 1, context.temp_allocator)
	slice.fill(oversize, ' ')
	_, big := agent.turn_payload(.Claude, .Prompt, oversize)
	testing.expect(t, !big)
}

@(test)
turn_payload_keeps_a_long_prompt_whole :: proc(t: ^testing.T) {
	// The event file clips the prompt; the payload does not, so a long one still reaches it.
	prompt := make([]u8, 5000, context.temp_allocator)
	slice.fill(prompt, 'a')
	input := strings.concatenate(
		{`{"session_id":"s","cwd":"C:\\w","prompt":"`, string(prompt), `"}`},
		context.temp_allocator,
	)
	p, ok := agent.turn_payload(.Claude, .Prompt, transmute([]u8)input)
	defer agent.turn_payload_destroy(&p)
	testing.expect(t, ok)
	testing.expect_value(t, len(p.prompt), 5000)
}
