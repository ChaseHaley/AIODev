package cli

import "aio:cli_protocol"
import "aio:events"
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
       aio events [--json] [<name>...]
       aio exec (<file.lua> | -e <code> | - | <action>) [<key>=<value>...] [--args <json> | @<file>]
                [--json] [--for <duration>] [--fail-fast]
       aio config check [--data-dir <directory>] [<file>]
       aio types [--data-dir <directory>] [--force]
       aio commands
       aio help [<command>]
       aio version
       aio agent-session (claude | codex)
       aio turn-hook (claude | codex) (prompt | stop | edit)

Runs AIODev commands from scripts and coding agents. Every command in the everything palette
runs by name, such as aio tab.next; aio commands lists AIODev's commands, and aio help
<command> explains one's options, their defaults and an example of each, for aio's own wait,
events, exec, config, types, commands, help, version, agent-session and turn-hook too. aio version prints
aio's build and the running AIODev's, and aio warns on stderr when the two differ.

Panes   --pane takes a pane id, a pane name, here or focused. Inside an AIODev pane the
        default is here, the pane aio runs in; elsewhere it is the focused pane.
        --workspace takes a workspace id or name; workspace.change, pane.move_workspace
        and tab.move_workspace open their dialog without it.
Files   aio pane.open_markdown [--direction left|right|up|down] [--focus] <file>
            Shows a Markdown file beside the pane and updates it when the file changes.
        aio pane.open_web [--float | --direction left|right|up|down] [--focus] [<url>]
            Opens a web pane beside the target, or a separate float with --float.
        aio layout.apply [--focus] <file>
            Opens a tab of named panes from a JSON layout; prints their ids in order.
Common  aio tab.new [--cwd <directory>] [--name <name>] [--tab-name <name>] [--focus] [-- <program>]
        aio workspace.new [--cwd <directory>] [--name <name>] [--focus] [-- <program>]
        aio pane.split [--direction left|right|up|down] [--ratio 0.05-0.95] [-- <program>]
            Each prints the new pane's id, starts in aio's working directory unless --cwd
            names another, and leaves focus where it is unless --focus.
            tab.new --name names the pane; workspace.new --name names the workspace.
            --command-file <file> takes the program and arguments from a JSON array of
            strings instead, so no shell quotes them.
        aio tab.rename <name>             names the pane's tab
        aio workspace.rename [--workspace <workspace>] <name>
            Without a name, tab.rename opens its dialog, and so does workspace.rename without
            --workspace.
        aio pane.send [--enter] <text>    types text into the pane; --enter then presses Enter
        aio pane.send --file <file>       types a UTF-8 file's text exactly
        aio pane.read [--lines <rows>] [--scrollback] [--unwrap]
            Prints the pane's visible text; --scrollback adds the history above it, --unwrap joins
            rows the terminal wrapped, and --lines keeps the last lines.
        aio pane.list                     one line per pane; --json for details
        aio tab.list, aio workspace.list  one line per tab or workspace
        aio pane.close
Wait    aio wait polls until the pane shows the text, a line matches the pattern or its program
        exits; text and patterns match across rows the terminal wrapped. --idle then waits until the
        screen has not changed for that long, and alone waits only for that. Give --text, --regex,
        --idle or --exit; --idle does not combine with --exit. The default timeout is %d ms, and 0
        waits without limit. --exit prints the exit code, even after the pane closed with its program,
        or closed when it was closed while running.
Events  aio events streams named application events, or all events without names. --json prints one
        JSON object per line; plain output is the event name, a tab and its fields as JSON.
        Ctrl+C exits 130; closing AIODev or the connection exits 4.
Lua     aio exec runs a Lua script with the aio API against AIODev, or one action by name, and prints
        what it returns as JSON; Ctrl+C exits 130 and aio.stop(code) exits with that code.
        aio config check loads init.lua without running its commands and reports its actions, keys,
        modes and problems; it exits 1 when there are problems.
        aio types writes types\aio.lua and .luarc.json beside init.lua for lua-language-server; it
        asks AIODev for your actions and copies the built-in definitions when AIODev is not running.
        Both use the init.lua the running AIODev loads; --data-dir names an instance's data folder
        only when AIODev is not running.
