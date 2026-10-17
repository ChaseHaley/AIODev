package aioctl

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "aio:control"
import "aio:instance"

USAGE :: `aioctl [--name <name>] <command> [args...]
launch [--fresh] [--settings <file>] [--shell <command>] [--size <cols>x<rows>] [--keep-env]
doctor
stop
help [<command>]
Name defaults to verify; names contain 1..32 ASCII letters, digits, hyphens, or underscores.
In PowerShell, quote positions such as '5,4' so each col,row remains one argument.
Exit codes: 0 success, 1 failed check or request, 2 usage error.
`

Options :: struct {
	name: string,
	args: []string,
	fresh, keep_env: bool,
	settings, shell: string,
	columns, rows: int,
}

@(require_results)
parse_options :: proc(args: []string) -> (Options, string) {
	args := args
	o := Options{name = "verify", columns = 120, rows = 32}
	if len(args) > 0 && args[0] == "--name" {
		if len(args) < 2 { return {}, "supply a name after --name; use help" }
		_, err := instance.parse({"--instance", args[1]})
		if err != .None { return {}, "use a name of 1..32 ASCII letters, digits, hyphens, or underscores" }
		o.name, args = args[1], args[2:]
	}
	if len(args) == 0 { return {}, "choose a command; use help" }
	for arg in args {
		if !utf8.valid_string(arg) || strings.contains(arg, "\x00") {
			return {}, "use valid UTF-8 arguments without NUL characters"
		}
	}
	o.args = args
	switch args[0] {
	case "help":
		if len(args) > 2 { return {}, "use help [command]" }
	case "doctor", "stop":
		if len(args) != 1 { return {}, "remove the extra arguments; use help" }
	case "launch":
		seen: [5]bool
		for i := 1; i < len(args); i += 1 {
			index := -1
			switch args[i] {
			case "--fresh": index, o.fresh = 0, true
			case "--keep-env": index, o.keep_env = 1, true
			case "--settings", "--shell", "--size":
				flag := args[i]
				index = flag == "--settings" ? 2 : (flag == "--shell" ? 3 : 4)
				i += 1
				if i == len(args) || strings.has_prefix(args[i], "--") {
					return {}, "supply a value after the launch option; use help launch"
				}
				value := args[i]
				if value == "" || strings.contains_any(value, "\r\n\x00") || !utf8.valid_string(value) {
					return {}, "use a nonempty single-line launch value"
				}
				switch flag {
				case "--settings": o.settings = value
				case "--shell": o.shell = value
				case "--size":
					request, err := control.parse({"resize", value})
					if err.advice != "" { return {}, "use --size <cols>x<rows>, each dimension 1..1000" }
					size := request.(control.Resize)
					o.columns, o.rows = size.columns, size.rows
				}
			case: return {}, "unknown launch option; use help launch"
			}
			if seen[index] { return {}, "use each launch option once" }
			seen[index] = true
		}
		if o.settings != "" && (seen[3] || seen[4]) {
			return {}, "--settings supplies all settings; omit --shell and --size"
		}
	case:
		if split_position(args) {
			return {}, "quote the position in PowerShell, e.g. '5,4', as one col,row argument"
		}
	}
	return o, ""
}

@(private)
bare_number :: proc(text: string) -> bool {
	if text == "" { return false }
	for c in text {
		if c < '0' || c > '9' { return false }
	}
	return true
}

@(private)
split_position :: proc(args: []string) -> bool {
	if len(args) < 4 { return false }
	positions: []int
	if args[0] == "expect" && (args[1] == "cursor" || args[1] == "cell") {
		positions = []int{2}
	} else if args[0] == "mouse" {
		switch args[1] {
		case "move", "down", "up", "click", "wheel": positions = []int{2}
		case "drag": positions = []int{2, 3}
		}
	}
	for i in positions {
		if i+1 < len(args) && bare_number(args[i]) && bare_number(args[i+1]) { return true }
	}
	return false
}

response_body :: proc(text: string) -> string {
	body := text
	for len(body) > 0 && (body[len(body)-1] == '\n' || body[len(body)-1] == '\r') {
		body = body[:len(body)-1]
	}
	return body
}

