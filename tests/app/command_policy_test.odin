package app_test

import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:term"
import "aio:ui"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:testing"

@(test)
command_categories_cover_every_action_namespace :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	if !testing.expect_value(t, app.register_actions(&registry), commands.Error.None) {return}
	for command in registry.items {
		category := commands.category(command.name)
		testing.expectf(t, category.title != "Commands", "uncategorized action: %s", command.name)
		if strings.has_prefix(command.name, "status.") {
			testing.expect_value(t, category.title, "Status")
		}
		if strings.has_prefix(command.name, "profile.") {
			testing.expect_value(t, category.title, "Profiles")
		}
	}
}

@(test)
command_payloads_select_catalogue_usage_and_empty_panes :: proc(t: ^testing.T) {
	state := app.App{registry = commands.create()}
	defer commands.destroy(&state.registry)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	list := commands.invocation(commands.Command_Id(app.Action.Pane_List), focus = false)
	panes := app.command_execute(&state, app.Control_Request{}, list)
	_, is_panes := panes.payload.(app.Outcome_Panes)
	testing.expect(t, is_panes)
	catalogue := commands.invocation(commands.Command_Id(app.Action.App_Commands), focus = false)
	all := app.command_execute(&state, app.Control_Request{}, catalogue)
	_, is_catalogue := all.payload.(app.Outcome_Catalogue)
	testing.expect(t, is_catalogue)
	catalogue.text = "pane.send"
	one := app.command_execute(&state, app.Control_Request{}, catalogue)
	usage, is_usage := one.payload.(app.Outcome_Usage)
	if !testing.expect(t, is_usage) {return}
	reply := app.control_cli_answer(&state, {"", "text", cli_protocol.CATALOGUE_COMMAND, "pane.send"})
	testing.expect_value(t, reply.text, fmt.tprintf("%s\n%s", usage.usage, usage.title))
	expected := cli_protocol.Reply_Json {
		ok = true,
		commands = []cli_protocol.Command_Report{cli_protocol.Command_Report(usage)},
	}
	encoded, err := json.marshal(expected, {}, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	json_reply := app.control_cli_answer(&state, {"", "json", cli_protocol.CATALOGUE_COMMAND, "pane.send"})
	testing.expect_value(t, json_reply.text, string(encoded))
}

@(test)
copy_availability_follows_terminal_selection_or_find_keyboard :: proc(t: ^testing.T) {
	f: Terminal_Copy_Fixture
	defer terminal_copy_fixture_destroy(&f)
	if !terminal_copy_fixture(t, &f) {return}
	testing.expect(t, !app.action_available(&f.state, &f.window, .Copy))
	testing.expect(t, app.action_available(&f.state, &f.window, .Paste))
	term.select_all(f.session)
	testing.expect(t, app.action_available(&f.state, &f.window, .Copy))
	term.clear_selection(f.session)
	ui.find_open(&f.window.find)
	testing.expect(t, app.action_available(&f.state, &f.window, .Copy))
}
