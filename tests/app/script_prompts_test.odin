package app_test

import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:events"
import "aio:input"
import "aio:ui"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:testing"

@(private = "file")
Prompt_Answer :: struct {
	prompt: u64,
	cancelled: bool,
	index: int,
	text: string,
}

@(private = "file")
invoke :: proc(state: ^app.App, caller: u32, args: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	request := app.Control_Request{caller = caller}
	return app.command_execute(state, request, invocation)
}

@(private = "file", require_results)
prompt_test_init :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window) -> bool {
	state.registry = commands.create()
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return false}
	if !testing.expect_value(t, ui.palette_init(&state.palette, nil), nil) {return false}
	events.init(&state.events)
	interest := events.Kinds{.Prompt_Closed}
	events.set_interest(&state.events, .Lua, interest)
	w^ = {id = 1, phase = .Shown, focused = true, width = 900, height = 700, scale = 1}
	app.overlay_surfaces_init(&w.surfaces)
	append(&state.windows, w)
	return true
}

@(private = "file")
prompt_test_destroy :: proc(state: ^app.App, w: ^app.Window) {
	app.window_overlays_cancel(state, w)
	app.overlay_surfaces_destroy(w)
	ui.palette_destroy(&state.palette)
	commands.destroy(&state.registry)
	events.destroy(&state.events)
	delete(state.windows)
}

@(private = "file")
prompt_test_key :: proc(state: ^app.App, w: ^app.Window, key: input.Key) {
	press := input.Key_Event{window = w.id, key = key, pressed = true}
	app.handle_event(state, press)
	release := input.Key_Event{window = w.id, key = key}
	app.handle_event(state, release)
}

@(private = "file", require_results)
prompt_test_answer :: proc(t: ^testing.T, state: ^app.App) -> Prompt_Answer {
	pending := events.pending(&state.events)
	if !testing.expect_value(t, len(pending), 1) {return {}}
	if !testing.expect_value(t, pending[0].kind, events.Kind.Prompt_Closed) {return {}}
	answer: Prompt_Answer
	if !testing.expect_value(t, json.unmarshal_string(pending[0].fields, &answer,
		allocator = context.temp_allocator), nil) {return {}}
	if answer.cancelled {
		testing.expect(t, !strings.contains(pending[0].fields, `"index"`))
		testing.expect(t, !strings.contains(pending[0].fields, `"text"`))
	}
	events.clear(&state.events)
	return answer
}

@(test)
script_select_filters_and_reports_original_index_or_cancellation :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer prompt_test_destroy(&state, &w)
	if !prompt_test_init(t, &state, &w) {return}
	selected := invoke(&state, 0, "app.select", "--title", "Choose a task", "--items",
		`["unrelated","build task","build task"]`, "--details", `["Other","Compile A","Compile B"]`)
	if !testing.expect_value(t, selected.status, cli_protocol.Status.Ok) {return}
	id := selected.payload.(app.Outcome_Prompt).prompt
	testing.expect(t, id != 0 && app.palette_active(&state, &w))
	testing.expect_value(t, state.palette.list_title, "Choose a task")
	testing.expect_value(t, len(state.palette.results), 3)
	testing.expect_value(t, state.palette.list_items[2].detail, "Compile B")
	geometry := ui.palette_layout(&state.palette, 900, 700, 1)
	testing.expect_value(t, geometry.mode_bar.height, f32(0))
	testing.expect_value(t, geometry.keys.width, f32(0))
	typed := input.Text_Event{window = w.id, text = "build"}
	app.handle_event(&state, typed)
	if !testing.expect_value(t, len(state.palette.results), 2) {return}
	prompt_test_key(&state, &w, .Arrow_Down)
	original := state.palette.results[state.palette.selected].source + 1
	testing.expect_value(t, original, 3)
	prompt_test_key(&state, &w, .Enter)
	answer := prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, id)
	testing.expect(t, !answer.cancelled)
	testing.expect_value(t, answer.index, original)
	testing.expect(t, !app.palette_active(&state, &w))
	// The strings must survive the closing fade, not merely the command's temporary storage.
	testing.expect_value(t, state.palette.list_items[2].label, "build task")
	cancelled := invoke(&state, 0, "app.select", "--title", "Cancel", "--items", `["one"]`)
	prompt_test_key(&state, &w, .Escape)
	answer = prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, cancelled.payload.(app.Outcome_Prompt).prompt)
	testing.expect(t, answer.cancelled)
	_ = invoke(&state, 0, "app.select", "--title", "Click away", "--items", `["one"]`)
	click := input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true}
	app.handle_event(&state, click)
	click.pressed = false
	app.handle_event(&state, click)
	answer = prompt_test_answer(t, &state)
	testing.expect(t, answer.cancelled)
	_ = invoke(&state, 0, "app.select", "--title", "Closing window", "--items", `[]`)
	app.window_overlays_cancel(&state, &w)
	answer = prompt_test_answer(t, &state)
	testing.expect(t, answer.cancelled)
}

