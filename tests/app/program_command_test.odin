package app_test

import "core:testing"
import app "../../src"

@(test)
program_command_reads_as_typed :: proc(t: ^testing.T) {
	cases := [?]struct {
		arguments: []string,
		stem, want: string,
	}{
		{{`C:\tools\claude.exe`, "--continue"}, "claude", "claude --continue"},
		{{"nvim", "my notes.md"}, "nvim", `nvim "my notes.md"`},
		{{"node", `C:\npm\node_modules\@openai\codex\bin\codex.js`, "--full-auto"}, "node", "codex --full-auto"},
		{{"cmd.exe", "/d", "/s", "/c", `C:\npm\npm.cmd run dev`}, "cmd", "npm run dev"},
		{{"ping", "a\x1b]0;x\x07b"}, "ping", "ping a]0;xb"},
		{{}, "ping", ""},
	}
	for c in cases {
		got := app.program_command(c.arguments, c.stem, context.temp_allocator)
		testing.expectf(t, got == c.want, "%v: got %q, want %q", c.arguments, got, c.want)
	}
}
