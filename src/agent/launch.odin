package agent

import "core:strings"

// What a resume keeps of how a harness was launched: its options, without the prompt or anything that
// chose a session. The option tables follow each harness's --help (Claude Code 2.1.318, codex-cli
// 0.166.0, omp 18.18.2). An option missing from a table cannot be told from a prompt, so it keeps
// nothing but the session id.
Launch :: struct {
	harness:   Harness,
	// False for a launch that holds no interactive session, such as print mode or a subcommand.
	resumable: bool,
	// The arguments the resume line keeps, in order; nil when only the session id carries over.
	flags:     []string,
	// omp's --profile, which says where omp keeps the pane's sessions; borrowed from the arguments.
	profile:   string,
}

@(private)
Option_Kind :: enum u8 {
	Keep,
	// Takes the next argument as its value.
	Keep_Value,
	// Takes every following argument up to the next option.
	Keep_Values,
	// Takes the next argument as its value unless it is an option.
	Keep_Optional,
	Drop,
	Drop_Value,
	Drop_Values,
	Drop_Optional,
	// The launch is not an interactive session that can be resumed.
	Stop,
}

@(private)
Option :: struct {
	name: string,
	kind: Option_Kind,
}

@(private, rodata)
claude_options := [?]Option {
	{"--add-dir", .Keep_Values},
	{"--agent", .Keep_Value},
	{"--agents", .Keep_Value},
	{"--allow-dangerously-skip-permissions", .Keep},
	{"--allowedTools", .Keep_Values},
	{"--allowed-tools", .Keep_Values},
	{"--append-system-prompt", .Keep_Value},
	{"--autocompact", .Keep_Value},
	{"--ax-screen-reader", .Keep},
	{"--bg", .Stop},
	{"--background", .Stop},
	{"--bare", .Keep},
	{"--betas", .Keep_Values},
	{"--brief", .Keep},
	{"--chrome", .Keep},
	{"--cloud", .Stop},
	{"-c", .Drop},
	{"--continue", .Drop},
	{"--dangerously-skip-permissions", .Keep},
	{"-d", .Keep_Optional},
	{"--debug", .Keep_Optional},
	{"--debug-file", .Keep_Value},
	{"--desktop", .Stop},
	{"--disable-slash-commands", .Keep},
	{"--disallowedTools", .Keep_Values},
	{"--disallowed-tools", .Keep_Values},
	{"--effort", .Keep_Value},
	{"--environment", .Stop},
	{"--exclude-dynamic-system-prompt-sections", .Keep},
	{"--fallback-model", .Keep_Value},
	{"--file", .Drop_Values},
	{"--fork-session", .Drop},
	{"--from-pr", .Drop_Optional},
	{"-h", .Stop},
	{"--help", .Stop},
	{"--ide", .Keep},
	{"--mcp-config", .Keep_Values},
	{"--model", .Keep_Value},
	{"-n", .Keep_Value},
	{"--name", .Keep_Value},
	{"--no-chrome", .Keep},
	{"--no-session-persistence", .Stop},
	{"--permission-mode", .Keep_Value},
	{"--plugin-dir", .Keep_Value},
	{"--plugin-url", .Keep_Value},
	{"-p", .Stop},
	{"--print", .Stop},
	{"--prompt-suggestions", .Keep_Optional},
	{"--remote-control", .Keep_Optional},
	{"--remote-control-session-name-prefix", .Keep_Value},
	{"--restricted", .Keep},
	{"-r", .Drop_Optional},
	{"--resume", .Drop_Optional},
	{"--safe-mode", .Keep},
	{"--session-id", .Drop_Value},
	{"--setting-sources", .Keep_Value},
	{"--settings", .Keep_Value},
	{"--strict-mcp-config", .Keep},
	{"--system-prompt", .Keep_Value},
	{"--system-prompt-snapshot", .Keep_Value},
	{"--teleport", .Drop_Optional},
	{"--tmux", .Drop},
	{"--tools", .Keep_Values},
	{"--verbose", .Keep},
	{"-v", .Stop},
	{"--version", .Stop},
	{"-w", .Drop_Optional},
	{"--worktree", .Drop_Optional},
}

@(private, rodata)
claude_commands := [?]string {
	"agents", "attach", "auth", "auto-mode", "doctor", "gateway", "import", "install", "logs", "mcp",
	"plugin", "plugins", "purge", "respawn", "rm", "setup-token", "stop", "kill", "update", "upgrade",
}

