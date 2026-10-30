package cli

import "aio:instance"
import "core:strconv"

// aio: the AIODev command line. Every command runs inside AIODev through the shared command core;
// this program only carries the request, prints the reply and exits with its status (D-046).

USAGE :: `Usage: aio [--instance <name>] [--json] <command> [options] [-- <program> [arguments]]
       aio wait [--pane <pane>] (--text <text> | --exit) [--timeout <ms>]
       aio commands
       aio help [<command>]

Runs AIODev commands from scripts and coding agents. Every palette command runs by
name, such as aio tab.next; aio commands lists them all.

Panes   --pane takes a pane id, a pane name, here or focused. Inside an AIODev pane the
        default is here, the pane aio runs in; elsewhere it is the focused pane.
Common  aio tab.new [--cwd <dir>] [--name <name>] [--focus] [-- <program> [arguments]]
        aio pane.split [--direction right|down|left|up] [--ratio <0.05-0.95>] [-- <program>]
            Both print the new pane's id and leave focus where it is unless --focus.
        aio pane.send [--enter] <text>    types text into the pane, then presses Enter
        aio pane.read [--lines <rows>]    prints the pane's visible text
        aio pane.list                     one line per pane; --json for details
        aio pane.close
Wait    aio wait polls until the pane shows the text or its program exits; the default
        timeout is 30000 ms, and 0 waits without limit. --exit prints the exit code, even
        after the pane closed with its program, or closed when it was closed while running.
Exit    0 ok, 1 failed, 2 bad command line, 3 pane missing or ambiguous,
        4 AIODev unreachable, 130 interrupted.

Turn on Command Line Control in AIODev's Settings (control.enabled) first.
`

WAIT_DEFAULT_TIMEOUT_MS :: 30000

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

// Reads aio's own options, which come before the command. `instance` is the AIODEV_INSTANCE value,
// overridden by --instance. Strings borrow from args.
@(require_results)
parse_options :: proc(args: []string, instance: string) -> (Options, string) {
	o := Options {
		instance = instance,
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
			if i + 1 == len(args) || !valid_instance(args[i + 1]) {
				return {}, "--instance takes 1 to 32 letters, digits, - or _"
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

// The pipe request for a command: the caller pane, the reply format, then the command line.
// `commands` and `help <command>` ask AIODev's catalogue.
@(require_results)
request :: proc(o: Options, caller: string, allocator := context.allocator) -> []string {
	args := make([dynamic]string, 0, len(o.args) + 3, allocator)
	append(&args, caller, o.json ? "json" : "text")
	switch o.args[0] {
	case "commands", "help":
		append(&args, "app.commands")
		append(&args, ..o.args[1:])
	case:
		append(&args, ..o.args)
	}
	return args[:]
}

// The app's own --instance rule decides which names are valid.
@(private, require_results)
valid_instance :: proc(name: string) -> bool {
	_, err := instance.parse({"--instance", name})
	return err == .None
}
