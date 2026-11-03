package settings

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

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
	return executable_stem(text[start:])
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
	executable := shell_executable(command)
	if !integration ||
	   !(strings.equal_fold(executable, "pwsh") || strings.equal_fold(executable, "powershell")) {
		return command
	}
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

shell_icon :: proc(executable, override: string) -> string {
	if override != "" {return override}
	if strings.equal_fold(executable, "cmd") {return "C:"}
	for name in ([?]string{"wsl", "bash", "zsh", "fish", "sh"}) {
		if strings.equal_fold(executable, name) {return "$"}
	}
	return ">_"
}

display_title :: proc(raw: string, allocator := context.allocator) -> string {
	bytes := make([dynamic]u8, 0, min(1024, len(raw)), allocator)
	for r in raw {
		if r < ' ' || r >= 0x7f && r <= 0x9f {continue}
		encoded, count := utf8.encode_rune(r)
		if len(bytes) + count > 1024 {break}
		if _, err := append(&bytes, ..encoded[:count]); err != nil {break}
	}
	return string(bytes[:])
}

@(private)
hex_digit :: proc(c: u8) -> (u8, bool) {
	if c >= '0' && c <= '9' {return c - '0', true}
	if c >= 'a' && c <= 'f' {return c - 'a' + 10, true}
	if c >= 'A' && c <= 'F' {return c - 'A' + 10, true}
	return 0, false
}

// Windows drive and UNC paths display with backslashes; other paths, such as WSL or Unix ones, keep
// their slashes.
@(private)
windows_separators :: proc(path: string) -> string {
	drive :=
		len(path) >= 2 &&
		path[1] == ':' &&
		((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z'))
	if !drive && !strings.has_prefix(path, `\\`) && !strings.has_prefix(path, "//") {return path}
	bytes := transmute([]u8)path
	for &c in bytes {if c == '/' {c = '\\'}}
	return path
}

// The display form of a shell directory: file URIs are decoded and Windows paths use backslashes.
@(require_results)
directory_label :: proc(
	raw: string,
	allocator := context.allocator,
) -> (
	string,
	runtime.Allocator_Error,
) {
	text := raw
	if !strings.has_prefix(text, "file://") {
		copy, err := strings.clone(raw, allocator)
		return windows_separators(copy), err
	}
	text = text[7:]
	if slash := strings.index_byte(text, '/'); slash >= 0 {
		host, path := text[:slash], text[slash:]
		drive := len(path) >= 3 && path[0] == '/' && path[2] == ':'
		text = path
		if host != "" && !strings.equal_fold(host, "localhost") && !drive {
			text = fmt.tprintf("//%s%s", host, path)
		}
	}
	if len(text) >= 3 && text[0] == '/' && text[2] == ':' {text = text[1:]}
	builder, err := strings.builder_make(allocator)
	if err != nil {return "", err}
	defer strings.builder_destroy(&builder)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '%' && i + 2 < len(text) {
			hi, hi_ok := hex_digit(text[i + 1])
			lo, lo_ok := hex_digit(text[i + 2])
			if hi_ok && lo_ok && hi * 16 + lo >= ' ' {
				c = hi * 16 + lo
				i += 2
			}
		}
		if strings.write_byte(&builder, c) != 1 {return "", .Out_Of_Memory}
	}
	decoded := strings.to_string(builder)
	if !utf8.valid_string(decoded) {return strings.clone(raw, allocator)}
	copy, clone_error := strings.clone(decoded, allocator)
	return windows_separators(copy), clone_error
}
