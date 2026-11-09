package cli

import "aio:cli_protocol"
import "aio:instance"
import "aio:layout"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:text/regex"

// aio: the AIODev command line. Every command runs inside AIODev through the shared command core;
// this program only carries the request, prints the reply and exits with its status (D-046).

// The usage text. Its wait default and exit statuses come from their declarations; print_usage
// supplies them in order. The split ratio range is spelled literally, held in step by the #assert.
#assert(layout.SPLIT_SHARE_MIN == 0.05 && layout.SPLIT_SHARE_MAX == 0.95)
@(private)
USAGE_FORMAT :: `Usage: aio [--instance <name>] [--json] <command> [options] [-- <program> [arguments]]
       aio wait [--pane <pane>] [--text <text> | --regex <pattern>] [--idle <ms>] [--timeout <ms>]
       aio wait [--pane <pane>] --exit [--timeout <ms>]
       aio commands
       aio help [<command>]

Runs AIODev commands from scripts and coding agents. Every palette command runs by
name, such as aio tab.next; aio commands lists them all.

Panes   --pane takes a pane id, a pane name, here or focused. Inside an AIODev pane the
        default is here, the pane aio runs in; elsewhere it is the focused pane.
Files   aio pane.open_markdown [--direction right|down|left|up] [--focus] <file>
            Shows a Markdown file beside the pane and updates it when the file changes.
Common  aio tab.new [--cwd <dir>] [--name <name>] [--focus] [-- <program> [arguments]]
        aio pane.split [--direction right|down|left|up] [--ratio <0.05-0.95>] [-- <program>]
            Both print the new pane's id and leave focus where it is unless --focus.
        aio pane.send [--enter] <text>    types text into the pane, then presses Enter
        aio pane.read [--lines <rows>] [--scrollback] [--unwrap]
            Prints the pane's visible text; --scrollback adds the history above it, --unwrap joins
            rows the terminal wrapped, and --lines keeps the last lines.
        aio pane.list                     one line per pane; --json for details
        aio pane.close
Wait    aio wait polls until the pane shows the text, a line matches the pattern or its program
        exits; text and patterns match across rows the terminal wrapped. --idle also waits until
        the screen has not changed for that long. The default timeout is %d ms, and 0 waits
        without limit. --exit prints the exit code, even after the pane closed with its program,
        or closed when it was closed while running.
Exit    %d ok, %d failed, %d bad command line, %d pane missing or ambiguous,
        %d AIODev unreachable, %d control pipe server unverified, %d interrupted.

Turn on Command Line Control in AIODev's Settings (control.enabled) first.
`

WAIT_DEFAULT_TIMEOUT_MS :: 30000

print_usage :: proc() {
	fmt.printf(
		USAGE_FORMAT,
		WAIT_DEFAULT_TIMEOUT_MS,
		u8(cli_protocol.Status.Ok),
		u8(cli_protocol.Status.Failed),
		u8(cli_protocol.Status.Usage),
		u8(cli_protocol.Status.Target),
		u8(cli_protocol.Status.Unreachable),
		u8(cli_protocol.Status.Impostor),
		u8(cli_protocol.Status.Interrupted),
	)
}

Wait :: struct {
	pane, text, regex:   string,
	exit:                bool,
	idle_ms, timeout_ms: int,
}

Options :: struct {
	// The AIODev instance name; empty for the default instance.
	instance: string,
	json:     bool,
	// The command and its arguments, as AIODev parses them.
	args:     []string,
	// Set when the command is wait.
	waiting:  bool,
	wait:     Wait,
}

