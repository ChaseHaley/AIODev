package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import app "../../src"
import "aio:cli_protocol"
import "aio:commands"
import "aio:events"
import "aio:layout"
import "cosmos:platform"
import "aio:settings"

// How these tests watch events: app.tick ends in app_events_deliver, which hands the tick's events to
// its consumers and frees them, and it has no hook a test can join. So the tests never read across a
// tick. A command or exported mutation pushes its events at once, and events_take then runs
// app_events_settle, what app_events_deliver runs before it takes the batch, and copies
// events.pending out. Where the event comes from the per-tick poll (pane.exited), the test calls
// app.update_sessions itself in place of tick, which reads the same atomically set flags.
@(private = "file")
Seen :: struct {
	kind:   events.Kind,
	fields: string,
}

@(private = "file")
events_take :: proc(state: ^app.App, seen: ^[dynamic]Seen) {
	app.app_events_settle(state)
	for event in events.pending(&state.events) {
		append(seen, Seen{event.kind, strings.clone(event.fields)})
	}
	events.clear(&state.events)
}

// Drops what `seen` holds, keeping it for the next step.
@(private = "file")
seen_reset :: proc(seen: ^[dynamic]Seen) {
	for event in seen {delete(event.fields)}
	clear(seen)
}

@(private = "file")
seen_free :: proc(seen: ^[dynamic]Seen) {
	seen_reset(seen)
	delete(seen^)
}

// How many of `seen` are `kind`, and with `fields` when it is not empty.
@(private = "file")
seen_count :: proc(seen: []Seen, kind: events.Kind, fields := "") -> int {
	count := 0
	for event in seen {
		if event.kind == kind && (fields == "" || event.fields == fields) {count += 1}
	}
	return count
}

// Every event of `kind` in `seen`, for failure messages.
@(private = "file")
seen_list :: proc(seen: []Seen, kind: events.Kind) -> string {
	b := strings.builder_make(context.temp_allocator)
	for event in seen {
		if event.kind == kind {fmt.sbprintf(&b, "%s ", event.fields)}
	}
	return strings.to_string(b)
}

@(private = "file")
invoke :: proc(state: ^app.App, caller: u32, args: ..string) -> app.Outcome {
	invocation, err := commands.parse_invocation(&state.registry, args, context.temp_allocator)
	if err.advice != "" {return {status = .Usage, message = err.advice}}
	return app.command_execute(state, app.Control_Request{caller = caller, origin = .Cli}, invocation)
}

// An app with real idle-shell panes, settled through its first ticks, listening for every kind.
@(private = "file")
Fixture :: struct {
	directory, path: string,
	state:           app.App,
	seen:            [dynamic]Seen,
}

