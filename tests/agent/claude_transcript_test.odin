package agent_test

import "aio:agent"
import "core:strings"
import "core:testing"

@(private)
places_of :: proc(chunk: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	agent.claude_transcript_places(transmute([]u8)chunk, &out, context.temp_allocator)
	return out
}

@(test)
transcript_path_replaces_every_non_alphanumeric :: proc(t: ^testing.T) {
	got := agent.claude_transcript_path(
		`C:\Users\x\.claude`,
		`C:\Users\chale\Projects\AIODev`,
		"abc-1",
		context.temp_allocator,
	)
	testing.expect_value(t, got, `C:\Users\x\.claude/projects/C--Users-chale-Projects-AIODev/abc-1.jsonl`)
	got = agent.claude_transcript_path("/cfg/", "/c/Users/a b.c", "s", context.temp_allocator)
	testing.expect_value(t, got, "/cfg/projects/-c-Users-a-b-c/s.jsonl")
}

@(test)
transcript_places_read_cwd_and_tool_paths :: proc(t: ^testing.T) {
	chunk := strings.concatenate(
		{
			`{"type":"user","cwd":"C:\\Users\\chale\\Projects\\AIODev","message":"hi"}` + "\n",
			`{"cwd":"/c/Users/chale/Projects/AIODev-wt","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"C:\\Users\\chale\\Projects\\AIODev-wt\\src\\a.odin","old_string":"x"}}]}}` + "\r\n",
			`{"content":[{"name":"NotebookEdit","input":{"notebook_path": "D:\\n\u00e9.ipynb"}}]}` + "\n",
			`{"cwd":"C:\\Users\\chale\\Projects\\AIODev"}` + "\n",
		},
		context.temp_allocator,
	)
	got := places_of(chunk)
	want := [?]string {
		"C:/Users/chale/Projects/AIODev",
		"C:/Users/chale/Projects/AIODev-wt",
		"C:/Users/chale/Projects/AIODev-wt/src/a.odin",
		"D:/n\u00e9.ipynb",
	}
	testing.expect_value(t, len(got), len(want))
	for w in want {
		found := false
		for g in got {found |= g == w}
		testing.expectf(t, found, "missing %q in %v", w, got[:])
	}
}

@(test)
transcript_places_take_files_only_from_editing_tools :: proc(t: ^testing.T) {
	got := places_of(
		`{"cwd":"C:\\a","m":[{"type":"tool_use","id":"t","name":"Read","input":{"file_path":"C:\\other\\r.txt"}}]}` +
		"\n" +
		`{"m":[{"type":"tool_use","id":"t","name":"Write","input":{"file_path":"C:\\w\\x.txt","content":"c"}}]}` +
		"\n" +
		`{"m":[{"type":"tool_use","id":"t","name":"Grep","input":{"notebook_path":"C:\\g"}}]}` + "\n",
	)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], "C:/a")
		testing.expect_value(t, got[1], "C:/w/x.txt")
	}
}

@(test)
transcript_places_skip_cut_and_malformed_lines :: proc(t: ^testing.T) {
	chunk := "ders\":\"x\",\"cwd\":\"C:\\\\cut\"}\n" +
		`{"cwd":"C:\\ok"}` + "\n" +
		`{"cwd":"C:\\bad\q"}` + "\n" +
		`{"cwd":"C:\\unterminated` + "\n" +
		`{"cwd":"C:\\tail","name":"Edit","input":{"file_path":"C:\\tai`
	got := places_of(chunk)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {testing.expect_value(t, got[0], "C:/ok")}
}

@(test)
transcript_places_ignore_escaped_keys_inside_strings :: proc(t: ^testing.T) {
	got := places_of(`{"text":"say \"cwd\":\"C:\\\\no\" now","cwd":"C:\\yes"}`)
	testing.expect_value(t, len(got), 1)
	if len(got) == 1 {testing.expect_value(t, got[0], "C:/yes")}
}

@(test)
transcript_places_join_a_line_split_across_chunks_by_the_caller :: proc(t: ^testing.T) {
	line := `{"cwd":"C:\\split"}`
	first := places_of(line[:9])
	second := places_of(line[9:])
	testing.expect_value(t, len(first) + len(second), 0)
	whole := places_of(line)
	testing.expect_value(t, len(whole), 1)
}

@(test)
transcript_places_handle_a_two_mebibyte_line :: proc(t: ^testing.T) {
	filler := strings.repeat("a", 2 << 20, context.temp_allocator)
	line := strings.concatenate(
		{`{"text":"`, filler, `","cwd":"/c/big","name":"Edit","input":{"file_path":"C:\\big\\f.txt"}}`, "\n"},
		context.temp_allocator,
	)
	got := places_of(line)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], "C:/big")
		testing.expect_value(t, got[1], "C:/big/f.txt")
	}
}
