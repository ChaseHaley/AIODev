package cli

import "aio:cli_protocol"
import "aio:commands"
import "aio:scripting"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

// `aio exec` and `aio config check`: the parts that need no running AIODev, so tests reach them.
// script_host_windows.odin runs the script against the pipe.

// The file aio config check reads when it names none, beside the instance's settings.ini.
INIT_FILE :: "init.lua"
// The same watchdog budget AIODev gives init.lua, so a check fails where a load would.
@(private)
CONFIG_BUDGET_MS :: 50

Exec_Target :: enum u8 {
	File,
	Code,
	Stdin,
	Action,
}

Exec :: struct {
	target:    Exec_Target,
	// The script's path, the -e code or the action's name; empty for standard input.
	source:    string,
	// The key=value words, in order.
	pairs:     []string,
	// --args' value: JSON text, or @ and a file holding it; "" without --args.
	args:      string,
	// --for in milliseconds; 0 without it.
	for_ms:    int,
	fail_fast: bool,
}

Config_Check :: struct {
	// The file to check; "" checks init.lua beside the instance's settings.
	path:     string,
	data_dir: string,
}

// Reads exec's options, which may come in any order after the command. The first word that is not
// an option is the target; key=value words follow it. Strings borrow from o.args.
@(require_results)
exec_options :: proc(o: Options) -> (Options, string) {
	o := o
	o.executing = true
	pairs := make([dynamic]string, 0, len(o.args), context.temp_allocator)
	has_target, seen_args := false, false
	for j := 1; j < len(o.args); j += 1 {
		word := o.args[j]
		switch word {
		case "--json":
			if o.json {return {}, "use --json once"}
			o.json = true
		case "--fail-fast":
			if o.exec.fail_fast {return {}, "use --fail-fast once"}
			o.exec.fail_fast = true
		case "-":
			if has_target {return {}, "name one script file, -e <code>, - or action"}
			o.exec.target, has_target = .Stdin, true
		case "--args", "--for", "-e":
			if j + 1 == len(o.args) {return {}, fmt.tprintf("supply a value after %s", word)}
			j += 1
			value := o.args[j]
			switch word {
			case "--args":
				if seen_args || value == "" || value == "@" {
					return {}, "use --args once with JSON or @<file>"
				}
				o.exec.args, seen_args = value, true
			case "--for":
				milliseconds, valid := duration_ms(value)
				if o.exec.for_ms > 0 || !valid || milliseconds < 1 {
					return {}, "use --for once with a duration such as 500ms, 30s, 10m or 1h"
				}
				o.exec.for_ms = milliseconds
			case:
				if has_target {return {}, "name one script file, -e <code>, - or action"}
				o.exec.target, o.exec.source, has_target = .Code, value, true
			}
		case:
			if strings.has_prefix(word, "-") {
				return {}, "exec takes --args, --json, --for, --fail-fast, -e and -"
			}
			if !has_target {
				o.exec.target = script_path(word) ? .File : .Action
				o.exec.source, has_target = word, true
				continue
			}
			if strings.index_byte(word, '=') <= 0 {
				return {}, fmt.tprintf("%s is not a key=value argument", word)
			}
			append(&pairs, word)
		}
	}
	if !has_target {return {}, "name a script file, -e <code>, - or an action to exec"}
	if seen_args && len(pairs) > 0 {return {}, "give --args or key=value arguments, not both"}
	if o.exec.target == .Action && (o.exec.for_ms > 0 || o.exec.fail_fast) {
		return {}, "--for and --fail-fast apply to scripts, not actions"
	}
	o.exec.pairs = pairs[:]
	return o, ""
}

