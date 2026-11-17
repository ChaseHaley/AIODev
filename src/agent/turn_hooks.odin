package agent

import "aio:turns"
import "base:runtime"
import "core:encoding/json"
import "core:strings"

// What `aio turn-hook` takes from a harness's hook input (WORK-487). Both harnesses send one JSON
// object on standard input with session_id and cwd; UserPromptSubmit adds prompt, and PreToolUse adds
// tool_input.
//   Claude Code: Edit, Write and MultiEdit name tool_input.file_path, NotebookEdit tool_input.notebook_path.
//   Codex: file edits go through its apply_patch tool, whose tool_input.command is the patch text, with
//   one "*** Add File: ", "*** Update File: ", "*** Delete File: " or "*** Move to: " line per path.

// A prompt can be large and the hook reads all of it; the app keeps only a title's worth.
PAYLOAD_LIMIT :: 1024 * 1024

Turn_Payload :: struct {
	session, cwd, prompt: string,
	// Absolute, '/' separated, each once.
	paths:                []string,
}

@(private, rodata)
PATCH_PREFIXES := [?]string{"*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "}

// The event fields a hook's input holds. False for input that is not a JSON object or is over
// PAYLOAD_LIMIT. Input of the right kind that names no paths gives an empty list.
@(require_results)
turn_payload :: proc(
	harness: Harness,
	kind: turns.Hook_Kind,
	payload: []u8,
	allocator := context.allocator,
) -> (
	p: Turn_Payload,
	ok: bool,
) {
	if len(payload) > PAYLOAD_LIMIT || harness != .Claude && harness != .Codex {return {}, false}
	value, parse_error := json.parse(payload, .JSON, false, context.temp_allocator)
	if parse_error != .None {return {}, false}
	root, is_object := value.(json.Object)
	if !is_object {return {}, false}
	defer if !ok {turn_payload_destroy(&p, allocator)}

	cloned: bool
	p.session, cloned = payload_clone(payload_string(root, "session_id"), allocator)
	if !cloned {return p, false}
	cwd := payload_string(root, "cwd")
	p.cwd, cloned = payload_clone(cwd, allocator)
	if !cloned {return p, false}
	switch kind {
	case .Prompt:
		p.prompt, cloned = payload_clone(payload_string(root, "prompt"), allocator)
		if !cloned {return p, false}
	case .Stop:
	case .Edit:
		raw := make([dynamic]string, 0, 4, context.temp_allocator)
		input := root["tool_input"]
		if tool_input, has_input := input.(json.Object); has_input {
			switch harness {
			case .Claude:
				for key in ([?]string{"file_path", "notebook_path"}) {
					if path := payload_string(tool_input, key); path != "" {append(&raw, path)}
				}
			case .Codex:
				patch_paths(payload_string(tool_input, "command"), &raw)
			case .None, .Omp:
			}
		}
		paths := make([dynamic]string, 0, len(raw), allocator)
		for path in raw {
			absolute, made := absolute_path(cwd, path, allocator)
			if !made {
				for kept in paths {delete(kept, allocator)}
				delete(paths)
				return p, false
			}
			if path_listed(paths[:], absolute) {
				delete(absolute, allocator)
				continue
			}
			append(&paths, absolute)
		}
		p.paths = paths[:]
	}
	return p, true
}

turn_payload_destroy :: proc(p: ^Turn_Payload, allocator := context.allocator) {
	delete(p.session, allocator)
	delete(p.cwd, allocator)
	delete(p.prompt, allocator)
	for path in p.paths {delete(path, allocator)}
	delete(p.paths, allocator)
	p^ = {}
}

@(private)
payload_string :: proc(object: json.Object, key: string) -> string {
	text, _ := object[key].(json.String)
	return string(text)
}

@(private)
payload_clone :: proc(text: string, allocator: runtime.Allocator) -> (string, bool) {
	result, err := strings.clone(text, allocator)
	return result, err == nil
}

@(private)
path_listed :: proc(paths: []string, path: string) -> bool {
	for listed in paths {
		if listed == path {return true}
	}
	return false
}

// Every path an apply_patch patch names, borrowed from `patch`. Only lines that start at column 0 count,
// since the lines of added content start with '+'.
@(private)
patch_paths :: proc(patch: string, out: ^[dynamic]string) {
	rest := patch
	for line in strings.split_lines_iterator(&rest) {
		for prefix in PATCH_PREFIXES {
			if !strings.has_prefix(line, prefix) {continue}
			if path := strings.trim_space(line[len(prefix):]); path != "" {append(out, path)}
			break
		}
	}
}

// `path` made absolute against `cwd`, with '/' separators and no "." or ".." segments. A relative path
// stays relative when there is no cwd to join it to.
@(private)
absolute_path :: proc(cwd, path: string, allocator := context.allocator) -> (string, bool) {
	joined := path_slashed(path, context.temp_allocator)
	if !path_rooted(joined) && cwd != "" {
		base := strings.trim_right(path_slashed(cwd, context.temp_allocator), "/")
		joined = strings.concatenate({base, "/", joined}, context.temp_allocator)
	}
	root := ""
	rest := joined
	switch {
	case len(joined) >= 2 && joined[1] == ':' && path_rooted(joined):
		root, rest = joined[:2], joined[2:]
		if strings.has_prefix(rest, "/") {root = joined[:3]; rest = rest[1:]}
	case strings.has_prefix(joined, "//"):
		root, rest = joined[:2], joined[2:]
	case strings.has_prefix(joined, "/"):
		root, rest = joined[:1], joined[1:]
	}
	segments := make([dynamic]string, 0, 8, context.temp_allocator)
	for segment in strings.split_iterator(&rest, "/") {
		switch segment {
		case "", ".":
		case "..":
			if len(segments) > 0 {pop(&segments)}
		case:
			append(&segments, segment)
		}
	}
	tail := strings.join(segments[:], "/", context.temp_allocator)
	result, err := strings.concatenate({root, tail}, allocator)
	return result, err == nil
}

@(private)
path_slashed :: proc(path: string, allocator := context.allocator) -> string {
	result, _ := strings.replace_all(path, `\`, "/", allocator)
	return result
}

@(private)
path_rooted :: proc(path: string) -> bool {
	if strings.has_prefix(path, "/") {return true}
	if len(path) < 2 || path[1] != ':' {return false}
	c := path[0]
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}