Theme   Inside a pane, AIODEV_THEME_FILE points to the live theme JSON. Read it on each prompt
        render for resolved #RRGGBB colors (colors.accent, colors.foreground, colors.background,
        colors.palette[0..15], and more). The file is updated when the theme changes. No aio call
        or Command line control setting is needed. In PowerShell 7:
        (Get-Content -LiteralPath $env:AIODEV_THEME_FILE -Raw | ConvertFrom-Json).colors.accent
Neovim  To make Neovim in a pane follow the theme,
        add this to init.lua (one line; the plugin is the nvim folder beside aio.exe):
        if vim.env.AIODEV_CLI then vim.opt.rtp:append(vim.fs.dirname(vim.env.AIODEV_CLI) .. "/nvim");
        require("aiodev_theme").setup() end
Hooks   aio agent-session runs from a Claude Code or Codex SessionStart hook and records the
        session the hook names, so the pane can resume it; the "Install agent session hooks"
        command sets it up.
        aio turn-hook runs from a Claude Code or Codex UserPromptSubmit, Stop or PreToolUse hook
        and tells AIODev when a turn starts or ends and which files it is about to edit, while
        "Record agent turns" is on; the "Install agent turn hooks" command sets it up.
Exit    %d ok, %d failed, %d bad command line, %d pane missing or ambiguous,
        %d AIODev unreachable, %d control pipe server unverified, %d interrupted.