@(private = "file")
fixture_open :: proc(t: ^testing.T, f: ^Fixture, label: string) -> bool {
	directory, directory_error := os.make_directory_temp("", "aio-events-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) {return false}
	f.directory = directory
	f.path = strings.concatenate({directory, "/settings.ini"})
	text := idle_shell_settings(t, "cursor.blink = false\n")
	if !testing.expect_value(t, os.write_entire_file(f.path, text), nil) {return false}
	f.state = app.App{options = {data_dir = directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Events%s.%d", label, os.get_pid())
	initialised := platform.init(&f.state.platform, f.state.app_id)
	if !testing.expect_value(t, initialised, platform.Init_Result.Primary) {return false}
	f.state.platform_ready = true
	if !testing.expect(t, app.app_init(&f.state)) {return false}
	// The first ticks show the window and announce what startup opened; these tests watch what follows.
	settled := false
	for deadline := time.tick_now(); !settled && time.tick_since(deadline) < 5 * time.Second; {
		app.tick(&f.state)
		settled = len(f.state.windows) > 0 && f.state.windows[0].phase == .Shown && !f.state.events_unattached
	}
	if !testing.expect(t, settled, "the app's first window shows") {return false}
	events.set_interest(&f.state.events, .Lua, ~events.Kinds{})
	events.clear(&f.state.events)
	return true
}

@(private = "file")
fixture_close :: proc(t: ^testing.T, f: ^Fixture) {
	seen_free(&f.seen)
	app.app_destroy(&f.state)
	if f.path != "" {
		os.remove(f.path)
		delete(f.path)
	}
	if f.directory != "" {
		testing.expect_value(t, os.remove(f.directory), nil)
		delete(f.directory)
	}
}

// pane.created names each pane with the tab and workspace pane.list reports. pane.list's `tab` is the
// tab's position from 1, so the event's tab id is the id of the tab at that position.
@(test)
app_events_report_pane_and_tab_lifecycles_with_pane_list_ids :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_close(t, &f)
	if !fixture_open(t, &f, "Lifecycle") {return}
	state := &f.state
	w := state.windows[0]
	workspace := w.workspace
	first := state.sessions[0].id

	created := invoke(state, first, "tab.new", "--name", "agent")
	if !testing.expect_value(t, created.status, cli_protocol.Status.Ok) {return}
	tab_pane := created.payload.(app.Outcome_Created).pane
	split := invoke(state, first, "pane.split", "--pane", "agent", "--direction", "down")
	if !testing.expect_value(t, split.status, cli_protocol.Status.Ok) {return}
	split_pane := split.payload.(app.Outcome_Created).pane
	events_take(state, &f.seen)
	if !testing.expect_value(t, len(workspace.tabs), 2) {return}
	second := workspace.tabs[1].id
	tab_created := fmt.tprintf(`{{"tab":%d,"workspace":%d}`, second, workspace.id)
	testing.expectf(t, seen_count(f.seen[:], .Tab_Created, tab_created) == 1 &&
		seen_count(f.seen[:], .Tab_Created) == 1, "tab.created: %s", seen_list(f.seen[:], .Tab_Created))
	testing.expectf(t, seen_count(f.seen[:], .Pane_Created) == 2, "pane.created: %s",
		seen_list(f.seen[:], .Pane_Created))
	listed := invoke(state, 0, "pane.list")
	if !testing.expect_value(t, listed.status, cli_protocol.Status.Ok) {return}
	opened := [?]u32{tab_pane, split_pane}
	for id in opened {
		found := false
		for report in listed.payload.(app.Outcome_Panes) {
			if report.id != id {continue}
			found = true
			if !testing.expect(t, report.tab >= 1 && report.tab <= len(workspace.tabs)) {continue}
			tab := workspace.tabs[report.tab - 1].id
			expected := fmt.tprintf(`{{"pane":%d,"tab":%d,"workspace":%d}`, id, tab, report.workspace)
			testing.expectf(t, seen_count(f.seen[:], .Pane_Created, expected) == 1, "want %s in %s",
				expected, seen_list(f.seen[:], .Pane_Created))
		}
		testing.expectf(t, found, "pane.list reports pane %d", id)
	}

	// Focus moves from the caller's pane to the split one, in the other tab.
	previous := app.focused_session(state, w)
	if !testing.expect(t, previous != nil && previous.id == first) {return}
	seen_reset(&f.seen)
	split_id := fmt.tprintf("%d", split_pane)
	focus := invoke(state, first, "pane.focus", "--pane", split_id)
	testing.expect_value(t, focus.status, cli_protocol.Status.Ok)
	events_take(state, &f.seen)
	focused := fmt.tprintf(`{{"pane":%d,"previous":%d}`, split_pane, first)
	testing.expectf(t, seen_count(f.seen[:], .Pane_Focused, focused) == 1 &&
		seen_count(f.seen[:], .Pane_Focused) == 1, "pane.focused: %s", seen_list(f.seen[:], .Pane_Focused))
	selected := fmt.tprintf(`{{"tab":%d,"workspace":%d}`, second, workspace.id)
	testing.expectf(t, seen_count(f.seen[:], .Tab_Selected, selected) == 1, "tab.selected: %s",
		seen_list(f.seen[:], .Tab_Selected))

	// Renames report the cleaned name; C1 has no pane rename event, so pane.rename is not watched.
	seen_reset(&f.seen)
	testing.expect_value(t, invoke(state, first, "tab.rename", "Build").status, cli_protocol.Status.Ok)
	testing.expect_value(t, invoke(state, first, "workspace.rename", "Main").status, cli_protocol.Status.Ok)
	events_take(state, &f.seen)
	renamed := fmt.tprintf(`{{"tab":%d,"workspace":%d,"name":"Build"}`, workspace.tabs[0].id, workspace.id)
	testing.expectf(t, seen_count(f.seen[:], .Tab_Renamed, renamed) == 1, "tab.renamed: %s",
		seen_list(f.seen[:], .Tab_Renamed))
	workspace_renamed := fmt.tprintf(`{{"workspace":%d,"name":"Main"}`, workspace.id)
	testing.expectf(t, seen_count(f.seen[:], .Workspace_Renamed, workspace_renamed) == 1,
		"workspace.renamed: %s", seen_list(f.seen[:], .Workspace_Renamed))

	// Closing the two-pane tab closes each running pane, without an exit code, and the tab once.
	seen_reset(&f.seen)
	index := app.tab_index_by_id(workspace, second)
	if !testing.expect_value(t, index, 1) {return}
	app.tab_close(state, w, index)
	events_take(state, &f.seen)
	testing.expect_value(t, len(workspace.tabs), 1)
	for id in opened {
		closed := fmt.tprintf(`{{"pane":%d}`, id)
		testing.expectf(t, seen_count(f.seen[:], .Pane_Closed, closed) == 1, "want %s in %s", closed,
			seen_list(f.seen[:], .Pane_Closed))
	}
	testing.expect_value(t, seen_count(f.seen[:], .Pane_Closed), 2)
	testing.expectf(t, seen_count(f.seen[:], .Tab_Closed, tab_created) == 1 &&
		seen_count(f.seen[:], .Tab_Closed) == 1, "tab.closed: %s", seen_list(f.seen[:], .Tab_Closed))
}

// A program's exit is reported once with its code, before the auto-close that follows reports the
// pane closed with the same code.
@(test)
app_events_report_a_programs_exit_code :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_close(t, &f)
	if !fixture_open(t, &f, "Exit") {return}
	state := &f.state
	first := state.sessions[0].id
	split := invoke(state, first, "pane.split", "--", "cmd.exe", "/d", "/c", "exit", "3")
	if !testing.expectf(t, split.status == .Ok, "pane.split: %v %s", split.status, split.message) {return}
	pane := split.payload.(app.Outcome_Created).pane
	exited := fmt.aprintf(`{{"pane":%d,"exit_code":3}`, pane)
	defer delete(exited)
	for deadline := time.tick_now(); time.tick_since(deadline) < 15 * time.Second; {
		app.update_sessions(state)
		events_take(state, &f.seen)
		free_all(context.temp_allocator)
		if seen_count(f.seen[:], .Pane_Exited) > 0 && seen_count(f.seen[:], .Pane_Closed) > 0 {break}
		time.sleep(50 * time.Millisecond)
	}
	testing.expectf(t, seen_count(f.seen[:], .Pane_Exited, exited) == 1 &&
		seen_count(f.seen[:], .Pane_Exited) == 1, "pane.exited: %s", seen_list(f.seen[:], .Pane_Exited))
	testing.expectf(t, seen_count(f.seen[:], .Pane_Closed, exited) == 1, "pane.closed: %s",
		seen_list(f.seen[:], .Pane_Closed))
	exit_at, closed_at := -1, -1
	for event, i in f.seen {
		if event.kind == .Pane_Exited && exit_at < 0 {exit_at = i}
		if event.kind == .Pane_Closed && closed_at < 0 {closed_at = i}
	}
	testing.expect(t, exit_at >= 0 && exit_at < closed_at, "pane.exited comes before pane.closed")
}

// A bare app with an initialised queue listening for every kind, and one workspace holding a Settings
// tab, so nothing starts a process.
@(private = "file")
bare_open :: proc(t: ^testing.T, state: ^app.App) -> (^app.Workspace, ^app.Tab, bool) {
	events.init(&state.events)
	events.set_interest(&state.events, .Lua, ~events.Kinds{})
	workspace := app.workspace_create_empty(state)
	if !testing.expect(t, workspace != nil) {return nil, nil, false}
	tab, reserved := app.tab_record_reserve(workspace)
	if !testing.expect(t, reserved) {return nil, nil, false}
	if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {
		app.tab_record_free(tab)
		return nil, nil, false
	}
	app.tab_record_commit(state, workspace, tab)
	return workspace, tab, true
}

@(private = "file")
bare_close :: proc(state: ^app.App) {
	for workspace in state.workspaces {app.workspace_destroy(workspace)}
	delete(state.workspaces)
	events.destroy(&state.events)
}

// The revision advances once for the mutations a tick makes, only when the arrangement differs, and
// whether or not anyone listens.
@(test)
app_events_layout_revision_advances_once_per_tick_after_a_mutation :: proc(t: ^testing.T) {
	state: app.App
	defer bare_close(&state)
	_, tab, ok := bare_open(t, &state)
	if !ok {return}
	seen: [dynamic]Seen
	defer seen_free(&seen)
	events_take(&state, &seen)
	testing.expect_value(t, state.events.revision, 1)
	testing.expect_value(t, seen_count(seen[:], .Layout_Changed, `{"revision":1}`), 1)
	seen_reset(&seen)
	events_take(&state, &seen)
	testing.expect_value(t, state.events.revision, 1)
	testing.expect_value(t, seen_count(seen[:], .Layout_Changed), 0)

	notes, split_error := layout.split(&tab.tree, tab.tree.root, .Horizontal, 0.5, {.Markdown, 7})
	if !testing.expect_value(t, split_error, nil) {return}
	_, split_error = layout.split(&tab.tree, notes, .Vertical, 0.25, {.Markdown, 8})
	if !testing.expect_value(t, split_error, nil) {return}
	events_take(&state, &seen)
	testing.expect_value(t, state.events.revision, 2)
	testing.expectf(t, seen_count(seen[:], .Layout_Changed, `{"revision":2}`) == 1 &&
		seen_count(seen[:], .Layout_Changed) == 1, "layout.changed: %s", seen_list(seen[:], .Layout_Changed))

	seen_reset(&seen)
	events.set_interest(&state.events, .Lua, {})
	_, split_error = layout.split(&tab.tree, notes, .Horizontal, 0.5, {.Markdown, 9})
	if !testing.expect_value(t, split_error, nil) {return}
	events_take(&state, &seen)
	testing.expect_value(t, state.events.revision, 3)
	testing.expect_value(t, len(seen), 0)
}

// The Settings page's commit path, without a settings file, changes the running settings and reports
// the key with its new value, and nothing for an assignment that changes nothing.
@(test)
app_events_settings_change_reports_the_key_and_new_value :: proc(t: ^testing.T) {
	state: app.App
	events.init(&state.events)
	defer events.destroy(&state.events)
	events.set_interest(&state.events, .Cli, {.Settings_Changed})
	entry := settings.schema_find("cursor.blink")
	if !testing.expect(t, entry != nil) {return}
	next := settings.value_text(&state.settings, entry^) == "true" ? "false" : "true"
	result := app.settings_change(&state, app.Setting_Value{"cursor.blink", next}, app.Settings_Current{})
	testing.expect_value(t, result.status, app.Settings_Status.Applied)
	pending := events.pending(&state.events)
	if !testing.expect_value(t, len(pending), 1) {return}
	testing.expect_value(t, pending[0].kind, events.Kind.Settings_Changed)
	testing.expect_value(t, pending[0].fields, fmt.tprintf(`{{"key":"cursor.blink","value":"%s"}`, next))
	events.clear(&state.events)
	again := app.settings_change(&state, app.Setting_Value{"cursor.blink", next}, app.Settings_Current{})
	testing.expect_value(t, again.status, app.Settings_Status.Applied)
	testing.expect_value(t, len(events.pending(&state.events)), 0)
}

// A saved revision reports each schema key it changes and each other assignment it adds, changes or
// removes, as settings_change does after saving the file.
@(test)
app_events_settings_commit_reports_changed_and_removed_keys :: proc(t: ^testing.T) {
	state: app.App
	events.init(&state.events)
	defer events.destroy(&state.events)
	events.set_interest(&state.events, .Lua, {.Settings_Changed})
	previous :: "cursor.blink = false\nprofile.x.name = X\nprofile.x.command = cmd.exe\n"
	revision :: "cursor.blink = true\nprofile.x.name = Y\n"
	running, running_diagnostics, running_error := settings.parse(previous)
	defer settings.diagnostics_destroy(&running_diagnostics)
	if !testing.expect_value(t, running_error, nil) {return}
	state.settings = running
	defer settings.destroy(&state.settings)
	loaded, diagnostics, parse_error := settings.parse(revision)
	defer settings.destroy(&loaded)
	defer settings.diagnostics_destroy(&diagnostics)
	if !testing.expect_value(t, parse_error, nil) {return}
	app.app_events_settings_commit(&state, &loaded, previous, revision)
	seen: [dynamic]Seen
	defer seen_free(&seen)
	events_take(&state, &seen)
	expected := [?]string {
		`{"key":"cursor.blink","value":"true"}`,
		`{"key":"profile.x.name","value":"Y"}`,
		`{"key":"profile.x.command","value":""}`,
	}
	for fields in expected {
		testing.expectf(t, seen_count(seen[:], .Settings_Changed, fields) == 1, "want %s in %s", fields,
			seen_list(seen[:], .Settings_Changed))
	}
	testing.expectf(t, seen_count(seen[:], .Settings_Changed) == len(expected), "settings.changed: %s",
		seen_list(seen[:], .Settings_Changed))
}

// A tab whose only pane is the Settings page can be renamed; the event carries the cleaned name, an
// unchanged name reports nothing, and clearing the name reports the empty name.
@(test)
app_events_tab_rename_without_a_process_reports_tab_renamed :: proc(t: ^testing.T) {
	state: app.App
	defer bare_close(&state)
	workspace, tab, ok := bare_open(t, &state)
	if !ok {return}
	events.clear(&state.events)
	testing.expect(t, app.tab_name_set(&state, workspace, tab, "  Build  "))
	pending := events.pending(&state.events)
	if !testing.expect_value(t, len(pending), 1) {return}
	testing.expect_value(t, pending[0].kind, events.Kind.Tab_Renamed)
	testing.expect_value(
		t, pending[0].fields, fmt.tprintf(`{{"tab":%d,"workspace":%d,"name":"Build"}`, tab.id, workspace.id),
	)
	events.clear(&state.events)
	testing.expect(t, app.tab_name_set(&state, workspace, tab, "Build"))
	testing.expect_value(t, len(events.pending(&state.events)), 0)
	testing.expect(t, app.tab_name_set(&state, workspace, tab, ""))
	pending = events.pending(&state.events)
	if !testing.expect_value(t, len(pending), 1) {return}
	testing.expect_value(
		t, pending[0].fields, fmt.tprintf(`{{"tab":%d,"workspace":%d,"name":""}`, tab.id, workspace.id),
	)
}
