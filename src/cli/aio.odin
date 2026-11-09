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
       aio version
       aio agent-session (claude | codex)

Runs AIODev commands from scripts and coding agents. Every palette command runs by
name, such as aio tab.next; aio commands lists them all, and aio help <command>
explains one's options, their defaults and an example of each. aio version prints
aio's build and the running AIODev's, and aio warns on stderr when the two differ.

Panes   --pane takes a pane id, a pane name, here or focused. Inside an AIODev pane the
        default is here, the pane aio runs in; elsewhere it is the focused pane.
        --workspace takes a workspace id or name; workspace.change, pane.move_workspace
        and tab.move_workspace open their dialog without it.
Files   aio pane.open_markdown [--direction right|down|left|up] [--focus] <file>
            Shows a Markdown file beside the pane and updates it when the file changes.
        aio layout.apply [--focus] <file>
            Opens a tab of named panes from a JSON layout; prints their ids in order.
Common  aio tab.new [--cwd <dir>] [--name <name>] [--tab-name <name>] [--focus] [-- <program>]
        aio workspace.new [--cwd <dir>] [--name <name>] [--focus] [-- <program>]
        aio pane.split [--direction right|down|left|up] [--ratio <0.05-0.95>] [-- <program>]
            Each prints the new pane's id, starts in aio's working directory unless --cwd
            names another, and leaves focus where it is unless --focus.
            tab.new --name names the pane; workspace.new --name names the workspace.
            --command-file <file> takes the program and arguments from a JSON array of
            strings instead, so no shell quotes them.
        aio tab.rename <name>             names the pane's tab
        aio workspace.rename [--workspace <workspace>] <name>
            Without a name, both open their dialog.
        aio pane.send [--enter] <text>    types text into the pane, then presses Enter
        aio pane.send --file <file>       types a UTF-8 file's text exactly
        aio pane.read [--lines <rows>] [--scrollback] [--unwrap]
            Prints the pane's visible text; --scrollback adds the history above it, --unwrap joins
            rows the terminal wrapped, and --lines keeps the last lines.
        aio pane.list                     one line per pane; --json for details
        aio tab.list, aio workspace.list  one line per tab or workspace
        aio pane.close
Wait    aio wait polls until the pane shows the text, a line matches the pattern or its program
        exits; text and patterns match across rows the terminal wrapped. --idle also waits until
        the screen has not changed for that long. The default timeout is %d ms, and 0 waits
        without limit. --exit prints the exit code, even after the pane closed with its program,
        or closed when it was closed while running.
Hooks   aio agent-session runs from a Claude Code or Codex SessionStart hook and records the
        session the hook names, so the pane can resume it; Install Agent Session Hooks sets it up.
Exit    %d ok, %d failed, %d bad command line, %d pane missing or ambiguous,
        %d AIODev unreachable, %d control pipe server unverified, %d interrupted.