// Reads aio's own options, which come before the command. `environment` is the AIODEV_INSTANCE
// value, overridden by --instance. Strings borrow from args.
@(require_results)
parse_options :: proc(args: []string, environment: string) -> (Options, string) {
	o := Options {
		instance = environment,
	}
	i := 0
	seen_instance := false
	for ; i < len(args); i += 1 {
		switch args[i] {
		case "--json":
			if o.json {return {}, "use --json once"}
			o.json = true
			continue
		case "--instance":
			if seen_instance {return {}, "use --instance once"}
			if i + 1 == len(args) || !instance.valid_name(args[i + 1]) {
				return {}, "--instance takes " + instance.NAME_RULE
			}
			i += 1
			o.instance, seen_instance = args[i], true
			continue
		}
		break
	}
	if i == len(args) {return {}, "name a command"}
	o.args = args[i:]
	if o.args[0] != "wait" {return o, ""}
	o.waiting = true
	o.wait.timeout_ms = WAIT_DEFAULT_TIMEOUT_MS
	seen_pane, seen_timeout := false, false
	for j := 1; j < len(o.args); j += 1 {
		option := o.args[j]
		if option == "--exit" {
			if o.wait.exit {return {}, "use --exit once"}
			o.wait.exit = true
			continue
		}
		if j + 1 == len(o.args) {return {}, "supply a value after the wait option"}
		j += 1
		value := o.args[j]
		switch option {
		case "--pane":
			if seen_pane || value == "" {return {}, "use --pane once with a pane"}
			o.wait.pane, seen_pane = value, true
		case "--text":
			if o.wait.text != "" || value == "" {return {}, "use --text once with nonempty text"}
			o.wait.text = value
		case "--regex":
			if o.wait.regex != "" || value == "" {return {}, "use --regex once with a pattern"}
			o.wait.regex = value
		case "--idle":
			idle, ok := strconv.parse_int(value, 10)
			if o.wait.idle_ms > 0 || !ok || idle < 1 {return {}, "use --idle once with milliseconds above 0"}
			o.wait.idle_ms = idle
		case "--timeout":
			timeout, ok := strconv.parse_int(value, 10)
			if seen_timeout || !ok || timeout < 0 {return {}, "use --timeout once with milliseconds"}
			o.wait.timeout_ms, seen_timeout = timeout, true
		case:
			return {}, "wait takes --pane, --text, --regex, --idle, --exit and --timeout"
		}
	}
	conditions := int(o.wait.text != "") + int(o.wait.regex != "") + int(o.wait.exit)
	if conditions > 1 {return {}, "wait for one of --text, --regex and --exit"}
	if o.wait.exit && o.wait.idle_ms > 0 {return {}, "--idle does not combine with --exit"}
	if conditions == 0 && o.wait.idle_ms == 0 {return {}, "wait for --text, --regex, --idle or --exit"}
	return o, ""
}

// Compiles the wait's pattern, or says why it does not compile.
@(require_results)
wait_pattern :: proc(
	pattern: string,
	allocator := context.allocator,
) -> (
	regex.Regular_Expression,
	string,
) {
	compiled, err := regex.create(pattern, {.Unicode, .No_Capture}, allocator)
	if err != nil {return {}, fmt.tprintf("--regex %q does not compile (%v)", pattern, err)}
	return compiled, ""
}

// Whether the pane's text shows what the wait looks for: the text anywhere, or a line the pattern
// matches. Waiting for --idle alone looks for nothing, so any text will do.
@(require_results)
wait_found :: proc(w: Wait, pattern: Maybe(regex.Regular_Expression), text: string) -> bool {
	if w.text != "" {return strings.contains(text, w.text)}
	compiled, has_pattern := pattern.?
	if !has_pattern {return true}
	lines := text
	for line in strings.split_lines_iterator(&lines) {
		_, matched := regex.match_and_allocate_capture(compiled, line, context.temp_allocator)
		if matched {return true}
	}
	return false
}

// The pipe request for a command: the caller pane, the reply format, aio's working directory, then
// the command line. `commands` and `help <command>` ask AIODev's catalogue.
@(require_results)
request :: proc(o: Options, caller, directory: string, allocator := context.allocator) -> []string {
	command := o.args
	switch o.args[0] {
	case "commands", "help":
		command = make([]string, len(o.args), allocator)
		command[0] = cli_protocol.CATALOGUE_COMMAND
		copy(command[1:], o.args[1:])
	}
	format := o.json ? cli_protocol.Format.Json : cli_protocol.Format.Text
	return cli_protocol.request_encode(
		{caller = caller, format = format, directory = directory, command = command},
		allocator,
	)
}
