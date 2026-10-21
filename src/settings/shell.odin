package settings

import "base:runtime"
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
	text = text[start:]
	if len(text) >= 4 &&
	   strings.equal_fold(text[len(text) - 4:], ".exe") {text = text[:len(text) - 4]}
	return text
}

shell_icon :: proc(executable, override: string) -> string {
	if override != "" {return override}
	if strings.equal_fold(executable, "cmd") {return "C:"}
	for name in ([?]string{"wsl", "bash", "zsh", "fish", "sh"}) {
		if strings.equal_fold(executable, name) {return "$"}
	}
	return ">_"
}

shell_command_line :: proc(command: string, report_directory: bool) -> string {
	executable := shell_executable(command)
	if !report_directory ||
	   !(strings.equal_fold(executable, "pwsh") ||
			   strings.equal_fold(executable, "powershell")) {return command}
	for arg in strings.fields(command, context.temp_allocator) {
		if len(arg) < 2 || arg[0] != '-' {continue}
		name := arg[1:]
		for option in ([?]string{"command", "commandwithargs", "encodedcommand", "file", "noninteractive"}) {
			if len(name) <= len(option) &&
			   strings.equal_fold(name, option[:len(name)]) {return command}
		}
	}
	script :=
		"$global:__AIODevPrompt=$function:prompt; function global:prompt { " +
		"try { if ($PWD.Provider.Name -eq 'FileSystem') { " +
		"[Console]::Write(([char]27).ToString()+']7;'+([uri]$PWD.ProviderPath).AbsoluteUri+([char]7)) " +
		"} } catch {}; & $global:__AIODevPrompt }"
	return fmt.tprintf("%s -NoExit -Command \"%s\"", command, script)
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
