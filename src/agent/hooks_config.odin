package agent

import "core:encoding/json"
import "core:strconv"
import "core:strings"

// Installing hooks. Claude Code's settings.json and Codex's hooks.json share the shape
// {"hooks": {"<Event>": [{"matcher": ..., "hooks": [{"type": "command", "command": ...}]}]}}.
// Antigravity's hooks.json names each hook, {"<name>": {"<Event>": [...]}}, and AIODev's is AGY_HOOK_NAME;
// a tool event there takes such groups, but any other event takes its handlers directly,
// [{"type": "command", "command": ...}], because agy refuses a group on them. The new group or handler
// is spliced into the user's text, so the rest of the file keeps its formatting and member order.

Hooks_Layout :: enum u8 {
	// {"hooks": {"<Event>": [group]}}: Claude Code and Codex.
	Grouped,
	// {AGY_HOOK_NAME: {"<Event>": [group or handler]}}: Antigravity.
	Named,
}

// The name of AIODev's hook in Antigravity's hooks.json.
AGY_HOOK_NAME :: "aiodev"

Hook_Install :: enum u8 {
	Added,
	// A hook already runs the command.
	Present,
	// The text is not JSON of that shape, so it is left alone.
	Invalid,
}

UTF8_BOM :: "\xef\xbb\xbf"

// Adds a group, or for an untargeted event of the Named layout a handler, running `command` to the
// `event` hooks of a settings file's text, unless a hook of that event already runs it. A non-empty
// `matcher` is written on the group. Empty text stands for a file that does not exist yet. The new text
// is in `allocator`.
hooks_install :: proc(
	text: string,
	layout: Hooks_Layout,
	event, matcher, command: string,
	timeout_seconds: int,
	allocator := context.allocator,
) -> (
	string,
	Hook_Install,
) {
	bom := strings.has_prefix(text, UTF8_BOM)
	body := bom ? text[len(UTF8_BOM):] : text
	if strings.trim_space(body) == "" {body = "{}"}
	container := layout == .Named ? AGY_HOOK_NAME : "hooks"
	present, valid := hooks_present(body, container, event, command)
	if !valid {return "", .Invalid}
	if present {return "", .Present}
	command_json, command_error := json.marshal(command, {}, context.temp_allocator)
	if command_error != nil {return "", .Invalid}
	event_json, event_error := json.marshal(event, {}, context.temp_allocator)
	if event_error != nil {return "", .Invalid}
	container_json, container_error := json.marshal(container, {}, context.temp_allocator)
	if container_error != nil {return "", .Invalid}
	matcher_part := ""
	if matcher != "" {
		matcher_json, matcher_error := json.marshal(matcher, {}, context.temp_allocator)
		if matcher_error != nil {return "", .Invalid}
		matcher_part = strings.concatenate(
			{`"matcher":`, string(matcher_json), `,`},
			context.temp_allocator,
		)
	}
	digits: [20]u8
	timeout := strconv.write_int(digits[:], i64(timeout_seconds), 10)
	// Built by concatenation: fmt reads braces as its own syntax.
	entry := strings.concatenate(
		{`{"type":"command","command":`, string(command_json), `,"timeout":`, timeout, `}`},
		context.temp_allocator,
	)
	if layout == .Grouped || matcher != "" {
		entry = strings.concatenate({`{`, matcher_part, `"hooks":[`, entry, `]}`}, context.temp_allocator)
	}
	root := skip_space(body, 0)
	at: int
	insertion: string
	if hooks, has_hooks := member_value(body, root, container); !has_hooks {
		member := strings.concatenate(
			{string(container_json), `:{`, string(event_json), `:[`, entry, `]}`},
			context.temp_allocator,
		)
		at, insertion = container_insert(body, root, member)
	} else if entries, has_event := member_value(body, hooks, event); !has_event {
		member := strings.concatenate({string(event_json), `:[`, entry, `]`}, context.temp_allocator)
		at, insertion = container_insert(body, hooks, member)
	} else {
		at, insertion = container_insert(body, entries, entry)
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

// Whether the text is a settings object of the hooks shape, and whether one of the hooks of `event` in
// its `container` member already runs `command`, as the handler of a group or a handler of its own.
@(private)
hooks_present :: proc(body, container, event, command: string) -> (present, valid: bool) {
	// Strict JSON, as every harness reads it; the splice does not step over comments.
	value, parse_error := json.parse_string(body, .JSON, allocator = context.temp_allocator)
	if parse_error != .None {return false, false}
	root, is_object := value.(json.Object)
	if !is_object {return false, false}
	hooks_value, has_hooks := root[container]
	if !has_hooks {return false, true}
	hooks, hooks_object := hooks_value.(json.Object)
	if !hooks_object {return false, false}
	event_value, has_event := hooks[event]
	if !has_event {return false, true}
	entries, is_array := event_value.(json.Array)
	if !is_array {return false, false}
	for entry_value in entries {
		entry, entry_object := entry_value.(json.Object)
		if !entry_object {continue}
		if handler_runs(entry, command) {return true, true}
		handlers, handlers_array := entry["hooks"].(json.Array)
		if !handlers_array {continue}
		for handler_value in handlers {
			handler, handler_object := handler_value.(json.Object)
			if handler_object && handler_runs(handler, command) {return true, true}
		}
	}
	return false, true
}

@(private)
handler_runs :: proc(handler: json.Object, command: string) -> bool {
	text, is_string := handler["command"].(json.String)
	return is_string && string(text) == command
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
