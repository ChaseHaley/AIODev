package agent

import "core:strings"

// Resuming the coding agents a pane runs (WORK-361): which harness a program is, what of its launch
// a resume keeps, and the command line that resumes a session. Everything here is pure; the app
// supplies process arguments and file contents.

Harness :: enum u8 {
	None,
	Claude,
	Codex,
	Omp,
}

HARNESS_NAMES :: [Harness]string {
	.None   = "",
	.Claude = "claude",
	.Codex  = "codex",
	.Omp    = "omp",
}

// The harness a program's canonical name names; None for any other program.
harness_named :: proc(name: string) -> Harness {
	names := HARNESS_NAMES
	for harness in Harness {
		if harness != .None && strings.equal_fold(name, names[harness]) {return harness}
	}
	return .None
}

SESSION_ID_LIMIT :: 128
// A resume line longer than this keeps only the session id; a saved one longer than this is refused.
RESUME_LINE_LIMIT :: 4096

// The variable naming the file a pane's agent session hook writes; see records.odin.
RECORD_VARIABLE :: "AIODEV_AGENT_RECORD"

// Session ids are typed into a shell, so only letters, digits, '-' and '_' are accepted, and not a
// leading '-', which the harness would read as an option.
session_id_valid :: proc(id: string) -> bool {
	if id == "" || len(id) > SESSION_ID_LIMIT || id[0] == '-' {return false}
	for i in 0 ..< len(id) {
		switch id[i] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_':
		case:
			return false
		}
	}
	return true
}

// The command that resumes `session` the way `launch` started its program, in `allocator`. A line
// past RESUME_LINE_LIMIT keeps only the session.
resume_line :: proc(launch: Launch, session: string, allocator := context.allocator) -> string {
	names := HARNESS_NAMES
	b := strings.builder_make(allocator)
	for flags in ([2][]string{launch.flags, nil}) {
		strings.builder_reset(&b)
		strings.write_string(&b, names[launch.harness])
		if launch.harness == .Codex {strings.write_string(&b, " resume")}
		for flag in flags {
			strings.write_byte(&b, ' ')
			token_write(&b, flag)
		}
		strings.write_string(&b, launch.harness == .Codex ? " " : " --resume ")
		strings.write_string(&b, session)
		if strings.builder_len(b) <= RESUME_LINE_LIMIT {break}
	}
	return strings.to_string(b)
}

// Whether a saved resume line is one resume_line could have written, so a damaged or edited layout
// cannot type anything else into a shell.
resume_line_valid :: proc(line: string) -> bool {
	if len(line) > RESUME_LINE_LIMIT {return false}
	tokens := make([dynamic]string, 0, 16, context.temp_allocator)
	start, quoted := 0, false
	for i in 0 ..= len(line) {
		if i < len(line) && line[i] == '"' {quoted = !quoted}
		if i < len(line) && (line[i] != ' ' || quoted) {continue}
		token := line[start:i]
		if len(token) >= 2 && token[0] == '"' && token[len(token) - 1] == '"' {token = token[1:len(token) - 1]}
		append(&tokens, token)
		start = i + 1
	}
	if quoted || len(tokens) < 3 {return false}
	names := HARNESS_NAMES
	harness := harness_named(tokens[0])
	if harness == .None || tokens[0] != names[harness] {return false}
	if harness == .Codex && tokens[1] != "resume" {return false}
	if harness != .Codex && tokens[len(tokens) - 2] != "--resume" {return false}
	for token in tokens[1:len(tokens) - 1] {
		if !token_safe(token) {return false}
	}
	return session_id_valid(tokens[len(tokens) - 1])
}

// A kept argument is typed into whichever shell the pane runs, PowerShell, cmd or bash, so it may
// hold nothing those read specially even inside double quotes: ASCII only, as PowerShell takes curly
// quotes for quotes, and no quotes, variables, escapes, operators or doubled and trailing
// backslashes, which cmd and bash fold.
@(private)
token_safe :: proc(token: string) -> bool {
	if token == "" || token[len(token) - 1] == '\\' || strings.contains(token, `\\`) {return false}
	for i in 0 ..< len(token) {
		switch token[i] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9':
		case '-', '_', '.', ',', ':', '/', '\\', '=', '@', '+', '~', ' ':
		case:
			return false
		}
	}
	return true
}

// Writes a safe token, quoted unless it is plain letters, digits and path punctuation. PowerShell
// reads a bare ',' or '@' as an array, and bash an unquoted '\' as an escape.
@(private)
token_write :: proc(b: ^strings.Builder, token: string) {
	plain := true
	for i in 0 ..< len(token) {
		switch token[i] {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '/', ':':
		case:
			plain = false
		}
	}
	if !plain {strings.write_byte(b, '"')}
	strings.write_string(b, token)
	if !plain {strings.write_byte(b, '"')}
}
