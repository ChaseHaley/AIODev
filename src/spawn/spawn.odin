// Programs run directly, without a shell or a terminal. A Process owns its child, job and pipe
// threads until destroy. The caller serializes API calls; wake runs on worker threads and must
// only signal the host, not call back into this package. The allocator must support worker threads.
package spawn

Options :: struct {
	cwd: string,
	// Edits are NAME=value; NAME= removes a variable. Names are case-insensitive on Windows.
	env: []string,
	clear_env: bool,
	// Initial input is copied before start returns and written asynchronously, so a child that
	// writes before reading cannot deadlock start. Later writes follow this initial input.
	stdin: string,
	keep_stdin: bool,
	discard_stdout, discard_stderr: bool,
	keep_crlf: bool,
}

Error :: enum {
	None,
	Not_Found,
	Not_Executable,
	Start_Failed,
	Closed,
	Out_Of_Memory,
}

// Output slices borrow storage until the next poll or destroy. exited becomes true only after
// exit and both captured streams reach EOF, so the last output cannot be missed. An output-buffer
// allocation failure terminates the job and reports code -1 rather than silently losing output.
Output :: struct {
	stdout, stderr: []u8,
	exited: bool,
	code: int,
}