// The options codex and codex resume share, plus resume's own session choices.
@(private, rodata)
codex_options := [?]Option {
	{"-c", .Keep_Value},
	{"--config", .Keep_Value},
	{"--enable", .Keep_Value},
	{"--disable", .Keep_Value},
	{"--remote", .Keep_Value},
	{"--remote-auth-token-env", .Keep_Value},
	{"--strict-config", .Keep},
	{"-i", .Drop_Values},
	{"--image", .Drop_Values},
	{"-m", .Keep_Value},
	{"--model", .Keep_Value},
	{"--oss", .Keep},
	{"--local-provider", .Keep_Value},
	{"-p", .Keep_Value},
	{"--profile", .Keep_Value},
	{"-s", .Keep_Value},
	{"--sandbox", .Keep_Value},
	{"--approve-for-me", .Keep},
	{"--dangerously-bypass-approvals-and-sandbox", .Keep},
	{"--dangerously-bypass-hook-trust", .Keep},
	{"-C", .Keep_Value},
	{"--cd", .Keep_Value},
	{"--worktree", .Drop},
	{"--add-dir", .Keep_Value},
	{"-a", .Keep_Value},
	{"--ask-for-approval", .Keep_Value},
	{"--search", .Keep},
	{"--no-alt-screen", .Keep},
	{"--no-daemon", .Keep},
	{"--last", .Drop},
	{"--all", .Drop},
	{"--include-non-interactive", .Drop},
	{"-h", .Stop},
	{"--help", .Stop},
	{"-V", .Stop},
	{"--version", .Stop},
}

// Codex subcommands that run an interactive session; every other one does not.
@(private, rodata)
codex_session_commands := [?]string{"resume", "fork"}

@(private, rodata)
codex_commands := [?]string {
	"agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control",
	"app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "queue", "archive",
	"delete", "migrate-rollouts", "migrate-nfs-db", "unarchive", "cloud", "exec-server", "features",
	"help",
}

@(private, rodata)
omp_options := [?]Option {
	{"--model", .Keep_Value},
	{"--smol", .Keep_Value},
	{"--slow", .Keep_Value},
	{"--plan", .Keep_Value},
	{"--goal", .Drop_Value},
	{"--prewalk", .Keep},
	{"--no-prewalk", .Keep},
	{"--prewalk-into", .Keep_Value},
	{"--plan-yolo", .Keep},
	{"--plan-yolo-into", .Keep_Value},
	{"--provider", .Keep_Value},
	{"--api-key", .Keep_Value},
	{"--system-prompt", .Keep_Value},
	{"--system-prompt-template", .Keep_Value},
	{"--append-system-prompt", .Keep_Value},
	{"--allow-home", .Keep},
	{"--profile", .Keep_Value},
	{"--alias", .Stop},
	{"--cwd", .Drop_Value},
	{"--mode", .Stop},
	{"--config", .Keep_Value},
	{"--add-dir", .Keep_Value},
	{"-p", .Stop},
	{"--print", .Stop},
	{"-c", .Drop},
	{"--continue", .Drop},
	{"-r", .Drop_Value},
	{"--resume", .Drop_Value},
	{"--restore", .Drop_Value},
	{"--from-claude", .Drop},
	{"--from-codex", .Drop},
	{"--session-dir", .Keep_Value},
	{"--no-session", .Stop},
	{"--models", .Keep_Value},
	{"--no-tools", .Keep},
	{"--no-lsp", .Keep},
	{"--no-pty", .Keep},
	{"--tools", .Keep_Value},
	{"--thinking", .Keep_Value},
	{"--service-tier", .Keep_Value},
	{"--hide-thinking", .Keep},
	{"--advisor", .Keep},
	{"--wait-async", .Keep},
	{"--external-thinking", .Keep},
	{"--hook", .Keep_Value},
	{"-e", .Keep_Value},
	{"--extension", .Keep_Value},
	{"--no-extensions", .Keep},
	{"--no-skills", .Keep},
	{"--skills", .Keep_Value},
	{"--no-rules", .Keep},
	{"--no-context-files", .Keep},
	{"--export", .Stop},
	{"--no-title", .Keep},
	{"--spinner-interval", .Keep_Value},
	{"--max-fps", .Keep_Value},
	{"--motion", .Keep_Value},
	{"--no-ui", .Keep},
	{"--print-thoughts", .Keep},
	{"--max-time", .Keep_Value},
	{"--warn-cost", .Keep_Value},
	{"--max-cost", .Keep_Value},
	{"--auto-approve", .Keep},
	{"--approval-mode", .Keep_Value},
	{"--plugin-dir", .Keep_Value},
	{"-h", .Stop},
	{"--help", .Stop},
	{"-v", .Stop},
	{"--version", .Stop},
}

