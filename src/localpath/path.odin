package localpath

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import "cosmos:winpath"

// Path shape (with cosmos:winpath), this machine's names and home expansion. These are facts about
// spellings only: working-directory acceptance (pty) and click-time file opening (open_windows.odin) keep
// their own admission policies on top of them.

// Absolute local drive paths only. UNC, device names and alternate data streams never reach an opener.
@(require_results)
local_absolute :: proc(path: string) -> bool {
	return winpath.is_drive_absolute(path) && valid_characters(path[2:])
}

// The characters and components a local file name may use: no controls, invisible direction marks,
// wildcards, stream colons, reserved device names or trailing dots and spaces.
@(require_results)
valid_characters :: proc(path: string) -> bool {
	if path == "" || !utf8.valid_string(path) {return false}
	for c in path {
		if c < 32 || (c >= 127 && c <= 159) || c == ':' || c == '"' || c == '<' ||
		   c == '>' || c == '|' || c == '?' || c == '*' || c == 0x2028 || c == 0x2029 ||
		   (c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069) ||
		   c == 0x200b || c == 0xfeff {return false}
	}
	start := 0
	for i := 0; i <= len(path); i += 1 {
		if i != len(path) && !winpath.is_separator(path[i]) {continue}
		part := path[start:i]
		if part != "" && part != "." && part != ".." {
			if part[len(part) - 1] == '.' || part[len(part) - 1] == ' ' {return false}
			base := part
			if dot := strings.index_byte(part, '.'); dot >= 0 {base = part[:dot]}
			for reserved in ([?]string{"con", "prn", "aux", "nul", "conin$", "conout$",
				"com\u00b9", "com\u00b2", "com\u00b3", "lpt\u00b9", "lpt\u00b2", "lpt\u00b3"}) {
				if strings.equal_fold(base, reserved) {return false}
			}
			if len(base) == 4 && base[3] >= '0' && base[3] <= '9' &&
			   (strings.equal_fold(base[:3], "com") || strings.equal_fold(base[:3], "lpt")) {
				return false
			}
		}
		start = i + 1
	}
	return true
}

// "~", "~/x" and "~\x" start at the user's home; anything else is copied unchanged.
@(require_results)
expand_home :: proc(path: string, allocator := context.allocator) -> (string, os.Error) {
	if path != "~" && !strings.has_prefix(path, "~/") && !strings.has_prefix(path, "~\\") {
		copy, err := strings.clone(path, allocator)
		if err != nil {
			return "", err
		}
		return copy, nil
	}
	home, err := os.user_home_dir(allocator)
	if err != nil {
		return "", err
	}
	defer delete(home, allocator)
	result, copy_error := strings.concatenate({home, path[1:]}, allocator)
	if copy_error != nil {
		return "", copy_error
	}
	return result, nil
}

// Shorthand a shell would expand: a leading "~" ("~", "~/x" or "~\x"), and anywhere %NAME%, $env:NAME,
// ${env:NAME}, $NAME and ${NAME}, read from this process's environment. Home is USERPROFILE, and an
// unset HOME falls back to it, as PowerShell's $HOME does. An unset name stays as written, as cmd
// leaves it, so a literal "$" or "%" in a file name survives. The result borrows text when nothing
// expands, otherwise buffer; false when the expansion does not fit.
@(require_results)
expand_variables :: proc(text: string, buffer: []u8) -> (string, bool) {
	home := text == "~" || strings.has_prefix(text, "~/") || strings.has_prefix(text, "~\\")
	if !home && strings.index_any(text, "%$") < 0 {return text, true}
	at, i := 0, 0
	expanded := false
	if home {
		length, found, fits := env_value("USERPROFILE", buffer)
		if !fits {return "", false}
		if found {at, i, expanded = length, 1, true}
	}
	for i < len(text) {
		if name, token := variable_at(text, i); token > 0 {
			length, found, fits := variable_value(name, buffer[at:])
			if !fits {return "", false}
			if found {
				at += length
				i += token
				expanded = true
				continue
			}
		}
		if at >= len(buffer) {return "", false}
		buffer[at] = text[i]
		at += 1
		i += 1
	}
	if !expanded {return text, true}
	return string(buffer[:at]), true
}

