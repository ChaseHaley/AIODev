package turns

import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

// What `aio turn-hook` hands the app. The files travel through a directory because the control pipe is
// off by default: the hook writes one event file per hook run, the app reads and deletes it, and the
// hook waits for the deletion so the app has seen the edit before the harness runs the tool.

Hook_Kind :: enum u8 {
	Prompt,
	Stop,
	Edit,
}

Hook_Event :: struct {
	pane_key, harness, session, cwd, prompt: string,
	kind:                                    Hook_Kind,
	// Absolute, '/' separated; only an Edit names any.
	paths:                                   []string,
	// Unix milliseconds, when the hook ran.
	written:                                 i64,
}

// A hook event file larger than this is not one.
HOOK_EVENT_LIMIT :: 64 * 1024
// Under the turns directory: one file per hook run, named <pane key>-<20-digit ns>.json.
INBOX_DIRECTORY :: "inbox"
// Under the turns directory while the app records; names the app process.
RECORDING_MARKER :: "recording.json"
// The variable AIODev gives every pane naming the turns directory; hooks find the inbox through it.
TURNS_VARIABLE :: "AIODEV_TURNS"

// The prompt is a title for the turn, not a copy of it.
HOOK_PROMPT_LIMIT :: 200

@(private)
HOOK_FIELD_LIMIT :: 4096
@(private)
HOOK_PATH_LIMIT :: 4096
@(private)
HOOK_KEY_LENGTH :: 32

@(private, rodata)
HOOK_KIND_NAMES := [Hook_Kind]string {
	.Prompt = "prompt",
	.Stop   = "stop",
	.Edit   = "edit",
}

// The wire shape; the kind is a word so the files stay readable.
@(private)
Hook_Wire :: struct {
	pane_key: string,
	harness:  string,
	session:  string,
	cwd:      string,
	prompt:   string,
	kind:     string,
	paths:    []string,
	written:  i64,
}

@(private)
Marker_Wire :: struct {
	pid: u32,
}

// The prompt cut to HOOK_PROMPT_LIMIT bytes at a rune boundary.
hook_prompt_clip :: proc(prompt: string) -> string {
	if len(prompt) <= HOOK_PROMPT_LIMIT {return prompt}
	cut := HOOK_PROMPT_LIMIT
	for cut > 0 && !utf8.rune_start(prompt[cut]) {cut -= 1}
	return prompt[:cut]
}

@(private)
hook_harness_valid :: proc(harness: string) -> bool {
	return harness == "claude" || harness == "codex" || harness == "agy"
}

@(private)
hook_key_valid :: proc(key: string) -> bool {
	if len(key) != HOOK_KEY_LENGTH {return false}
	for c in transmute([]u8)key {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {return false}
	}
	return true
}

// The event as JSON text in `allocator`; false when it is invalid or would not fit HOOK_EVENT_LIMIT.
@(require_results)
hook_event_encode :: proc(e: Hook_Event, allocator := context.allocator) -> (string, bool) {
	if !hook_key_valid(e.pane_key) || !hook_harness_valid(e.harness) {return "", false}
	if int(e.kind) >= len(HOOK_KIND_NAMES) {return "", false}
	wire := Hook_Wire {
		pane_key = e.pane_key,
		harness  = e.harness,
		session  = e.session,
		cwd      = e.cwd,
		prompt   = hook_prompt_clip(e.prompt),
		kind     = HOOK_KIND_NAMES[e.kind],
		paths    = e.paths,
		written  = e.written,
	}
	data, err := json.marshal(wire, {}, allocator)
	if err != nil {return "", false}
	if len(data) > HOOK_EVENT_LIMIT {
		delete(data, allocator)
		return "", false
	}
	return string(data), true
}