@(test)
script_input_edits_selected_default_and_replacement_cancels_first :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer prompt_test_destroy(&state, &w)
	if !prompt_test_init(t, &state, &w) {return}
	first := invoke(&state, 0, "app.select", "--title", "Old", "--items", `["one"]`)
	second := invoke(&state, 0, "app.input", "--title", "Your name", "default")
	if !testing.expect_value(t, second.status, cli_protocol.Status.Ok) {return}
	answer := prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, first.payload.(app.Outcome_Prompt).prompt)
	testing.expect(t, answer.cancelled)
	testing.expect_value(t, w.overlay.(app.Overlay_Input).title, "Your name")
	testing.expect_value(t, ui.field_selected_text(&w.rename), "default")
	edited := input.Text_Event{window = w.id, text = "edited"}
	app.handle_event(&state, edited)
	prompt_test_key(&state, &w, .Enter)
	answer = prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, second.payload.(app.Outcome_Prompt).prompt)
	testing.expect_value(t, answer.text, "edited")
	testing.expect(t, !answer.cancelled && w.overlay == nil)
	_ = invoke(&state, 0, "app.input", "--title", "Empty is valid", "selected")
	prompt_test_key(&state, &w, .Backspace)
	prompt_test_key(&state, &w, .Enter)
	answer = prompt_test_answer(t, &state)
	testing.expect(t, !answer.cancelled)
	testing.expect_value(t, answer.text, "")
	_ = invoke(&state, 0, "app.input", "--title", "Escape")
	prompt_test_key(&state, &w, .Escape)
	answer = prompt_test_answer(t, &state)
	testing.expect(t, answer.cancelled)
	old_input := invoke(&state, 0, "app.input", "--title", "Replace me")
	new_select := invoke(&state, 0, "app.select", "--title", "New", "--items", `["one"]`)
	answer = prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, old_input.payload.(app.Outcome_Prompt).prompt)
	testing.expect(t, answer.cancelled)
	old_id := old_input.payload.(app.Outcome_Prompt).prompt
	testing.expect(t, new_select.payload.(app.Outcome_Prompt).prompt > old_id)
	_ = invoke(&state, 0, "app.select", "--title", "Newest", "--items", `["two"]`)
	answer = prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, new_select.payload.(app.Outcome_Prompt).prompt)
	testing.expect(t, answer.cancelled)
}

@(test)
script_prompt_replies_and_invalid_lists_preserve_the_open_question :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer prompt_test_destroy(&state, &w)
	if !prompt_test_init(t, &state, &w) {return}
	select_args := []string{"", "json", "", "app.select", "--title", "Pick", "--items", `["one"]`}
	response := app.control_cli_answer(&state, select_args)
	if !testing.expect(t, response.ok) {return}
	reply: cli_protocol.Reply_Json
	if !testing.expect_value(t, json.unmarshal_string(response.text, &reply,
		allocator = context.temp_allocator), nil) {return}
	testing.expect(t, reply.prompt != 0)
	testing.expect_value(t, reply.prompt, w.script_prompt.id)
	bad_lists := []string{`null`, `[1]`, `["one"] trailing`, `{}`}
	for bad in bad_lists {
		failure := invoke(&state, 0, "app.select", "--title", "Bad", "--items", bad)
		testing.expect_value(t, failure.status, cli_protocol.Status.Usage)
		testing.expect_value(t, w.script_prompt.id, reply.prompt)
	}
	failure := invoke(&state, 0, "app.select", "--title", "Bad details", "--items", `["one"]`, "--details", `[]`)
	testing.expect_value(t, failure.status, cli_protocol.Status.Usage)
	testing.expect_value(t, len(events.pending(&state.events)), 0)
	input_args := []string{"", "text", "", "app.input", "--title", "Text"}
	plain := app.control_cli_answer(&state, input_args)
	testing.expect(t, plain.ok)
	id, parsed := strconv.parse_u64(plain.text)
	testing.expect(t, parsed && id > reply.prompt)
	testing.expect_value(t, id, w.script_prompt.id)
	answer := prompt_test_answer(t, &state)
	testing.expect_value(t, answer.prompt, reply.prompt)
	testing.expect(t, answer.cancelled)
}