// A script file ends in .lua or names a directory; any other word names an action.
@(require_results)
script_path :: proc(word: string) -> bool {
	extension :: ".lua"
	if len(word) >= len(extension) && strings.equal_fold(word[len(word) - len(extension):], extension) {
		return true
	}
	return strings.contains_any(word, `/\`)
}

// A duration such as 500ms, 30s, 10m or 1h; a bare number counts seconds.
@(require_results)
duration_ms :: proc(text: string) -> (int, bool) {
	digits := 0
	for digits < len(text) && text[digits] >= '0' && text[digits] <= '9' {digits += 1}
	if digits == 0 {return 0, false}
	count, valid := strconv.parse_int(text[:digits], 10)
	if !valid {return 0, false}
	unit: int
	switch text[digits:] {
	case "ms":
		unit = 1
	case "", "s":
		unit = 1000
	case "m":
		unit = 60 * 1000
	case "h":
		unit = 60 * 60 * 1000
	case:
		return 0, false
	}
	if count > max(int) / unit {return 0, false}
	return count * unit, true
}

// Config check reads its own options after the check word.
@(require_results)
config_options :: proc(o: Options) -> (Options, string) {
	o := o
	o.checking = true
	if len(o.args) < 2 || o.args[1] != "check" {return {}, "config takes check"}
	for j := 2; j < len(o.args); j += 1 {
		word := o.args[j]
		if word == "--data-dir" {
			if o.check.data_dir != "" || j + 1 == len(o.args) || o.args[j + 1] == "" {
				return {}, "use --data-dir once with a directory"
			}
			j += 1
			o.check.data_dir = o.args[j]
			continue
		}
		if strings.has_prefix(word, "-") {return {}, "config check takes --data-dir and a file"}
		if o.check.path != "" {return {}, "config check takes one file"}
		o.check.path = word
	}
	return o, ""
}

// The script's arguments as JSON: --args' text, or the file it names, checked to be JSON; or an
// object of the key=value arguments, where a JSON number and true or false keep their type and any
// other value is a string; or "" for none. The text borrows from e or is allocated.
@(require_results)
exec_args :: proc(e: Exec, allocator := context.allocator) -> (string, string) {
	if e.args != "" {
		text := e.args
		if text[0] == '@' {
			data, err := os.read_entire_file(text[1:], allocator)
			if err != nil {
				return "", fmt.tprintf("cannot read the --args file %s: %s", text[1:], os.error_string(err))
			}
			text = string(data)
		}
		text = strings.trim_space(text)
		if !json.is_valid(transmute([]u8)text, .JSON) {return "", "--args is not valid JSON"}
		return text, ""
	}
	if len(e.pairs) == 0 {return "", ""}
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '{')
	for pair, index in e.pairs {
		equals := strings.index_byte(pair, '=')
		key, value := pair[:equals], pair[equals + 1:]
		for earlier in e.pairs[:index] {
			if earlier[:strings.index_byte(earlier, '=')] == key {
				strings.builder_destroy(&b)
				return "", fmt.tprintf("give the argument %s once", key)
			}
		}
		if index > 0 {strings.write_byte(&b, ',')}
		json_quote(&b, key)
		strings.write_byte(&b, ':')
		if value == "true" || value == "false" || json.is_valid_number(value, .JSON) {
			strings.write_string(&b, value)
		} else {
			json_quote(&b, value)
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b), ""
}

// Writes text as a JSON string. Bytes past ASCII are UTF-8 and pass through.
@(private)
json_quote :: proc(b: ^strings.Builder, text: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			strings.write_string(b, `\"`)
		case '\\':
			strings.write_string(b, `\\`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case 0 ..< 0x20:
			fmt.sbprintf(b, `\u%04x`, c)
		case:
			strings.write_byte(b, c)
		}
	}
	strings.write_byte(b, '"')
}

// What exec prints for a result: the JSON as given, or indented with --json; "" for no result.
@(require_results)
exec_result_text :: proc(value: string, indent: bool, allocator := context.allocator) -> string {
	if value == "" || !indent {return value}
	return json_indent(value, allocator)
}

