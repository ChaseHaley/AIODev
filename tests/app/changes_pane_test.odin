package app_test

import "aio:layout"
import "aio:platform"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"

@(private = "file")
Fixture :: struct {
	state:     app.App,
	directory: string,
}

@(private = "file")
fixture_start :: proc(t: ^testing.T, f: ^Fixture, name: string, keep_directory := false) -> bool {
	if !keep_directory {
		directory, err := os.make_directory_temp("", "aio-changes-*", context.allocator)
		if !testing.expect_value(t, err, nil) {return false}
		f.directory = directory
		settings_path := strings.concatenate({directory, "/settings.ini"}, context.temp_allocator)
		text := idle_shell_settings(t, "cursor.blink = false\n")
		if !testing.expect_value(t, os.write_entire_file(settings_path, text), nil) {return false}
	}
	f.state = {options = {data_dir = f.directory, inactive = true}}
	f.state.app_id = fmt.aprintf("AIODev.Test.Changes.%s.%d", name, os.get_pid())
	app.layout_state_enable(&f.state, strings.concatenate({f.directory, "/layout.json"}))
	if !testing.expect_value(t, platform.init(&f.state.platform, f.state.app_id), platform.Init_Result.Primary) {
		return false
	}
	f.state.platform_ready = true
	return testing.expect(t, app.app_init(&f.state))
}

@(private = "file")
changes_pane_of :: proc(state: ^app.App, w: ^app.Window) -> (layout.Pane_Rect, bool) {
	for pane in w.panes {if pane.content.kind == .Changes {return pane, true}}
	return {}, false
}

@(test)
agent_changes_opens_another_pane_on_every_run :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Open") {return}
	w := f.state.windows[0]
	terminal := app.window_tree(w).focus
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 1) {return}
	pane := f.state.changes_panes[0]
	testing.expect_value(t, pane.scope, ui.Changes_Scope.Uncommitted)
	testing.expect_value(t, pane.agent.pane_key, f.state.sessions[0].key)
	testing.expect(t, app.workspace_has_content(w.workspace, {.Changes, pane.id}))
	testing.expect_value(t, app.window_tree(w).focus != terminal, true)
	tree := app.window_tree(w)
	testing.expect_value(t, layout.find_content(tree, {.Changes, pane.id}) != layout.INVALID_NODE, true)

	// A run from an Agent changes pane opens another with its agent and scope.
	agent, cloned := app.changes_session_clone(
		{pane_key = pane.agent.pane_key, harness = "claude", session = "s1"},
	)
	if !testing.expect(t, cloned) {return}
	app.changes_session_delete(&pane.agent)
	pane.agent, pane.scope = agent, .Staged
	app.run_action(&f.state, w, .Agent_Changes)
	if !testing.expect_value(t, len(f.state.changes_panes), 2) {return}
	opened := f.state.changes_panes[1]
	testing.expect(t, app.workspace_has_content(w.workspace, {.Changes, pane.id}))
	testing.expect(t, app.workspace_has_content(w.workspace, {.Changes, opened.id}))
	testing.expect_value(t, opened.scope, ui.Changes_Scope.Staged)
	testing.expect_value(t, opened.agent.pane_key, pane.agent.pane_key)
	testing.expect_value(t, opened.agent.harness, "claude")
	testing.expect_value(t, opened.agent.session, "s1")
	testing.expect_value(t, opened.directory, pane.directory)
	focused, _ := app.window_focused_content(w)
	testing.expect_value(t, focused, layout.Content{.Changes, opened.id})
}

@(test)
layout_restore_keeps_a_changes_pane_with_its_agent_scope_and_directory :: proc(t: ^testing.T) {
	first: Fixture
	if !fixture_start(t, &first, "RestoreA") {return}
	defer delete(first.directory)
	defer testing.expect_value(t, os.remove_all(first.directory), nil)
	app.run_action(&first.state, first.state.windows[0], .Agent_Changes)
	if !testing.expect_value(t, len(first.state.changes_panes), 1) {
		app.app_destroy(&first.state)
		return
	}
	saved := first.state.changes_panes[0]
	saved.scope = .Staged
	agent, cloned := app.changes_session_clone(
		{pane_key = saved.agent.pane_key, harness = "codex", session = "s9"},
	)
	if !testing.expect(t, cloned) {
		app.app_destroy(&first.state)
		return
	}
	app.changes_session_delete(&saved.agent)
	saved.agent = agent
	directory := strings.clone(saved.directory)
	pane_key := strings.clone(saved.agent.pane_key)
	defer delete(directory)
	defer delete(pane_key)
	app.layout_state_save(&first.state)
	app.app_destroy(&first.state)

	second := Fixture{directory = first.directory}
	if !fixture_start(t, &second, "RestoreB", true) {return}
	defer app.app_destroy(&second.state)
	if !testing.expect_value(t, len(second.state.changes_panes), 1) {return}
	restored := second.state.changes_panes[0]
	testing.expect_value(t, restored.scope, ui.Changes_Scope.Staged)
	testing.expect_value(t, restored.directory, directory)
	testing.expect_value(t, restored.agent.pane_key, pane_key)
	testing.expect_value(t, restored.agent.harness, "codex")
	testing.expect_value(t, restored.agent.session, "s9")
}

@(test)
turn_settings_default_to_off_and_two_weeks :: proc(t: ^testing.T) {
	s, d, err := settings.parse("")
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, s.turns.record, false)
	testing.expect_value(t, s.turns.retention_days, 14)
}

@(test)
the_record_button_turns_recording_on :: proc(t: ^testing.T) {
	f: Fixture
	defer {
		app.app_destroy(&f.state)
		testing.expect_value(t, os.remove_all(f.directory), nil)
		delete(f.directory)
	}
	if !fixture_start(t, &f, "Record") {return}
	testing.expect(t, !f.state.settings.turns.record)
	app.run_action(&f.state, f.state.windows[0], .Agent_Changes)
	f.state.changes_panes[0].scope = .Agent
	app.changes_model_changed(&f.state, f.state.changes_panes[0])
	testing.expect_value(t, f.state.changes_panes[0].model.view.notice, ui.Changes_Notice.Recording_Off)
	testing.expect(t, app.settings_save_value(&f.state, "turns.record", "true", "Could not turn on turn recording."))
	testing.expect(t, f.state.settings.turns.record)
	app.changes_model_changed(&f.state, f.state.changes_panes[0])
	testing.expect(t, f.state.changes_panes[0].model.view.notice != ui.Changes_Notice.Recording_Off)
}
