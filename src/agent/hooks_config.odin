package agent

import "core:encoding/json"
import "core:strconv"
import "core:strings"

// Installing the SessionStart hooks. Claude Code's settings.json and Codex's hooks.json share the
// shape {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": ...}]}]}}. The new group
// is spliced into the user's text, so the rest of the file keeps its formatting and member order.

Hook_Install :: enum u8 {
	Added,
	// A hook already runs the command.
	Present,
	// The text is not JSON of that shape, so it is left alone.
	Invalid,
}

UTF8_BOM :: "\xef\xbb\xbf"

// Adds a SessionStart group running `command` to a settings file's text, unless a hook already runs
// it. Empty text stands for a file that does not exist yet. The new text is in `allocator`.
hooks_install :: proc(
	text, command: string,
	timeout_seconds: int,
	allocator := context.allocator,
) -> (
	string,
	Hook_Install,
) {
	bom := strings.has_prefix(text, UTF8_BOM)
	body := bom ? text[len(UTF8_BOM):] : text
	if strings.trim_space(body) == "" {body = "{}"}
	present, valid := hooks_present(body, command)
	if !valid {return "", .Invalid}
	if present {return "", .Present}
	command_json, command_error := json.marshal(command, {}, context.temp_allocator)
	if command_error != nil {return "", .Invalid}
	digits: [20]u8
	timeout := strconv.write_int(digits[:], i64(timeout_seconds), 10)
	// Built by concatenation: fmt reads braces as its own syntax.
	group := strings.concatenate(
		{`{"hooks":[{"type":"command","command":`, string(command_json), `,"timeout":`, timeout, `}]}`},
		context.temp_allocator,
	)
	root := skip_space(body, 0)
	at: int
	insertion: string
	if hooks, has_hooks := member_value(body, root, "hooks"); !has_hooks {
		event := strings.concatenate({`"hooks":{"SessionStart":[`, group, `]}`}, context.temp_allocator)
		at, insertion = container_insert(body, root, event)
	} else if groups, has_event := member_value(body, hooks, "SessionStart"); !has_event {
		event := strings.concatenate({`"SessionStart":[`, group, `]`}, context.temp_allocator)
		at, insertion = container_insert(body, hooks, event)
	} else {
		at, insertion = container_insert(body, groups, group)
	}
	result := strings.concatenate({bom ? UTF8_BOM : "", body[:at], insertion, body[at:]}, allocator)
	if _, parse_error := json.parse_string(
		result[bom ? len(UTF8_BOM) : 0:],
		.JSON,
		allocator = context.temp_allocator,
	); parse_error != .None {
		delete(result, allocator)
		return "", .Invalid
	}
	return result, .Added
}

// Whether the text is a settings object of the hooks shape, and whether one of its SessionStart hooks
// already runs `command`.
@(private)
hooks_present :: proc(body, command: string) -> (present, valid: bool) {
	// Strict JSON, as both harnesses read it; the splice does not step over comments.
	value, parse_error := json.parse_string(body, .JSON, allocator = context.temp_allocator)
	if parse_error != .None {return false, false}
	root, is_object := value.(json.Object)
	if !is_object {return false, false}
	hooks_value, has_hooks := root["hooks"]
	if !has_hooks {return false, true}
	hooks, hooks_object := hooks_value.(json.Object)
	if !hooks_object {return false, false}
	event_value, has_event := hooks["SessionStart"]
	if !has_event {return false, true}
	groups, is_array := event_value.(json.Array)
	if !is_array {return false, false}
	for group_value in groups {
		group, group_object := group_value.(json.Object)
		if !group_object {continue}
		handlers, handlers_array := group["hooks"].(json.Array)
		if !handlers_array {continue}
		for handler_value in handlers {
			handler, handler_object := handler_value.(json.Object)
			if !handler_object {continue}
			if text, is_string := handler["command"].(json.String); is_string && string(text) == command {
				return true, true
			}
		}
	}
	return false, true
}

// Where `insertion` goes at the start of the object or array opening at `open`, and the insertion with
// the comma that separates it from the members already there.
@(private)
container_insert :: proc(body: string, open: int, insertion: string) -> (int, string) {
	next := skip_space(body, open + 1)
	if next < len(body) && (body[next] == '}' || body[next] == ']') {return open + 1, insertion}
	return open + 1, strings.concatenate({insertion, ","}, context.temp_allocator)
}

// The start of the value of `key` in the object opening at `open`. The text has already parsed, so
// the scan assumes well-formed JSON; keys are compared as written.
@(private)
member_value :: proc(body: string, open: int, key: string) -> (int, bool) {
	i := skip_space(body, open + 1)
	for i < len(body) && body[i] == '"' {
		key_end := string_end(body, i)
		name := body[i + 1:key_end - 1]
		i = skip_space(body, key_end)
		i = skip_space(body, i + 1)
		if name == key {return i, true}
		i = skip_space(body, value_end(body, i))
		if i < len(body) && body[i] == ',' {i = skip_space(body, i + 1)}
	}
	return 0, false
}

// The index just past the value starting at `i`.
@(private)
value_end :: proc(body: string, i: int) -> int {
	if i >= len(body) {return i}
	switch body[i] {
	case '"':
		return string_end(body, i)
	case '{', '[':
		depth := 0
		for j := i; j < len(body); j += 1 {
			switch body[j] {
			case '"':
				j = string_end(body, j) - 1
			case '{', '[':
				depth += 1
			case '}', ']':
				depth -= 1
				if depth == 0 {return j + 1}
			}
		}
		return len(body)
	}
	j := i
	for j < len(body) && strings.index_byte(",}] \t\r\n", body[j]) < 0 {j += 1}
	return j
}

// The index just past the string whose opening quote is at `i`.
@(private)
string_end :: proc(body: string, i: int) -> int {
	for j := i + 1; j < len(body); j += 1 {
		switch body[j] {
		case '\\':
			j += 1
		case '"':
			return j + 1
		}
	}
	return len(body)
}

@(private)
skip_space :: proc(body: string, i: int) -> int {
	j := i
	for j < len(body) && strings.index_byte(" \t\r\n", body[j]) >= 0 {j += 1}
	return j
}
