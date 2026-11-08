package settings

import "aio:procinfo"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"

// The shells AIODev knows by name.
Shell_Kind :: enum {
	Other,
	PowerShell_7,
	// Found apart from PowerShell 7; a pwsh command line still infers PowerShell_7.
	PowerShell_7_Preview,
	Windows_PowerShell,
	Command_Prompt,
	WSL,
	Bash,
	Zsh,
	Fish,
	Sh,
}

// What AIODev knows about one shell. `id`, `name` and `command` are the profile machine discovery
// adds, and `name` also names a profile without one. `stem` is matched case-insensitively against a
// command line's executable; an empty stem is never inferred. `badge` is the text icon shown when
// there is no PNG.
Shell_Definition :: struct {
	id, name, stem, command, badge: string,
	// Runs AIODev's prompt integration.
	powershell:                     bool,
	// A Unix shell rather than a Windows one.
	unix:                           bool,
}

@(rodata)
shell_definitions := [Shell_Kind]Shell_Definition {
	.Other = {badge = ">_"},
	.PowerShell_7 = {
		id = "pwsh",
		name = "PowerShell 7",
		stem = "pwsh",
		command = DEFAULT_PROFILE_COMMAND,
		badge = ">_",
		powershell = true,
	},
	.PowerShell_7_Preview = {
		id = "pwsh-preview",
		name = "PowerShell 7 Preview",
		command = DEFAULT_PROFILE_COMMAND,
		badge = ">_",
		powershell = true,
	},
	.Windows_PowerShell = {
		id = "powershell",
		name = "Windows PowerShell",
		stem = "powershell",
		command = "powershell.exe -NoLogo",
		badge = ">_",
		powershell = true,
	},
	.Command_Prompt = {
		id = "cmd",
		name = "Command Prompt",
		stem = "cmd",
		command = "cmd.exe",
		badge = "C:",
	},
	.WSL = {name = "WSL", stem = "wsl", badge = "$", unix = true},
	.Bash = {name = "Bash", stem = "bash", badge = "$", unix = true},
	.Zsh = {stem = "zsh", badge = "$", unix = true},
	.Fish = {stem = "fish", badge = "$", unix = true},
	.Sh = {stem = "sh", badge = "$", unix = true},
}

// The known shell a command line runs, by its executable's stem.
shell_kind :: proc(command: string) -> Shell_Kind {
	executable := shell_executable(command)
	for definition, kind in shell_definitions {
		if definition.stem != "" && strings.equal_fold(executable, definition.stem) {return kind}
	}
	return .Other
}

// The text badge of the shell a command line runs.
shell_badge :: proc(command: string) -> string {
	return shell_definitions[shell_kind(command)].badge
}

shell_executable :: proc(command: string) -> string {
	text := strings.trim_space(command)
	if len(text) == 0 {return ""}
	end := 0
	if text[0] == '"' {
		text = text[1:]
		for end < len(text) && text[end] != '"' {end += 1}
	} else {
		for end < len(text) && text[end] != ' ' && text[end] != '\t' {end += 1}
	}
	text = text[:end]
	start := 0
	for c, i in text {
		if c == '/' || c == '\\' {start = i + 1}
	}
	return procinfo.executable_stem(text[start:])
}

// Wraps the prompt after the user's profile has defined it, as VS Code's PowerShell integration
// does, so the user's prompt still sees $? and $LASTEXITCODE before the directory is reported.
@(private)
POWERSHELL_INTEGRATION :: `if (-not $global:__AIODevPrompt) {
$global:__AIODevPrompt = $function:prompt
function global:prompt {
$p = & $global:__AIODevPrompt
try { if ($PWD.Provider.Name -eq 'FileSystem') { [Console]::Write([char]27 + ']7;' + ([uri]$PWD.ProviderPath).AbsoluteUri + [char]7) } } catch {}
$p
}
}`

// The command line that starts an interactive PowerShell with AIODev's shell integration, or the
// command unchanged for other shells and for launches that run a script or command and exit.
shell_command_line :: proc(command: string, integration: bool) -> string {
	if !integration || !shell_definitions[shell_kind(command)].powershell {return command}
	// Options taking a value, with pwsh's aliases; any other bare argument is a script it would run.
	VALUED :: [?]string{"executionpolicy", "ep", "workingdirectory", "wd", "configurationname",
		"custompipename", "settingsfile", "inputformat", "outputformat", "windowstyle", "version",
		"psconsolefile"}
	EXITS :: [?]string{"command", "commandwithargs", "cwa", "encodedcommand", "ec", "file", "noninteractive"}
	rest := strings.trim_space(command)
	end := rest[0] == '"' ? strings.index_byte(rest[1:], '"') + 2 : strings.index_any(rest, " \t")
	rest = end <= 0 ? "" : rest[end:]
	value := false
	for arg in strings.fields(rest, context.temp_allocator) {
		if len(arg) < 2 || (arg[0] != '-' && arg[0] != '/') {
			if !value {return command}
			value = false
			continue
		}
		value = false
		name := strings.trim_left(arg, "-/")
		for option in EXITS {if option_abbreviates(name, option) {return command}}
		for option in VALUED {if option_abbreviates(name, option) {value = true}}
	}
	wide := make([dynamic]u8, 0, 2 * len(POWERSHELL_INTEGRATION), context.temp_allocator)
	for unit in POWERSHELL_INTEGRATION {append(&wide, u8(unit), 0)}
	encoded := base64.encode(wide[:], allocator = context.temp_allocator)
	return fmt.tprintf("%s -NoExit -EncodedCommand %s", command, encoded)
}

@(private)
option_abbreviates :: proc(name, option: string) -> bool {
	return name != "" && len(name) <= len(option) && strings.equal_fold(name, option[:len(name)])
}