// Validates the pane key (32 lowercase hex digits), the harness, the kind and every size, and keeps
// the prompt to HOOK_PROMPT_LIMIT bytes. Strings are copied into `allocator`.
@(require_results)
hook_event_decode :: proc(data: []u8, allocator := context.allocator) -> (e: Hook_Event, ok: bool) {
	if len(data) > HOOK_EVENT_LIMIT {return e, false}
	value, parse_error := json.parse(data, .JSON, true, context.temp_allocator)
	if parse_error != .None {return e, false}
	root, is_object := value.(json.Object)
	if !is_object {return e, false}
	defer if !ok {hook_event_destroy(&e, allocator)}

	pane_key, key_ok := hook_field(root, "pane_key", HOOK_KEY_LENGTH)
	if !key_ok || !hook_key_valid(pane_key) {return e, false}
	harness, harness_ok := hook_field(root, "harness", HOOK_FIELD_LIMIT)
	if !harness_ok || !hook_harness_valid(harness) {return e, false}
	kind_name, kind_ok := hook_field(root, "kind", HOOK_FIELD_LIMIT)
	if !kind_ok {return e, false}
	kind_found := false
	for name, kind in HOOK_KIND_NAMES {
		if name == kind_name {e.kind, kind_found = kind, true}
	}
	if !kind_found {return e, false}
	session, session_ok := hook_field(root, "session", HOOK_FIELD_LIMIT)
	cwd, cwd_ok := hook_field(root, "cwd", HOOK_FIELD_LIMIT)
	prompt, prompt_ok := hook_field(root, "prompt", HOOK_EVENT_LIMIT)
	if !session_ok || !cwd_ok || !prompt_ok {return e, false}
	if written, has_written := root["written"]; has_written {
		number, is_integer := written.(json.Integer)
		if !is_integer {return e, false}
		e.written = i64(number)
	}
	paths_count := 0
	paths: json.Array
	if paths_value, has_paths := root["paths"]; has_paths {
		is_array: bool
		paths, is_array = paths_value.(json.Array)
		if !is_array {return e, false}
		paths_count = len(paths)
	}
	for path_value in paths {
		path, is_string := path_value.(json.String)
		if !is_string || len(path) > HOOK_PATH_LIMIT {return e, false}
	}

	cloned: bool
	e.pane_key, cloned = hook_clone(pane_key, allocator)
	if !cloned {return e, false}
	e.harness, cloned = hook_clone(harness, allocator)
	if !cloned {return e, false}
	e.session, cloned = hook_clone(session, allocator)
	if !cloned {return e, false}
	e.cwd, cloned = hook_clone(cwd, allocator)
	if !cloned {return e, false}
	e.prompt, cloned = hook_clone(hook_prompt_clip(prompt), allocator)
	if !cloned {return e, false}
	if paths_count > 0 {
		list, list_error := make([]string, paths_count, allocator)
		if list_error != nil {return e, false}
		e.paths = list
		for path_value, i in paths {
			e.paths[i], cloned = hook_clone(string(path_value.(json.String)), allocator)
			if !cloned {return e, false}
		}
	}
	return e, true
}

@(private)
hook_field :: proc(root: json.Object, name: string, limit: int) -> (string, bool) {
	value, found := root[name]
	if !found {return "", true}
	text, is_string := value.(json.String)
	if !is_string || len(text) > limit {return "", false}
	return string(text), true
}

@(private)
hook_clone :: proc(text: string, allocator := context.allocator) -> (string, bool) {
	text_copy, err := strings.clone(text, allocator)
	return text_copy, err == nil
}

// Frees what hook_event_decode allocated; accepts a partly built event.
hook_event_destroy :: proc(e: ^Hook_Event, allocator := context.allocator) {
	delete(e.pane_key, allocator)
	delete(e.harness, allocator)
	delete(e.session, allocator)
	delete(e.cwd, allocator)
	delete(e.prompt, allocator)
	for path in e.paths {delete(path, allocator)}
	delete(e.paths, allocator)
	e^ = {}
}

// The recording marker's text, `{"pid":<n>}`, in `allocator`.
@(require_results)
marker_encode :: proc(pid: u32, allocator := context.allocator) -> string {
	data, err := json.marshal(Marker_Wire{pid}, {}, allocator)
	return err == nil ? string(data) : ""
}

// The app's pid from a recording marker; not ok for anything else, or a pid of 0.
@(require_results)
marker_decode :: proc(data: []u8) -> (pid: u32, ok: bool) {
	if len(data) == 0 || len(data) > 1024 {return 0, false}
	value, parse_error := json.parse(data, .JSON, true, context.temp_allocator)
	if parse_error != .None {return 0, false}
	root, is_object := value.(json.Object)
	if !is_object {return 0, false}
	number, is_integer := root["pid"].(json.Integer)
	if !is_integer || number <= 0 || number > i64(max(u32)) {return 0, false}
	return u32(number), true
}
