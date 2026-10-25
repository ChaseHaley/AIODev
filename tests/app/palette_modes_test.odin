package app_test

import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:platform"
import "aio:ui"

@(private)
palette_mode_commands := [?]struct {
	action: app.Action,
	name:   string,
	mode:   ui.Palette_Mode,
}{
	{app.Action.Palette_Tabs, "app.palette_tabs", .Tabs},
	{app.Action.Palette_Workspaces, "app.palette_workspaces", .Workspaces},
	{app.Action.Palette_Settings, "app.palette_settings", .Settings},
	{app.Action.Palette_Commands, "app.palette_commands", .Commands},
}

@(test)
palette_mode_actions_register_without_defaults :: proc(t: ^testing.T) {
	registry := commands.create()
	defer commands.destroy(&registry)
	if !testing.expect_value(t, app.register_actions(&registry), commands.Error.None) {return}
	for entry in palette_mode_commands {
		command := commands.find(&registry, entry.name)
		if !testing.expect(t, command != nil) {continue}
		testing.expect_value(t, command.title, expected_title(entry.action))
		testing.expect_value(t, len(commands.active_shortcuts(command)), 0)
		testing.expect_value(t, command.defaults.count, 0)
		testing.expect_value(t, app.palette_action_mode(entry.action), entry.mode)
	}
	testing.expect_value(t, app.palette_action_mode(.Command_Palette), ui.Palette_Mode.All)
}

@(private)
expected_title :: proc(action: app.Action) -> string {
	#partial switch action {
	case .Palette_Tabs:
		return "Show Palette: Tabs"
	case .Palette_Workspaces:
		return "Show Palette: Workspaces"
	case .Palette_Settings:
		return "Show Palette: Settings"
	case .Palette_Commands:
		return "Show Palette: Commands"
	case:
		return ""
	}
}

@(test)
palette_mode_binding_survives_reload_and_opens_its_mode :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "mode-reload") {return}
	s := &f.state
	first := s.windows[0]
	content, read_ok := os.read_entire_file(f.path, context.allocator)
	if !testing.expect_value(t, read_ok, nil) {return}
	defer delete(content)
	updated := strings.concatenate(
		{string(content), "keys.app.palette_tabs = Ctrl+Alt+1\n"},
		context.temp_allocator,
	)
	if !testing.expect_value(t, os.write_entire_file(f.path, updated), nil) {return}
	app.reload_settings(s, false)
	bound := commands.find_by_key(
		&s.registry,
		.Digit_1,
		{.Control, .Alt},
		0,
	)
	if !testing.expect(t, bound != nil) {return}
	testing.expect_value(t, bound.name, "app.palette_tabs")

	app.handle_event(
		s,
		platform.Key_Event {
			window = first.id,
			key = .Digit_1,
			modifiers = {.Control, .Alt},
			pressed = true,
		},
	)
	testing.expect(t, app.palette_active(s, first))
	testing.expect_value(t, s.palette.mode, ui.Palette_Mode.Tabs)
	testing.expect_value(t, ui.palette_query(&s.palette), "")
}

@(private)
palette_select_id :: proc(t: ^testing.T, s: ^app.App, id: u64) -> bool {
	for result, index in s.palette.results {
		if ui.palette_target(&s.palette, result).id != id {continue}
		s.palette.selected = index
		return true
	}
	return false
}

@(test)
palette_tab_activation_selects_the_tab_and_its_window :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "mode-tabs") {return}
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	first_workspace := first.workspace
	second_workspace := second.workspace
	app.tab_new(s, first)
	app.tab_new(s, second)
	if !testing.expect_value(t, first.workspace.selected, 1) {return}
	if !testing.expect_value(t, second.workspace.selected, 1) {return}
	first_tab := first_workspace.tabs[0]
	second_tab := second_workspace.tabs[0]
	first_key := u64(first_workspace.id) << 32 | u64(first_tab.id)
	second_key := u64(second_workspace.id) << 32 | u64(second_tab.id)

	app.palette_open_mode(s, first, .Tabs)
	if !testing.expect(t, palette_select_id(t, s, first_key)) {return}
	app.handle_event(
		s,
		platform.Key_Event{window = first.id, key = .Enter, pressed = true},
	)
	testing.expect(t, !app.palette_active(s, first))
	testing.expect_value(t, first_workspace.selected, 0)

	// A tab in another window is selected there; the requesting window keeps its workspace.
	app.palette_open_mode(s, first, .Tabs)
	if !testing.expect(t, palette_select_id(t, s, second_key)) {return}
	app.handle_event(
		s,
		platform.Key_Event{window = first.id, key = .Enter, pressed = true},
	)
	testing.expect(t, !app.palette_active(s, first))
	testing.expect_value(t, second_workspace.selected, 0)
	testing.expect_value(t, first.workspace, first_workspace)
}

@(test)
palette_workspace_activation_follows_exclusive_ownership :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "mode-workspaces") {return}
	s := &f.state
	first, second := s.windows[0], s.windows[1]
	first_workspace, second_workspace := first.workspace, second.workspace
	other := app.workspace_create_empty(s)
	if !testing.expect(t, other != nil) {return}
	if !testing.expect(t, app.tab_create(s, other)) {return}

	app.palette_open_mode(s, first, .Workspaces)
	if !testing.expect(t, palette_select_id(t, s, u64(second_workspace.id))) {return}
	app.handle_event(
		s,
		platform.Key_Event{window = first.id, key = .Enter, pressed = true},
	)
	testing.expect_value(t, app.window_for_workspace(s, second_workspace), second)
	testing.expect_value(t, first.workspace, first_workspace)

	// An unowned workspace is adopted by the requesting window.
	app.palette_open_mode(s, first, .Workspaces)
	if !testing.expect(t, palette_select_id(t, s, u64(other.id))) {return}
	app.handle_event(
		s,
		platform.Key_Event{window = first.id, key = .Enter, pressed = true},
	)
	testing.expect_value(t, first.workspace, other)
	testing.expect_value(t, app.window_for_workspace(s, other), first)
}

@(test)
palette_mode_actions_open_directly_and_default_to_all :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "mode-actions") {return}
	s := &f.state
	first := s.windows[0]
	for entry in palette_mode_commands {
		app.run_action(s, first, entry.action)
		if !testing.expect(t, app.palette_active(s, first)) {return}
		testing.expect_value(t, s.palette.mode, entry.mode)
		app.palette_close(s, first)
		app.update_motion(s)
		testing.expect(t, !s.palette.open)
	}
	app.run_action(s, first, .Command_Palette)
	testing.expect_value(t, s.palette.mode, ui.Palette_Mode.All)
}
