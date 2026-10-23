package term

import "aio:pty"

// session_pty_bytes reports how much output a session's console has delivered. The reader thread
// updates the counter, so the value may lag by the chunk it is reading right now.
@(require_results)
session_pty_bytes :: proc(s: ^Session) -> u64 {
	return pty.output_bytes(&s.pty)
}

// session_reset_pty_bytes clears that total for a diagnostics reset. A chunk read at the same
// moment may still be counted afterwards.
session_reset_pty_bytes :: proc(s: ^Session) {
	pty.reset_output_bytes(&s.pty)
}
