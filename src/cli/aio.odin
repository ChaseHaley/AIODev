package cli

import "aio:cli_protocol"
import "aio:instance"
import "aio:layout"
import "core:fmt"
import "core:strconv"

// aio: the AIODev command line. Every command runs inside AIODev through the shared command core;
// this program only carries the request, prints the reply and exits with its status (D-046).

// The usage text. Its wait default and exit statuses come from their declarations; print_usage
// supplies them in order. The split ratio range is spelled literally, held in step by the #assert.
#assert(layout.SPLIT_SHARE_MIN == 0.05 && layout.SPLIT_SHARE_MAX == 0.95)
@(private)
USAGE_FORMAT :: `Usage: aio [--instance <name>] [--json] <command> [options] [-- <program> [arguments]]
       aio wait [--pane <pane>] (--text <text> | --exit) [--timeout <ms>]
       aio commands
       aio help [<command>]

Runs AIODev commands from scripts and coding agents. Every palette command runs by
name, such as aio tab.next; aio commands lists them all.

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
        aio pane.read [--lines <rows>]    prints the pane's visible text
        aio pane.list                     one line per pane; --json for details
        aio pane.close
Wait    aio wait polls until the pane shows the text or its program exits; the default
        timeout is %d ms, and 0 waits without limit. --exit prints the exit code, even
        after the pane closed with its program, or closed when it was closed while running.
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
	pane, text: string,
	exit:       bool,
	timeout_ms: int,
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
		case "--timeout":
			timeout, ok := strconv.parse_int(value, 10)
			if seen_timeout || !ok || timeout < 0 {return {}, "use --timeout once with milliseconds"}
			o.wait.timeout_ms, seen_timeout = timeout, true
		case:
			return {}, "wait takes --pane, --text, --exit and --timeout"
		}
	}
	if (o.wait.text != "") == o.wait.exit {return {}, "wait for either --text or --exit"}
	return o, ""
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