// Indents valid JSON two spaces a level, keeping its members in their order, which decoding and
// encoding again would lose. Empty objects and arrays stay on one line.
@(require_results)
json_indent :: proc(text: string, allocator := context.allocator) -> string {
	b := strings.builder_make(0, len(text) * 2, allocator)
	depth := 0
	newline :: proc(b: ^strings.Builder, depth: int) {
		strings.write_byte(b, '\n')
		for _ in 0 ..< depth {strings.write_string(b, "  ")}
	}
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		switch c {
		case '"':
			end := json_string_end(text, i)
			strings.write_string(&b, text[i:end])
			i = end - 1
		case '{', '[':
			strings.write_byte(&b, c)
			next := json_space_end(text, i + 1)
			if next < len(text) && (text[next] == '}' || text[next] == ']') {
				strings.write_byte(&b, text[next])
				i = next
				continue
			}
			depth += 1
			newline(&b, depth)
		case '}', ']':
			depth -= 1
			newline(&b, depth)
			strings.write_byte(&b, c)
		case ',':
			strings.write_byte(&b, c)
			newline(&b, depth)
		case ':':
			strings.write_string(&b, ": ")
		case ' ', '\t', '\r', '\n':
		case:
			strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

// The raw JSON of a top-level object's member, kept as written; false when the object lacks it.
@(require_results)
json_member :: proc(text, key: string) -> (string, bool) {
	i := json_space_end(text, 0)
	if i == len(text) || text[i] != '{' {return "", false}
	i += 1
	for {
		i = json_space_end(text, i)
		if i >= len(text) || text[i] != '"' {return "", false}
		name_end := json_string_end(text, i)
		name := text[i + 1:max(i + 1, name_end - 1)]
		i = json_space_end(text, name_end)
		if i >= len(text) || text[i] != ':' {return "", false}
		start := json_space_end(text, i + 1)
		i = json_value_end(text, start)
		if name == key {return text[start:i], true}
		i = json_space_end(text, i)
		if i >= len(text) || text[i] != ',' {return "", false}
		i += 1
	}
}

@(private, require_results)
json_space_end :: proc(text: string, from: int) -> int {
	i := from
	for i < len(text) && (text[i] == ' ' || text[i] == '\t' || text[i] == '\r' || text[i] == '\n') {i += 1}
	return i
}

// The index after the string starting at the quote at `from`.
@(private, require_results)
json_string_end :: proc(text: string, from: int) -> int {
	i := from + 1
	for i < len(text) {
		switch text[i] {
		case '\\':
			i += 2
		case '"':
			return i + 1
		case:
			i += 1
		}
	}
	return len(text)
}

// The index after the value starting at `from`.
@(private, require_results)
json_value_end :: proc(text: string, from: int) -> int {
	if from >= len(text) {return from}
	switch text[from] {
	case '"':
		return json_string_end(text, from)
	case '{', '[':
		depth := 0
		i := from
		for i < len(text) {
			switch text[i] {
			case '"':
				i = json_string_end(text, i)
				continue
			case '{', '[':
				depth += 1
			case '}', ']':
				depth -= 1
				if depth == 0 {return i + 1}
			}
			i += 1
		}
		return len(text)
	}
	i := from
	for i < len(text) && !strings.contains_rune(",}] \t\r\n", rune(text[i])) {i += 1}
	return i
}

// The exit status for aio.stop's code; Windows keeps the low byte that aio's status carries.
@(require_results)
stop_status :: proc(code: int) -> cli_protocol.Status {
	return cli_protocol.Status(u8(clamp(code, 0, 255)))
}

// Loads the Lua file as AIODev loads init.lua, in a state whose commands are refused, and reports
// it as settings.check_lua does: the path, the counts, then each problem as file:line: message.
// The status is Failed when there is a problem. The chunk is named by the file's name alone: Lua
// cuts long chunk names to their last 60 bytes, which would leave problems naming a partial path.
@(require_results)
config_check :: proc(path: string, allocator := context.allocator) -> (string, cli_protocol.Status) {
	root := filepath.dir(path)
	backend := scripting.Backend {
		command = config_check_refuse,
	}
	config := scripting.Config {
		kind      = .Config,
		root      = root,
		budget_ms = CONFIG_BUDGET_MS,
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, path)
	s, problem := scripting.create(config, backend)
	if s == nil {
		fmt.sbprintf(&b, "\n%s", problem)
		return strings.to_string(b), .Failed
	}
	defer scripting.destroy(s)
	name := filepath.base(path)
	result: scripting.Run_Result
	if source, read_error := os.read_entire_file(path, context.temp_allocator); read_error == nil {
		result = scripting.run_source(s, name, string(source))
	} else {
		result.file = name
		result.message = fmt.tprintf("cannot open %s: %s", path, os.error_string(read_error))
	}
	errors := scripting.take_errors(s)
	declarations := scripting.declarations(s)
	fmt.sbprintf(
		&b,
		"\nactions %d\nkeys %d\nmodes %d",
		len(declarations.actions),
		len(declarations.keys),
		len(declarations.modes),
	)
	problems := 0
	if !result.ok {
		config_problem(&b, root, result.file, result.line, result.message)
		problems += 1
	}
	for err in errors {
		config_problem(&b, root, err.file, err.line, err.message)
		problems += 1
	}
	for key in declarations.keys {
		if _, valid := commands.parse_sequence(key.key); valid {continue}
		message := fmt.tprintf(`key "%s" is not a valid key sequence`, key.key)
		config_problem(&b, root, key.file, key.line, message)
		problems += 1
	}
	return strings.to_string(b), problems > 0 ? .Failed : .Ok
}

// One problem line, as settings.check_lua writes it: the file relative to the checked file's folder
// when it lies inside it, or its name alone when Lua cut the front of a long name to "...", the line,
// and the message without the location Lua already put before it.
@(private)
config_problem :: proc(b: ^strings.Builder, root, file: string, line: int, message: string) {
	message := message
	location := fmt.tprintf("%s:%d: ", file, line)
	if strings.has_prefix(message, location) {message = message[len(location):]}
	shown := file
	if root != "" && len(file) > len(root) + 1 && strings.has_prefix(file, root) &&
	   (file[len(root)] == '\\' || file[len(root)] == '/') {
		shown = file[len(root) + 1:]
	} else if strings.has_prefix(file, "...") {
		shown = filepath.base(file)
	}
	switch {
	case file == "":
		fmt.sbprintf(b, "\n%s", message)
	case line == 0:
		fmt.sbprintf(b, "\n%s: %s", shown, message)
	case:
		fmt.sbprintf(b, "\n%s:%d: %s", shown, line, message)
	}
}

@(private)
config_check_refuse :: proc(_: rawptr, _: u32, _, _, _: string) -> string {
	return `{"ok":false,"status":1,"error":"commands do not run in aio config check"}`
}
