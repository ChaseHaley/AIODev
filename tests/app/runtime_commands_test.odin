package app_test

import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "cosmos:input"
import "aio:layout"
import "aio:settings"
import "aio:ui"
import "core:encoding/json"
import "core:strings"
import "core:testing"

@(private = "file")
runtime_bridge_seen: struct {
	calls: int,
	origin: app.Command_Origin,
	fields: string,
}

@(private = "file")
runtime_bridge_runner :: proc(_: ^app.App, ctx: app.Command_Context, invocation: commands.Invocation) -> app.Outcome {
	runtime_bridge_seen.calls += 1
	runtime_bridge_seen.fields = invocation.fields
	switch caller in ctx {
	case app.Window_Context:
		runtime_bridge_seen.origin = caller.origin
	case app.Control_Request:
		runtime_bridge_seen.origin = caller.origin
	}
	if invocation.fields == `{"raw":true}` {
		return {payload = app.Outcome_Json("123456789012345678901234567890")}
	}
	return {payload = app.Outcome_Json(`{"answer":42,"nested":[true,"ok"]}`)}
}

@(test)
runtime_commands_share_fields_origins_bindings_and_catalogue :: proc(t: ^testing.T) {
	state := app.App{registry = commands.create(), runtime_runner = runtime_bridge_runner}
	defer commands.destroy(&state.registry)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	id, register_error := commands.register_runtime(&state.registry, {name = "build", title = "Build project",
		category = "Project", keywords = "compile", source = "init.lua:12"}, app.RUNTIME_COMMAND_FIRST)
	if !testing.expect_value(t, register_error, commands.Error.None) {return}
	runtime_bridge_seen = {}
	fields :: `{"target":"all","options":{"clean":true}}`
	response := app.command_run_fields(&state, app.Control_Request{origin = .Cli}, "build", fields, "")
	testing.expect(t, response.ok, response.text)
	testing.expect_value(t, runtime_bridge_seen.fields, fields)
	testing.expect_value(t, runtime_bridge_seen.origin, app.Command_Origin.Cli)
	reply: cli_protocol.Reply_Json
	if !testing.expect_value(t, json.unmarshal_string(response.text, &reply, allocator = context.temp_allocator), nil) {return}
	result, result_ok := reply.result.(json.Object)
	if testing.expect(t, result_ok, "result is a JSON object, not quoted JSON") {
		testing.expect_value(t, result["answer"].(json.Integer), json.Integer(42))
	}
	for word, origin in app.COMMAND_ORIGIN_WORDS {
		response = app.control_cli_answer(&state, {"", "json", "", "build", cli_protocol.FIELDS_OPTION, fields, cli_protocol.ORIGIN_OPTION, word})
		testing.expect(t, response.ok, response.text)
		testing.expect_value(t, runtime_bridge_seen.origin, origin)
	}
	plain := app.control_cli_answer(&state, {"", "text", "", "build", cli_protocol.FIELDS_OPTION, "{}"})
	testing.expect_value(t, plain.text, `{"answer":42,"nested":[true,"ok"]}`)
	response = app.command_run_fields(&state, app.Control_Request{}, "app.commands", "{}", "")
	testing.expect(t, strings.contains(response.text, `"name":"build"`))
	help := app.control_cli_answer(&state, {"", "text", "", "app.commands", "build"})
	raw := app.command_run_fields(&state, app.Control_Request{}, "build", `{"raw":true}`, "")
	testing.expect(t, strings.contains(raw.text, `"result":123456789012345678901234567890`), raw.text)
	for malformed in ([][]string{
		{"", "json", "", "build", cli_protocol.FIELDS_OPTION},
		{"", "json", "", "build", cli_protocol.FIELDS_OPTION, "{}", cli_protocol.ORIGIN_OPTION, "bogus"},
		{"", "json", "", "build", cli_protocol.FIELDS_OPTION, "{}", "--wrong", "script"},
	}) {
		rejected := app.control_cli_answer(&state, malformed)
		testing.expect_value(t, rejected.status, u8(cli_protocol.Status.Usage))
	}
	testing.expect(t, help.ok && strings.contains(help.text, "Build project"), help.text)

	parsed, diagnostics, parse_error := settings.parse("keys.build = Ctrl+Alt+B\n")
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, parse_error, nil) {return}
	defer settings.destroy(&parsed)
	report, report_error := app.binding_report(&state.registry, &parsed)
	testing.expect_value(t, report_error, nil)
	testing.expect_value(t, len(report.issues), 0)
	bound := commands.find_by_key(&state.registry, .B, {.Control, .Alt}, 'b')
	if !testing.expect(t, bound != nil) {return}
	testing.expect_value(t, bound.id, id)
	// A real key event on a settings pane needs no terminal process or platform window.
	tab: app.Tab
	if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {return}
	defer layout.destroy(&tab.tree)
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{id = 1, workspace = &workspace, phase = .Shown, width = 800, height = 600, scale = 1}
	defer ui.editor_destroy(&w.editor)
	append(&state.windows, &w)
	defer delete(state.windows)
	before := runtime_bridge_seen.calls
	app.handle_event(&state, input.Key_Event{window = w.id, key = .B, unshifted = 'b', modifiers = {.Control, .Alt}, pressed = true})
	testing.expect_value(t, runtime_bridge_seen.calls, before + 1)
	testing.expect_value(t, runtime_bridge_seen.origin, app.Command_Origin.Key)

	state.runtime_runner = nil
	missing_runner := app.command_run_fields(&state, app.Control_Request{}, "build", "{}", "")
	testing.expect(t, !missing_runner.ok && strings.contains(missing_runner.text, "no script defines build"))
	commands.unregister_runtime(&state.registry)
	testing.expect(t, commands.find(&state.registry, "build") == nil)
	report, report_error = app.binding_report(&state.registry, &parsed)
	testing.expect_value(t, report_error, nil)
	if testing.expect_value(t, len(report.issues), 1) {
		testing.expect_value(t, report.issues[0].kind, app.Binding_Issue_Kind.Unknown_Command)
		testing.expect_value(t, report.issues[0].line, 1)
	}
	response = app.command_run_fields(&state, app.Control_Request{}, "build", "{}", "")
	testing.expect(t, !response.ok && strings.contains(response.text, "unknown command"))
	response = app.command_run_fields(&state, app.Control_Request{}, "app.commands", "{}", "")
	testing.expect(t, !strings.contains(response.text, `"name":"build"`))
}

@(test)
runtime_binding_conflicts_report_runtime_source_lines :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	if !testing.expect_value(t, app.register_actions(&registry), commands.Error.None) {return}
	for name in ([?]string{"build", "deploy"}) {
		_, err := commands.register_runtime(&registry, {name = name, title = name}, app.RUNTIME_COMMAND_FIRST)
		if !testing.expect_value(t, err, commands.Error.None) {return}
	}
	s, diagnostics, parse_error := settings.parse("keys.build = Ctrl+Alt+B\nkeys.deploy = Ctrl+Alt+B\n")
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, parse_error, nil) {return}
	defer settings.destroy(&s)
	report, report_error := app.binding_report(&registry, &s)
	testing.expect_value(t, report_error, nil)
	if !testing.expect_value(t, len(report.issues), 1) {return}
	issue := report.issues[0]
	testing.expect_value(t, issue.kind, app.Binding_Issue_Kind.Duplicate_Shortcut)
	testing.expect_value(t, issue.conflict.winner.name, "build")
	testing.expect_value(t, issue.conflict.winner.line, 1)
	testing.expect_value(t, issue.conflict.loser.name, "deploy")
	testing.expect_value(t, issue.conflict.loser.line, 2)
}