// The length of the variable spelled at text[at:] when it is set, else 0.
@(require_results)
set_variable_length :: proc(text: string, at: int) -> int {
	name, token := variable_at(text, at)
	if token == 0 {return 0}
	value: [4096]u8 = ---
	_, found, _ := variable_value(name, value[:])
	return found ? token : 0
}

@(private, require_results)
variable_value :: proc(name: string, out: []u8) -> (length: int, found, fits: bool) {
	length, found, fits = env_value(name, out)
	if !found && fits && strings.equal_fold(name, "HOME") {return env_value("USERPROFILE", out)}
	return
}

// The variable name spelled at text[at:] and the length of its spelling, or 0 when none starts there.
// Braced and %-quoted names may hold parentheses, as in %ProgramFiles(x86)%.
@(private, require_results)
variable_at :: proc(text: string, at: int) -> (name: string, length: int) {
	rest := text[at:]
	switch {
	case strings.has_prefix(rest, "%"):
		close := strings.index_byte(rest[1:], '%')
		if close <= 0 || !variable_name(rest[1:1 + close], true) {return "", 0}
		return rest[1:1 + close], close + 2
	case strings.has_prefix(rest, "${"):
		close := strings.index_byte(rest, '}')
		if close < 0 {return "", 0}
		name = rest[2:close]
		if len(name) > 4 && strings.equal_fold(name[:4], "env:") {name = name[4:]}
		if !variable_name(name, true) {return "", 0}
		return name, close + 1
	case strings.has_prefix(rest, "$"):
		start := 1
		if len(rest) > 5 && strings.equal_fold(rest[1:5], "env:") {start = 5}
		end := start
		for end < len(rest) && variable_byte(rest[end], false) {end += 1}
		name = rest[start:end]
		if !variable_name(name, false) {return "", 0}
		return name, end
	}
	return "", 0
}

@(private, require_results)
variable_name :: proc(name: string, parentheses: bool) -> bool {
	if name == "" || (name[0] >= '0' && name[0] <= '9') {return false}
	for i in 0 ..< len(name) {
		if !variable_byte(name[i], parentheses) {return false}
	}
	return true
}

@(private, require_results)
variable_byte :: proc(c: u8, parentheses: bool) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
		(parentheses && (c == '(' || c == ')'))
}

// Which step of settings_relative failed; callers word the two differently.
Settings_Path_Error :: enum {
	None,
	Expand,
	Join,
}

// A path named in the settings file: home expanded, then relative to the settings file's folder.
@(require_results)
settings_relative :: proc(
	path, settings_file: string,
	allocator := context.allocator,
) -> (
	string,
	Settings_Path_Error,
) {
	expanded, err := expand_home(path, allocator)
	if err != nil {return "", .Expand}
	if filepath.is_abs(expanded) {return expanded, .None}
	defer delete(expanded, allocator)
	joined, join_error := filepath.join({filepath.dir(settings_file), expanded}, allocator)
	if join_error != nil {return "", .Join}
	return joined, .None
}

@(private)
hex_value :: proc(c: u8) -> (u8, bool) {
	if c >= '0' && c <= '9' {return c - '0', true}
	if c >= 'a' && c <= 'f' {return c - 'a' + 10, true}
	if c >= 'A' && c <= 'F' {return c - 'A' + 10, true}
	return 0, false
}

// Windows drive and UNC paths display with backslashes; other paths, such as WSL or Unix ones, keep
// their slashes.
@(private)
windows_separators :: proc(path: string) -> string {
	if !winpath.has_drive_prefix(path) && !strings.has_prefix(path, `\\`) && !strings.has_prefix(path, "//") {
		return path
	}
	bytes := transmute([]u8)path
	for &c in bytes {if c == '/' {c = '\\'}}
	return path
}

// The display form of a shell directory: file URIs are decoded and Windows paths use backslashes.
// Display only: unlike link resolution it keeps remote hosts as UNC names and refuses nothing.
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
			hi, hi_ok := hex_value(text[i + 1])
			lo, lo_ok := hex_value(text[i + 2])
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
