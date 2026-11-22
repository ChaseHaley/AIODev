package app_test

import "aio:cli_protocol"
import "aio:commands"
import "cosmos:input"
import "aio:platform"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"

@(private = "file")
web_open :: proc(state: ^app.App, args: ..string) -> app.Outcome {
	line := make([dynamic]string, context.temp_allocator)
	append(&line, "pane.open_web")
	append(&line, ..args)
	invocation, err := commands.parse_invocation(&state.registry, line[:], context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Control_Request{caller = state.sessions[0].id, origin = .Cli}, invocation)
}

@(test)
open_web_command_opens_a_normalized_pane_and_refuses_other_schemes :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-web-open-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove_all(directory)
	settings := idle_shell_settings(t, "cursor.blink = false\n")
	if !testing.expect_value(t, os.write_entire_file(strings.concatenate({directory, "/settings.ini"}, context.temp_allocator), settings), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.WebOpen.%d", os.get_pid())
	defer app.app_destroy(&state)
	app.layout_state_enable(&state, strings.concatenate({directory, "/layout.json"}))
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]

	testing.expect_value(t, web_open(&state, "example.com").status, cli_protocol.Status.Ok)
	if !testing.expect_value(t, len(state.web_panes), 1) {return}
	pane := state.web_panes[0]
	testing.expect_value(t, pane.url, "https://example.com")
	testing.expect(t, app.workspace_has_content(w.workspace, {.Web, pane.id}))

	testing.expect_value(t, web_open(&state, "--direction", "down", "localhost:3000").status, cli_protocol.Status.Ok)
	if !testing.expect_value(t, len(state.web_panes), 2) {return}
	testing.expect_value(t, state.web_panes[1].url, "http://localhost:3000")

	refused := web_open(&state, "file://server/share/report.html")
	testing.expect_value(t, refused.status, cli_protocol.Status.Usage)
	testing.expect(t, strings.contains(refused.message, "local file:///"))
	testing.expect_value(t, len(state.web_panes), 2)

	state.settings.pane.web_navigator = false
	testing.expect_value(t, web_open(&state, "--focus").status, cli_protocol.Status.Ok)
	if !testing.expect_value(t, len(state.web_panes), 3) {return}
	app.handle_event(&state, input.Key_Event{window = w.id, key = .E, text = "e", pressed = true})
	app.handle_event(&state, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, state.web_panes[2].url, "https://e")
}