Turn on "Command line control" in AIODev's Settings (control.enabled) first.
aio talks only to the AIODev beside it. In a pane of an AIODev elsewhere, it hands the call to the aio
that pane names in AIODEV_CLI; outside its panes, use the aio beside that AIODev.
`

WAIT_DEFAULT_TIMEOUT_MS :: 30000

// The commands aio runs itself, which AIODev's catalogue does not know, so aio answers their help.
// wait's timeout default is spelled literally, held in step by the #assert.
#assert(WAIT_DEFAULT_TIMEOUT_MS == 30000)
@(private, rodata)
local_commands := [?]cli_protocol.Command_Report {
	{
		name = "wait",
		title = "Wait for text, a pattern, a quiet screen or exit",
		usage = "wait [--pane <pane>] ([--text <text> | --regex <pattern>] [--idle <ms>] | --exit) " +
		"[--timeout <ms>]",
		summary = "Polls the pane until its screen shows the text or a matching line, then with --idle until " +
		"the screen stays the same, or until its program exits; --idle alone waits only for the screen to " +
		"stay the same. Text and patterns match across rows the terminal wrapped. On timeout aio exits " +
		"with status 1.",
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
		name = "events",
		title = "Stream application events",
		usage = "events [--json] [<name>...]",
		summary = "Subscribes to the named events, or all events without names, until Ctrl+C (exit 130) " +
		"or AIODev disconnects (exit 4). Plain output is the event name, a tab and its fields as JSON. " +
		"An unknown name fails with the list of names.",
		options = {
			{
				option = "--json",
				description = "prints each event as the JSON object AIODev sends, its type first",
				default = "off",
				example = "--json",
			},
			{
				option = "<name>...",
				description = "the events to stream, such as pane.focused, tab.created or settings.changed",
				default = "all events",
				example = "pane.focused pane.exited",
			},
		},
	},
	{
		name = "exec",
		title = "Run a Lua script or an action",
		usage = "exec (<file.lua> | -e <code> | - | <action>) [<key>=<value>...] [--args <json> | @<file>] " +
		"[--json] [--for <duration>] [--fail-fast]",
		summary = "Runs a Lua script with the aio API, its commands going to AIODev with origin script, " +
		"and prints the value its top level returns as JSON (nothing for nil). The script runs until its " +
		"top level, timers, waits and processes finish, aio.stop(code) ends it with that exit code, or " +
		"Ctrl+C (exit 130). Handler errors print Error: file:line: message and the script goes on; a " +
		"top-level error exits 1 and an unreachable AIODev exits 4. A name that does not end in .lua and " +
		"holds no slash or backslash runs that action once and prints its result as JSON.",
		options = {
			{
				option = "<file.lua> | -e <code> | - | <action>",
				description = "the script file, Lua code given inline, a script read from standard input, " +
				"or an action or command name",
				default = "none (required)",
				example = "-e \"return aio.view()\"",
			},
			{
				option = "<key>=<value>",
				description = "an argument, seen as aio.args.<key> or as the action's field; a number " +
				"or true or false keeps its type, anything else is a string",
				default = "none",
				example = "count=2 force=true name=build",
			},
			{
				option = "--args <json> | @<file>",
				description = "the arguments as JSON text, or a file holding it, instead of key=value " +
				"arguments",
				default = "none",
				example = "--args @args.json",
			},
			{
				option = "--json",
				description = "indents the printed result",
				default = "off",
				example = "--json",
			},
			{
				option = "--for <duration>",
				description = "keeps a script with event handlers running this long, then exits 0; " +
				"a number with ms, s, m or h, seconds without a unit",
				default = "until the script has nothing left to do",
				example = "--for 10m",
			},
			{
				option = "--fail-fast",
				description = "exits 1 at the first handler, timer or process callback error",
				default = "off",
				example = "--fail-fast",
			},
		},
	},
	{
		name = "config",
		title = "Check init.lua",
		usage = "config check [--data-dir <directory>] [<file>]",
		summary = "Loads init.lua as AIODev would, without running commands, and prints the file, the " +
		"number of actions, keys and modes it declares and each problem as file:line: message; exits 1 " +
		"when there is a problem. Without --data-dir or a file it checks the init.lua the running AIODev " +
		"loads; AIODev need not be running.",
		options = {
			{
				option = "--data-dir <directory>",
				description = "checks the init.lua beside the settings of the instance that uses " +
				"this data folder; needed only when that AIODev is not running",
				default = "the init.lua the running AIODev loads, else the settings folder of the " +
				"default instance or --instance",
				example = "--data-dir D:\\aiodev-test",
			},
			{
				option = "<file>",
				description = "the Lua file to check instead",
				default = "the init.lua the running AIODev loads, beside its settings.ini",
				example = "C:\\work\\init.lua",
			},
		},
	},
	{
		name = "types",
		title = "Write Lua type definitions",
		usage = "types [--data-dir <directory>] [--force]",
		summary = "Writes types\\aio.lua beside init.lua with the definitions of the aio API and your " +
		"init.lua actions, as AIODev reports them, and creates .luarc.json there so lua-language-server " +
		"reads them. The init.lua is the one the running AIODev loads. When AIODev is not reachable, it " +
		"copies the built-in definitions from types\\aio.lua beside aio.exe, without your actions. An " +
		"existing .luarc.json is kept, and aio prints the two settings to add; exits 1 when no " +
		"definitions are found or a file cannot be written.",
		options = {
			{
				option = "--data-dir <directory>",
				description = "writes beside the init.lua of the instance that uses this data folder; " +
				"needed only when that AIODev is not running",
				default = "the init.lua the running AIODev loads, else the settings folder of the " +
				"default instance or --instance",
				example = "--data-dir D:\\aiodev-test",
			},
			{
				option = "--force",
				description = "replaces an existing .luarc.json too",
				default = "off",
				example = "--force",
			},
			{
				option = "--json",
				description = "prints {ok, status, path, luarc, actions_included}; luarc is created, " +
				"replaced or kept",
				default = "off",
				example = "--json",
			},
		},
	},
	{
		name = "commands",
		title = "List commands",
		usage = "commands",
		summary = "Prints every command AIODev runs by name, with its title; --json adds usage and summary.",
	},
	{
		name = "help",
		title = "Show help",
		usage = "help [<command>]",
		summary = "Prints aio's usage, or one command's usage, title, summary and options.",
		options = {
			{
				option = "<command>",
				description = "the command to explain: any name aio commands lists, or wait, events, exec, " +
				"config, types, commands, help, version, agent-session or turn-hook",
				default = "none (prints aio's usage)",
				example = "pane.split",
			},
		},
	},
	{
		name = "version",
		title = "Show aio's and AIODev's builds",
		usage = "version",
		summary = "Prints aio's build, then the running AIODev's; --version does the same. aio warns on " +
		"stderr whenever the two differ, and after its own line exits 4 when AIODev is unreachable or 5 " +
		"when its control pipe server is unverified.",
	},
	{
		name = "agent-session",
		title = "Record an agent session",
		usage = "agent-session (claude | codex)",
		summary = "Run by a Claude Code or Codex SessionStart hook: records the session the hook names so " +
		"the pane can resume it. Needs no control pipe, prints nothing and succeeds outside an AIODev pane; " +
		"the \"Install agent session hooks\" command sets it up.",
		options = {
			{
				option = "claude | codex",
				description = "the harness whose hook runs it",
				default = "none (required)",
				example = "claude",
			},
		},
	},
	{
		name = "turn-hook",
		title = "Report an agent turn",
		usage = "turn-hook (claude | codex) (prompt | stop | edit)",
		summary = "Run by a Claude Code or Codex UserPromptSubmit, Stop or PreToolUse hook: tells AIODev " +
		"when a turn starts or ends and which files it is about to edit, so Agent changes can show " +
		"them exactly. Needs no control pipe, prints nothing and succeeds outside an AIODev pane or " +
		"while turn recording is off; the \"Install agent turn hooks\" command sets it up.",
		options = {
			{
				option = "claude | codex",
				description = "the harness whose hook runs it",
				default = "none (required)",
				example = "claude",
			},
			{
				option = "prompt | stop | edit",
				description = "the hook's event: UserPromptSubmit, Stop or a file edit's PreToolUse",
				default = "none (required)",
				example = "prompt",
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
	instance:    string,
	json:        bool,
	// The command and its arguments, as AIODev parses them.
	args:        []string,
	// Set when the command is wait.
	waiting:     bool,
	// Set when the command is version or --version.
	version:     bool,
	wait:        Wait,
	// Set when the command is events, with the event names it gave; none streams every event.
	streaming:   bool,
	event_names: []string,
	// Set when the command is exec.
	executing:   bool,
	exec:        Exec,
	// Set when the command is config check.
	checking:    bool,
	check:       Config_Check,
	// Set when the command is types.
	typing:      bool,
	lua_types:   Lua_Types,
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
	switch o.args[0] {
	case "exec":
		return exec_options(o)
	case "config":
		return config_options(o)
	case "types":
		return types_options(o)
	}
	o.version = o.args[0] == "version" || o.args[0] == "--version"
	// Only an AIODev too old to know the version command fails it, which build_warning reports.
	if o.version && len(o.args) > 1 {return {}, "version takes no arguments"}
	if o.args[0] == "events" {
		o.streaming = true
		// --json may follow the command too, since aio and not AIODev formats the stream.
		names := make([dynamic]string, 0, len(o.args) - 1, context.temp_allocator)
		for word in o.args[1:] {
			if word == "--json" {
				if o.json {return {}, "use --json once"}
				o.json = true
			} else if strings.has_prefix(word, "-") {
				return {}, "events takes --json and event names"
			} else {
				append(&names, word)
			}
		}
		o.event_names = names[:]
		return o, ""
	}
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
// as text, since aio prints its own build beside it and composes any JSON itself; `events` subscribes
// to the names it gave.
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
	if o.streaming {
		command = make([]string, 1 + len(o.event_names), allocator)
		command[0] = cli_protocol.EVENTS_COMMAND
		copy(command[1:], o.event_names)
	} else if name != o.args[0] {
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

// `aio events`' plain line for one stream line: the event's name, a tab and its fields object without
// "type". The stream puts "type" first and event names hold no quotes, so the fields' JSON is kept
// as AIODev wrote it rather than decoded and encoded again. False for a line in another shape.
@(require_results)
event_plain :: proc(line: string, allocator := context.allocator) -> (string, bool) {
	name, rest, valid := event_line_split(line)
	if !valid {return "", false}
	if rest == "}" {return strings.concatenate({name, "\t{}"}, allocator), true}
	return strings.concatenate({name, "\t{", rest[1:]}, allocator), true
}

// The kind a stream line names, for the script host, which hands the whole line to the script as the
// event's fields: the script sets "type" itself. False for a line in another shape or an unknown name.
@(require_results)
event_line_kind :: proc(line: string) -> (events.Kind, bool) {
	name, _, valid := event_line_split(line)
	if !valid {return {}, false}
	return events.kind_named(name)
}

// A stream line's event name and what follows its closing quote: "}" or "," and the other fields.
@(private, require_results)
event_line_split :: proc(line: string) -> (name, rest: string, valid: bool) {
	prefix :: `{"type":"`
	if !strings.has_prefix(line, prefix) {return}
	tail := line[len(prefix):]
	end := strings.index_byte(tail, '"')
	if end <= 0 {return}
	name, rest = tail[:end], tail[end + 1:]
	if rest == "}" {return name, rest, true}
	if !strings.has_prefix(rest, ",") || !strings.has_suffix(rest, "}") {return "", "", false}
	return name, rest, true
}