@(private, rodata)
omp_commands := [?]string {
	"acp", "agents", "anonymize", "auth", "auth-broker", "auth-gateway", "bash", "bench",
	"browser-relay", "cleanse", "clip", "collab", "commit", "completions", "compress", "config",
	"dry-balance", "find", "gallery", "gc", "git", "grep", "grievances", "if-bench", "images", "install",
	"join", "login", "models", "play", "plugin", "predict", "ps", "read", "render", "say", "search",
	"session", "setup", "sh", "share", "shell", "skill", "ssh", "stats", "stream", "tiny-models",
	"token", "toks", "ttsr", "update", "usage", "worktree", "zsh", "edit", "write", "glob", "lsp",
	"python", "notebook", "browser", "computer", "task", "todo", "web_search", "ask",
}

// Reads a harness's arguments, those after its name, into what a resume keeps; flags are in
// `allocator`, other strings borrow from `arguments`.
launch_parse :: proc(harness: Harness, arguments: []string, allocator := context.allocator) -> Launch {
	launch := Launch {
		harness   = harness,
		resumable = harness != .None,
	}
	if harness == .None {return launch}
	options: []Option
	commands: []string
	switch harness {
	case .Claude:
		options, commands = claude_options[:], claude_commands[:]
	case .Codex:
		options, commands = codex_options[:], codex_commands[:]
	case .Omp:
		options, commands = omp_options[:], omp_commands[:]
	case .None:
	}
	kept := make([dynamic]string, 0, len(arguments), allocator)
	exact := true
	positionals := 0
	// Codex's resume and fork take a session before the prompt; both are dropped.
	session_command := false
	for i := 0; i < len(arguments); i += 1 {
		argument := arguments[i]
		if argument == "--" {break}
		if len(argument) < 2 || argument[0] != '-' {
			if positionals == 0 && harness == .Codex && name_listed(codex_session_commands[:], argument) {
				session_command = true
				continue
			}
			if positionals == 0 && !session_command && name_listed(commands, argument) {
				launch.resumable = false
				break
			}
			positionals += 1
			continue
		}
		name, value, attached := argument, "", false
		if equals := strings.index_byte(argument, '='); equals > 0 && argument[1] == '-' {
			name, value, attached = argument[:equals], argument[equals + 1:], true
		}
		option, known := option_find(options, name)
		if !known {
			exact = false
			continue
		}
		if harness == .Omp && name == "--profile" {
			if attached {launch.profile = value} else if i + 1 < len(arguments) {launch.profile = arguments[i + 1]}
		}
		start := i
		switch option.kind {
		case .Stop:
			launch.resumable = false
		case .Keep, .Drop:
			if attached {exact = false}
		case .Keep_Value, .Drop_Value:
			if !attached {i = min(i + 1, len(arguments) - 1)}
		case .Keep_Values, .Drop_Values:
			if !attached {
				for i + 1 < len(arguments) && !option_like(arguments[i + 1]) {i += 1}
			}
		case .Keep_Optional, .Drop_Optional:
			if !attached && i + 1 < len(arguments) && !option_like(arguments[i + 1]) {i += 1}
		}
		if !launch.resumable {break}
		#partial switch option.kind {
		case .Keep, .Keep_Value, .Keep_Values, .Keep_Optional:
			append(&kept, ..arguments[start:i + 1])
		}
	}
	if !launch.resumable {
		delete(kept)
		return launch
	}
	for flag in kept {
		if !token_safe(flag) {exact = false}
	}
	if exact && len(kept) > 0 {
		launch.flags = kept[:]
	} else {
		delete(kept)
	}
	return launch
}

@(private)
option_find :: proc(options: []Option, name: string) -> (Option, bool) {
	for option in options {
		if option.name == name {return option, true}
	}
	return {}, false
}

@(private)
option_like :: proc(argument: string) -> bool {
	return len(argument) >= 2 && argument[0] == '-'
}

@(private)
name_listed :: proc(names: []string, name: string) -> bool {
	for listed in names {
		if listed == name {return true}
	}
	return false
}