@(require_results)
safe_data_path :: proc(repo, path, name: string) -> bool {
	_, err := instance.parse({"--instance", name})
	if err != .None || len(repo) < 3 || repo[1:3] != `:\` { return false }
	if strings.contains_any(repo, "/\r\n\x00") || strings.contains(repo, `\..`) { return false }
	suffix := `\build\verify\`
	if len(path) != len(repo)+len(suffix)+len(name) { return false }
	return strings.equal_fold(path[:len(repo)], repo) &&
	       strings.equal_fold(path[len(repo):len(repo)+len(suffix)], suffix) &&
	       strings.equal_fold(path[len(repo)+len(suffix):], name)
}

@(require_results)
settings_text :: proc(
	o: Options, repo, data_dir: string, allocator := context.allocator,
) -> (string, bool) {
	if o.columns < 1 || o.columns > 1000 || o.rows < 1 || o.rows > 1000 ||
	   len(o.shell) > 32767 || repo == "" || len(repo) > 32767 ||
	   strings.contains_any(o.shell, "\r\n\x00") ||
	   strings.contains_any(repo, "\r\n\x00\"") || !utf8.valid_string(o.shell) ||
	   !utf8.valid_string(repo) { return "", false }
	shell := o.shell
	generated: string
	defer delete(generated, allocator)
	if shell == "" {
		command, ok := default_shell(data_dir, allocator)
		if !ok { return "", false }
		generated, shell = command, command
	}
	if len(shell) > 32767 { return "", false }
	b, allocation_error := strings.builder_make(allocator)
	if allocation_error != nil { return "", false }
	defer strings.builder_destroy(&b)
	buffer: [64]u8
	size := fmt.bprintf(buffer[:], "\nwindow.columns = %d\nwindow.rows = %d\n", o.columns, o.rows)
	parts := [?]string{"shell.command = \"", shell, "\"\nshell.directory = \"", repo,
		"\"\nfont.family = Cascadia Mono\ncursor.blink = false", size}
	for p in parts {
		if strings.write_string(&b, p) != len(p) { return "", false }
	}
	text, err := strings.clone(strings.to_string(b), allocator)
	return text, err == nil
}

@(private, require_results)
default_shell :: proc(data_dir: string, allocator: runtime.Allocator) -> (string, bool) {
	if data_dir == "" || strings.contains_any(data_dir, "\r\n\x00\"") || !utf8.valid_string(data_dir) {
		return "", false
	}
	b, allocation_error := strings.builder_make(allocator)
	if allocation_error != nil { return "", false }
	defer strings.builder_destroy(&b)
	prefix := `pwsh -NoLogo -NoProfile -NoExit -Command "Set-PSReadLineOption -HistorySavePath '`
	if strings.write_string(&b, prefix) != len(prefix) { return "", false }
	start := 0
	for c, i in data_dir {
		if c != '\'' { continue }
		part := data_dir[start:i]
		if strings.write_string(&b, part) != len(part) || strings.write_string(&b, "''") != 2 {
			return "", false
		}
		start = i+1
	}
	for part in ([]string{data_dir[start:], `\history.txt' -PredictionSource None"`}) {
		if strings.write_string(&b, part) != len(part) { return "", false }
	}
	text, err := strings.clone(strings.to_string(b), allocator)
	return text, err == nil
}

History :: enum { Unknown, Isolated, Custom_Shell, Settings_File }
Record :: struct { pid: u32, created: u64, executable: string, keep_env: bool, history: History }

@(require_results)
response_field :: proc(text, key: string, allocator := context.allocator) -> (string, bool) {
	remaining := text
	for remaining != "" {
		i := strings.index_byte(remaining, '=')
		if i < 1 { return "", false }
		name := remaining[:i]
		remaining = remaining[i+1:]
		if len(remaining) == 0 { return "", false }
		end := 0
		if remaining[0] == '"' {
			end = 1
			for end < len(remaining) && remaining[end] != '"' {
				if remaining[end] == '\\' { end += 1 }
				end += 1
			}
			if end >= len(remaining) { return "", false }
			end += 1
		} else {
			for end < len(remaining) && remaining[end] != ' ' { end += 1 }
		}
		if end < len(remaining) && remaining[end] != ' ' { return "", false }
		if name == key {
			if remaining[0] == '"' {
				value, allocated, ok := strconv.unquote_string(remaining[:end], allocator)
				if !ok { return "", false }
				if allocated { return value, true }
				copy, err := strings.clone(value, allocator)
				return copy, err == nil
			}
			copy, err := strings.clone(remaining[:end], allocator)
			return copy, err == nil
		}
		remaining = strings.trim_space(remaining[end:])
	}
	return "", false
}

@(require_results)
parse_record :: proc(text: string) -> (Record, bool) {
	remaining_text := strings.trim_space(text)
	r: Record
	seen: [5]bool
	for line in strings.split_lines_iterator(&remaining_text) {
		i := strings.index_byte(line, '=')
		if i < 1 { return {}, false }
		key, value := line[:i], line[i+1:]
		index := -1
		switch key {
		case "pid":
			index = 0
			n, ok := strconv.parse_u64(value)
			if !ok || n == 0 || n > u64(max(u32)) { return {}, false }
			r.pid = u32(n)
		case "created":
			index = 1
			n, ok := strconv.parse_u64(value)
			if !ok || n == 0 { return {}, false }
			r.created = n
		case "executable":
			index, r.executable = 2, value
			if value == "" { return {}, false }
		case "no_color":
			index = 3
			if value != "removed" && value != "kept" { return {}, false }
			r.keep_env = value == "kept"
		case "history":
			index = 4
			switch value {
			case "isolated": r.history = .Isolated
			case "custom-shell": r.history = .Custom_Shell
			case "settings-file": r.history = .Settings_File
			case: return {}, false
			}
		case: return {}, false
		}
		if seen[index] { return {}, false }
		seen[index] = true
	}
	return r, seen[0] && seen[1] && seen[2] && seen[3]
}
