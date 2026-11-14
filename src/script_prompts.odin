package main

import "aio:commands"
import "aio:events"
import "aio:ui"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

// A window has at most one script question. The UI owns the displayed strings through its close.
Script_Prompt :: struct {
	id: u64,
	selection: bool,
}

@(private, require_results)
script_prompt_window :: proc(app: ^App, ctx: Command_Context, invocation: commands.Invocation) -> ^Window {
	switch caller in ctx {
	case Window_Context:
		return caller.window
	case Control_Request:
		if caller.caller != 0 || invocation.pane != "" {
			target, failure := pane_target_resolve(app, invocation.pane, caller.caller)
			if failure.status == .Ok {
				if linked := pane_link_window_of(app, target.pane.content); linked != nil {return linked}
				if shown := window_for_workspace(app, target.workspace); shown != nil {return shown}
			}
		}
	}
	return window_focused_or_primary(app)
}

// Parsed strings live on the current command's temporary allocator; the UI copies what it keeps.
@(private, require_results)
script_prompt_strings :: proc(text: string) -> ([]string, bool) {
	if !utf8.valid_string(text) {return nil, false}
	context.allocator = context.temp_allocator
	parser := json.make_parser_from_string(text, .JSON)
	value, err := json.parse_value(&parser)
	array, is_array := value.(json.Array)
	if err != .None || !is_array || parser.curr_token.kind != .EOF {return nil, false}
	result, allocation_error := make([]string, len(array), context.temp_allocator)
	if allocation_error != nil {return nil, false}
	for element, index in array {
		item, is_string := element.(json.String)
		if !is_string {return nil, false}
		result[index] = item
	}
	return result, true
}

@(require_results)
script_prompt_select :: proc(app: ^App, ctx: Command_Context, invocation: commands.Invocation) -> Outcome {
	items, valid := script_prompt_strings(invocation.items)
	if !valid {return outcome_failure(.Usage, "--items must be a JSON array of strings")}
	details: []string
	if .Details in invocation.given {
		parsed, ok := script_prompt_strings(invocation.details)
		if !ok || len(parsed) != len(items) {
			return outcome_failure(.Usage, "--details must be a JSON array with one string per item")
		}
		details = parsed
	}
	w := script_prompt_window(app, ctx, invocation)
	if w == nil {return outcome_failure(.Failed, "no window is open")}
	allocator := app.palette.results.allocator
	owned, allocation_error := make([]ui.Palette_Item, len(items), allocator)
	if allocation_error != nil {return outcome_failure(.Failed, "not enough memory for the prompt")}
	transferred := false
	defer if !transferred {
		for item in owned {delete(item.label, allocator); delete(item.detail, allocator)}
		delete(owned, allocator)
	}
	for item, index in items {
		label, err := strings.clone(item, allocator)
		if err != nil {return outcome_failure(.Failed, "not enough memory for the prompt")}
		owned[index].label = label
		if len(details) != 0 {
			detail, detail_error := strings.clone(details[index], allocator)
			if detail_error != nil {return outcome_failure(.Failed, "not enough memory for the prompt")}
			owned[index].detail = detail
		}
	}
	title, title_error := strings.clone(invocation.title, allocator)
	if title_error != nil {return outcome_failure(.Failed, "not enough memory for the prompt")}
	defer if !transferred {delete(title, allocator)}
	if !palette_open_list(app, w, title, owned) {
		return outcome_failure(.Failed, "the window is busy with a drag")
	}
	transferred = true
	app.next_prompt_id += 1
	w.script_prompt = {id = app.next_prompt_id, selection = true}
	w.dirty = true
	return {payload = Outcome_Prompt{w.script_prompt.id}}
}

@(require_results)
script_prompt_input :: proc(app: ^App, ctx: Command_Context, invocation: commands.Invocation) -> Outcome {
	w := script_prompt_window(app, ctx, invocation)
	if w == nil {return outcome_failure(.Failed, "no window is open")}
	if !utf8.valid_string(invocation.text) || strings.contains_any(invocation.text, "\r\n") {
		return outcome_failure(.Usage, "the default must be one line of UTF-8 text")
	}
	title, err := strings.clone(invocation.title)
	if err != nil {return outcome_failure(.Failed, "not enough memory for the prompt")}
	if !gesture_cancel(app, w) {
		delete(title)
		return outcome_failure(.Failed, "the window is busy with a drag")
	}
	// Reserve before replacing the current prompt, so allocation failure leaves the question intact.
	if reserve(&w.rename.bytes, len(invocation.text)) != nil {
		delete(title)
		return outcome_failure(.Failed, "not enough memory for the prompt")
	}
	overlay_open(app, w, Overlay_Input{title})
	ui.field_set(&w.rename, invocation.text)
	ui.field_select_all(&w.rename)
	app.next_prompt_id += 1
	w.script_prompt = {id = app.next_prompt_id}
	w.dirty = true
	return {payload = Outcome_Prompt{w.script_prompt.id}}
}

script_prompt_cancel :: proc(app: ^App, w: ^Window) {
	if w.script_prompt.id == 0 {return}
	fields := Event_Prompt_Closed{prompt = w.script_prompt.id, cancelled = true}
	events.push(&app.events, .Prompt_Closed, fields)
	w.script_prompt = {}
}

script_prompt_accept_index :: proc(app: ^App, w: ^Window, index: int) {
	if w.script_prompt.id == 0 || !w.script_prompt.selection {return}
	fields := Event_Prompt_Closed{prompt = w.script_prompt.id, index = index}
	events.push(&app.events, .Prompt_Closed, fields)
	w.script_prompt = {}
}

script_prompt_accept_text :: proc(app: ^App, w: ^Window, text: string) {
	if w.script_prompt.id == 0 || w.script_prompt.selection {return}
	fields := Event_Prompt_Closed{prompt = w.script_prompt.id, text = text}
	events.push(&app.events, .Prompt_Closed, fields)
	w.script_prompt = {}
}
