package app_test

import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:input"
import "aio:settings"
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
	reply := app.control_cli_answer(&state, {"", "text", "", cli_protocol.CATALOGUE_COMMAND, "pane.send"})
	testing.expect(t, strings.has_prefix(reply.text, fmt.tprintf("%s\n%s\n", usage.usage, usage.title)))
	expected := cli_protocol.Reply_Json {
		ok = true,
		commands = []cli_protocol.Command_Report{cli_protocol.Command_Report(usage)},
	}
	encoded, err := json.marshal(expected, {}, context.temp_allocator)
	if !testing.expect_value(t, err, nil) {return}
	json_reply := app.control_cli_answer(&state, {"", "json", "", cli_protocol.CATALOGUE_COMMAND, "pane.send"})
	testing.expect_value(t, json_reply.text, string(encoded))
}

// Help gives --pane and each accepted argument a line saying what it does, its default and an example;
// --profile names the profiles that can launch, in settings order, and the default one.
@(test)
command_help_describes_every_option :: proc(t: ^testing.T) {
	state := app.App{registry = commands.create()}
	defer commands.destroy(&state.registry)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	profiles := &state.settings.profiles
	profiles.items = make([dynamic]settings.Profile, context.temp_allocator)
	append(
		&profiles.items,
		settings.Profile{id = "pwsh", command = "pwsh.exe"},
		settings.Profile{id = "empty"},
		settings.Profile{id = "cmd", command = "cmd.exe"},
	)
	profiles.default_id = "cmd"
	split := commands.find(&state.registry, "pane.split")
	reply := app.control_cli_answer(&state, {"", "text", "", cli_protocol.CATALOGUE_COMMAND, "pane.split"})
	if !testing.expect(t, reply.ok) {return}
	lines, split_error := strings.split_lines(reply.text, context.temp_allocator)
	if !testing.expect_value(t, split_error, nil) {return}
	// Usage, title, summary and a blank line come first.
	options := lines[4:]
	if !testing.expect_value(t, len(options), 1 + card(split.arguments)) {return}
	testing.expect(t, strings.has_prefix(options[0], "  --pane <pane> "))
	for line in options {
		described := strings.contains(line, "; default: ") && strings.contains(line, "; example: ")
		testing.expectf(t, described, "%q", line)
	}
	i := 1
	for argument in commands.Argument {
		if argument not_in split.arguments {continue}
		form := strings.builder_make(context.temp_allocator)
		commands.argument_write(&form, argument)
		prefix := fmt.tprintf("  %s ", strings.to_string(form))
		testing.expectf(t, strings.has_prefix(options[i], prefix), "%q", options[i])
		if argument == .Profile {
			listed := strings.contains(options[i], "by id: cmd, pwsh;") && strings.contains(options[i], "now cmd;")
			testing.expectf(t, listed, "%q", options[i])
		}
		i += 1
	}
	send := app.control_cli_answer(&state, {"", "text", "", cli_protocol.CATALOGUE_COMMAND, "pane.send"})
	testing.expectf(t, strings.contains(send.text, "the text to type; required; example: "), "%q", send.text)
	json_reply := app.control_cli_answer(&state, {"", "json", "", cli_protocol.CATALOGUE_COMMAND, "pane.split"})
	document: cli_protocol.Reply_Json
	parsed := json.unmarshal_string(json_reply.text, &document, allocator = context.temp_allocator)
	if !testing.expect_value(t, parsed, nil) {return}
	if !testing.expect_value(t, len(document.commands), 1) {return}
	testing.expect_value(t, len(document.commands[0].options), 1 + card(split.arguments))
	testing.expect(t, document.commands[0].summary != "")
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

@(private = "file")
policy_key :: proc(s: ^app.App, w: ^app.Window, key: input.Key) {
	e := input.Key_Event{window = w.id, key = key, pressed = true}
	app.handle_event(s, e)
	e.pressed = false
	app.handle_event(s, e)
}

// Restart Stopped Pane holds Enter only while the focused session can restart; otherwise, and while
// the find bar has the keyboard, Enter goes on to the pane, as it did before the key was a binding.
@(test)
pane_restart_takes_its_keys_only_from_a_stopped_session :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "pane-restart", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	entry := app.focused_session(s, w)
	if !testing.expect(t, entry != nil && entry.status == .Running) {return}
	command := commands.find(&s.registry, "pane.restart")
	if !testing.expect(t, command != nil) {return}
	defaults := commands.active_shortcuts(command)
	if testing.expect_value(t, len(defaults), 2) {
		testing.expect_value(t, defaults[0], commands.Shortcut{.Enter, {}})
		testing.expect_value(t, defaults[1], commands.Shortcut{.Numpad_Enter, {}})
	}
	exited := term.Status{kind = .Exited, exit_code = 1}
	testing.expect_value(t, app.session_message(s, "", exited), "The shell exited with code 1. Press Enter to restart it.")
	testing.expect(t, !app.action_available(s, w, .Restart_Pane))
	app.handle_event(s, input.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect(t, !app.key_suppressed(w, .Enter))
	app.handle_event(s, input.Key_Event{window = w.id, key = .Enter})
	entry.status = .Exited
	testing.expect(t, app.action_available(s, w, .Restart_Pane))
	policy_key(s, w, .Numpad_Enter)
	testing.expect_value(t, entry.status, term.Status_Kind.Running)
	entry.status = .Exited
	ui.find_open(&w.find)
	testing.expect(t, !app.action_available(s, w, .Restart_Pane))
	policy_key(s, w, .Enter)
	testing.expect_value(t, entry.status, term.Status_Kind.Exited)
	ui.find_close(&w.find)
	bindings := [?]commands.Shortcut{{.F5, {}}}
	overrides := [?]commands.Override{{command.id, bindings[:]}}
	errors: [1]commands.Error
	testing.expect_value(t, commands.rebind(&s.registry, overrides[:], errors[:]), commands.Error.None)
	policy_key(s, w, .Enter)
	testing.expect_value(t, entry.status, term.Status_Kind.Exited)
	policy_key(s, w, .F5)
	testing.expect_value(t, entry.status, term.Status_Kind.Running)
	testing.expect_value(t, app.session_message(s, "", exited), "The shell exited with code 1. Press F5 to restart it.")
	unbound := [?]commands.Override{{command.id, nil}}
	testing.expect_value(t, commands.rebind(&s.registry, unbound[:], errors[:]), commands.Error.None)
	testing.expect_value(t, app.session_message(s, "pwsh", {kind = .Failed, message = "Gone."}),
		"Gone. Check profile.pwsh.command and profile.pwsh.directory in settings, then run Restart Stopped Pane to try again.")
}