Turn on Command Line Control in AIODev's Settings (control.enabled) first.
`

WAIT_DEFAULT_TIMEOUT_MS :: 30000

// The commands aio runs itself, which AIODev's catalogue does not know, so aio answers their help.
// wait's timeout default is spelled literally, held in step by the #assert.
#assert(WAIT_DEFAULT_TIMEOUT_MS == 30000)
@(private, rodata)
local_commands := [?]cli_protocol.Command_Report {
	{
		name = "wait",
		title = "Wait for Text, a Pattern, a Quiet Screen or Exit",
		usage = "wait [--pane <pane>] (--text <text> | --regex <pattern> | --exit) [--idle <ms>] " +
		"[--timeout <ms>]",
		summary = "Polls the pane until its screen shows the text or a matching line, then with --idle until " +
		"the screen stays the same, or until its program exits; text and patterns match across rows the " +
		"terminal wrapped. On timeout aio exits with status 1.",
		options = {
			cli_protocol.PANE_OPTION,
			{
				option = "--text <text>",
				description = "waits until the pane's visible screen contains this text, case-sensitive",
				default = "none (give --text, --regex, --idle or --exit)",
				example = "--text 'PS '",
			},
			{
				option = "--regex <pattern>",
				description = "waits until a line of the visible screen matches this pattern, case-sensitive; " +
				"a pattern cannot span a line break",
				default = "none",
				example = `--regex "built \d+ targets"`,
			},
			{
				option = "--idle <ms>",
				description = "waits until the screen has not changed for this many milliseconds, alone or " +
				"after --text or --regex matches; not with --exit",
				default = "off",
				example = "--idle 1000",
			},
			{
				option = "--exit",
				description = "waits until the pane's program exits, then prints its exit code, or closed " +
				"for a pane closed while its program ran",
				default = "off",
				example = "--exit",
			},
			{
				option = "--timeout <ms>",
				description = "gives up after this many milliseconds (0 waits without limit)",
				default = "30000",
				example = "--timeout 5000",
			},
		},
	},
	{
		name = "commands",
		title = "List Commands",
		usage = "commands",
		summary = "Prints every command AIODev runs by name, with its title; --json adds usage and summary.",
	},
	{
		name = "help",
		title = "Show Help",
		usage = "help [<command>]",
		summary = "Prints aio's usage, or one command's usage, title, summary and options.",
		options = {
			{
				option = "<command>",
				description = "the command to explain: any name aio commands lists, or wait, commands, help, " +
				"version or agent-session",
				default = "none (prints aio's usage)",
				example = "pane.split",
			},
		},
	},
	{
		name = "version",
		title = "Show Builds",
		usage = "version",
		summary = "Prints aio's build, then the running AIODev's; --version does the same. aio warns on " +
		"stderr whenever the two differ, and exits 4 after its own line when AIODev is unreachable.",
	},
	{
		name = "agent-session",
		title = "Record an Agent Session",
		usage = "agent-session (claude | codex)",
		summary = "Run by a Claude Code or Codex SessionStart hook: records the session the hook names so " +
		"the pane can resume it. Needs no control pipe, prints nothing and succeeds outside an AIODev pane; " +
		"Install Agent Session Hooks sets it up.",
		options = {
			{
				option = "claude | codex",
				description = "the harness whose hook runs it",
				default = "none (required)",
				example = "claude",
			},
		},
	},
}

// The help aio gives itself for `help <command>` naming a command it runs; false for any other.
@(require_results)
local_help :: proc(o: Options) -> (cli_protocol.Command_Report, bool) {
	if len(o.args) != 2 || o.args[0] != "help" {return {}, false}
	for report in local_commands {
		if report.name == o.args[1] {return report, true}
	}
	return {}, false
}

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
	// Set when the command is version or --version.
	version:  bool,
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
	o.version = o.args[0] == "version" || o.args[0] == "--version"
	// Only an AIODev too old to know the version command fails it, which build_warning reports.
	if o.version && len(o.args) > 1 {return {}, "version takes no arguments"}
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
// the command line. `commands` and `help <command>` ask AIODev's catalogue; `version` asks its build
// as text, since aio prints its own build beside it and composes any JSON itself.
@(require_results)
request :: proc(o: Options, caller, directory: string, allocator := context.allocator) -> []string {
	format := o.json ? cli_protocol.Format.Json : cli_protocol.Format.Text
	name := o.args[0]
	switch {
	case name == "commands" || name == "help":
		name = cli_protocol.CATALOGUE_COMMAND
	case o.version:
		name, format = cli_protocol.VERSION_COMMAND, .Text
	}
	command := o.args
	if name != o.args[0] {
		command = make([]string, len(o.args), allocator)
		command[0] = name
		copy(command[1:], o.args[1:])
	}
	return cli_protocol.request_encode(
		{caller = caller, format = format, directory = directory, command = command},
		allocator,
	)
}

// The warning aio prints when the running AIODev comes from another build, or "" when both report
// the same one. `own` is aio's build_text; `app` is AIODev's reply to the version command, or "" from
// an AIODev too old to answer it.
@(require_results)
build_warning :: proc(own, app: string, allocator := context.allocator) -> string {
	prefix :: cli_protocol.APP_NAME + " "
	if strings.has_prefix(app, prefix) && app[len(prefix):] == own {return ""}
	advice :: "use aio and AIODev from one build"
	if app == "" {
		return fmt.aprintf(
			"aio: warning: aio %s does not match the running AIODev, which does not report its build; %s",
			own, advice, allocator = allocator,
		)
	}
	return fmt.aprintf(
		"aio: warning: aio %s does not match the running %s; %s", own, app, advice, allocator = allocator,
	)
}
