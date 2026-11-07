package app_test

import "aio:input"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

@(test)
pane_window_preparation_cancel_and_commit_keep_runtime :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-pane-windows-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path,
		idle_shell_settings(t, "cursor.blink = false\n")), nil) { return }
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.PaneWindows.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) { return }
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	source_window := state.windows[0]
	source_workspace := source_window.workspace
	source := app.selected_tab(source_workspace)
	node := source.tree.root
	session := state.sessions[0].session
	pid := term.process_id(session)
	geometry := term.geometry(session)
	workspace_id := state.next_workspace_id
	tab_id := source_workspace.next_tab_id
	last_preview := app.pane_window_preview_create(&state, source, node)
	testing.expect(t, last_preview == nil)
	if last_preview != nil { app.pane_window_preview_discard(&state, last_preview.id) }
	testing.expect_value(t, state.next_workspace_id, workspace_id)
	testing.expect_value(t, source_workspace.next_tab_id, tab_id)
	app.pane_drag_press(&state, source_window, node, 80, 58)
	testing.expect(t, app.pane_drag_move(&state, source_window, -30_000, -30_000, false))
	_, tear_off := app.pane_drag_destination(source_window).(app.Drop_Tear_Off)
	testing.expect(t, app.pane_drag_active(source_window) && !tear_off)
	_, failed_preview := app.drag_active(source_window).preview.(app.Preview_Failed)
	testing.expect(t, !failed_preview)
	testing.expect_value(t, drag_preview(source_window), input.Window_Id(0))
	testing.expect(t, app.pane_drag_release(&state, source_window))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, state.next_workspace_id, workspace_id)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, term.process_id(session), pid)
	app.run_action(&state, source_window, .Settings_UI)
	settings_tab := app.selected_tab(source_workspace)
	workspace_id = state.next_workspace_id
	settings_preview := app.pane_window_preview_create(&state, settings_tab, settings_tab.tree.root)
	if !testing.expect(t, settings_preview != nil) { return }
	app.pane_window_preview_discard(&state, settings_preview.id)
	testing.expect(t, state.next_workspace_id > workspace_id)
	testing.expect_value(t, len(state.workspaces), 1)
	settings_preview = app.pane_window_preview_create(&state, source, node)
	if !testing.expect(t, settings_preview != nil) { return }
	app.pane_window_preview_discard(&state, settings_preview.id)
	app.tab_close(&state, source_window, 1)
	testing.expect_value(t, len(source_workspace.tabs), 1)
	testing.expect_value(t, len(state.sessions), 1)
	if _, created := app.tab_create(&state, source_workspace); !testing.expect(t, created) { return }
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.pane_window_preview_create(&state, source, node)
	context.allocator = allocator
	testing.expect(t, failed == nil)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, source.tree.root, node)
	minimum := state.settings.pane.minimum_columns
	state.settings.pane.minimum_columns = 10_000
	failed = app.pane_window_preview_create(&state, source, node)
	state.settings.pane.minimum_columns = minimum
	testing.expect(t, failed == nil)
	testing.expect(t, state.next_workspace_id > workspace_id)
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, term.process_id(session), pid)
	preview := app.pane_window_preview_create(&state, source, node)
	if !testing.expect(t, preview != nil) { return }
	testing.expect(t, preview.phase == .Preparing)
	testing.expect_value(t, preview.workspace.name, "")
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.geometry(session), geometry)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, len(preview.views), 0)
	testing.expect_value(t, cap(preview.views), 0)
	app.window_set_dpi(&state, preview, 144)
	testing.expect_value(t, len(preview.views), 0)
	testing.expect_value(t, term.geometry(session), geometry)
	app.window_set_dpi(&state, preview, 96)
	preview_id := preview.id
	preview_workspace_id := preview.workspace.id
	app.pane_window_preview_discard(&state, preview_id)
	testing.expect(t, app.window_find(&state, preview_id) == nil)
	testing.expect_value(t, state.next_workspace_id, preview_workspace_id)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.geometry(session), geometry)
	preview = app.pane_window_preview_create(&state, source, node)
	if !testing.expect(t, preview != nil) { return }
	seed_pane_drag(source_window, source, node, preview = app.Preview_Ready{preview.id})
	app.window_close(&state, preview)
	testing.expect(t, !app.drag_held(source_window))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	testing.expect_value(t, term.geometry(session), geometry)
	preview = app.pane_window_preview_create(&state, source, node)
	if !testing.expect(t, preview != nil) { return }
	preview_id = preview.id
	app.tab_close(&state, source_window, 1)
	testing.expect(t, !app.pane_to_window(&state, source_window, source, node, preview_id))
	testing.expect(t, preview.phase == .Preparing && preview.workspace.provisional)
	testing.expect_value(t, source.tree.root, node)
	testing.expect_value(t, len(state.sessions), 1)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.geometry(session), geometry)
	app.pane_drag_press(&state, source_window, node, 80, 58)
	seed_pane_drag(source_window, source, node, preview = app.Preview_Ready{preview_id})
	testing.expect(t, app.pane_drag_move(&state, source_window, -30_000, -30_000, false))
	_, tear_off = app.pane_drag_destination(source_window).(app.Drop_Tear_Off)
	testing.expect(t, !tear_off)
	testing.expect_value(t, drag_preview(source_window), input.Window_Id(0))
	testing.expect(t, app.window_find(&state, preview_id) == nil)
	testing.expect(t, app.pane_drag_release(&state, source_window))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, len(state.workspaces), 1)
	if _, created := app.tab_create(&state, source_workspace); !testing.expect(t, created) { return }
	preview = app.pane_window_preview_create(&state, source, node)
	if !testing.expect(t, preview != nil) { return }
	preview_id = preview.id
	preview_workspace_id = preview.workspace.id
	allocator = context.allocator
	context.allocator = runtime.nil_allocator()
	failed_commit := app.pane_to_window(&state, source_window, source, node, preview_id)
	context.allocator = allocator
	testing.expect(t, !failed_commit)
	testing.expect(t, preview.phase == .Preparing && preview.workspace.provisional)
	testing.expect_value(t, source.tree.root, node)
	// The drop moves the pane at once, then names the new window in its own chip.
	seed_pane_drag(source_window, source, node, app.Drop_Tear_Off{}, app.Preview_Ready{preview_id})
	testing.expect(t, app.pane_drag_release(&state, source_window))
	testing.expect(t, !app.rename_shown(source_window))
	testing.expect(t, app.chip_name_shown(preview))
	testing.expect_value(t, ui.field_selected_text(&preview.rename), preview.workspace.name)
	geometry_default := app.initial_geometry(&state)
	testing.expect_value(t, u32(preview.width), geometry_default.surface_width)
	testing.expect_value(t, u32(preview.height), geometry_default.surface_height)
	_ = ui.field_text(&preview.rename, "Detached tools")
	app.rename_finish(&state, preview, true)
	testing.expect_value(t, preview.workspace.name, "Detached tools")
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, app.window_find(&state, preview_id) == preview)
	testing.expect(t, preview.phase == .Shown)
	testing.expect(t, preview.workspace.name != "" && preview.workspace.name != source_workspace.name)
	testing.expect_value(t, preview.workspace.id, preview_workspace_id)
	testing.expect(t, preview.workspace.id > 2)
	testing.expect_value(t, len(source_workspace.tabs), 1)
	testing.expect_value(t, len(preview.panes), 1)
	testing.expect_value(t, preview.panes[0].content, layout.Content{.Terminal, state.sessions[0].id})
	testing.expect_value(t, len(state.sessions), 2)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, term.status(session).kind, term.Status_Kind.Running)
	testing.expect(t, !state.tray_hint_shown)
	app.tick(&state)

	// A foreign empty strip accepts the sole pane and removes only its exhausted source view.
	second_workspace := app.workspace_create_empty(&state)
	if !testing.expect(t, second_workspace != nil) { return }
	if _, created := app.tab_create(&state, second_workspace); !testing.expect(t, created) { return }
	if !testing.expect(t, app.window_open(&state, second_workspace)) { return }
	second := app.window_for_workspace(&state, second_workspace)
	shown := app.selected_tab(preview.workspace)
	if !testing.expect(t, app.pane_to_tab(&state, second, shown, app.window_tree(preview).root)) { return }
	testing.expect_value(t, len(state.windows), 2)
	testing.expect(t, app.window_find(&state, second.id) == second)
	testing.expect_value(t, len(second_workspace.tabs), 2)
	testing.expect_value(t, len(state.sessions), 3)
	testing.expect_value(t, term.process_id(session), pid)
	testing.expect_value(t, second.panes[0].content.id, state.sessions[0].id)
}

// Regression: a tear-off moved the pane before showing its window, so a show the OS refused left the pane
// in a window off screen while the drop reported the source preserved; the tab path kept its tabs there
// and reported success. Both now show the window first, and a refused show moves nothing.
@(test)
tear_off_commit_moves_nothing_when_its_window_cannot_show :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "tear-off-show-fails", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	app.pane_split(s, w, .Right)
	if _, created := app.tab_create(s, w.workspace); !testing.expect(t, created) {return}
	app.tab_select(s, w, 0)
	source := app.selected_tab(w.workspace)
	node := source.tree.focus
	content := source.tree.nodes[node].(layout.Pane).content
	pane_preview := app.pane_window_preview_create(s, source, node)
	if !testing.expect(t, pane_preview != nil) {return}
	tab_preview := app.tab_window_preview_create(s, source)
	if !testing.expect(t, tab_preview != nil) {return}
	pane_id, tab_id := pane_preview.id, tab_preview.id
	errors := 0
	logger := context.logger
	context.logger = {
		procedure = proc(data: rawptr, level: runtime.Logger_Level, _: string, _: runtime.Logger_Options,
			_ := #caller_location) {
			if level >= .Error {(^int)(data)^ += 1}
		},
		data = &errors,
	}
	// Without its native window the preview cannot be shown.
	_ = platform.window_destroy(&s.platform, pane_id)
	_ = platform.window_destroy(&s.platform, tab_id)
	moved_pane := app.pane_to_window(s, w, source, node, pane_id)
	moved_tabs := app.tabs_to_window(s, w, tab_preview)
	pane_kept := pane_preview.phase == .Preparing && pane_preview.workspace.provisional
	tabs_kept := tab_preview.phase == .Preparing && tab_preview.workspace.provisional
	app.pane_window_preview_discard(s, pane_id)
	app.pane_window_preview_discard(s, tab_id)
	context.logger = logger
	testing.expect(t, !moved_pane && !moved_tabs)
	testing.expect(t, pane_kept && tabs_kept, "a refused show leaves each preview to discard")
	testing.expect(t, errors > 0)
	testing.expect_value(t, len(w.workspace.tabs), 2)
	testing.expect(t, app.selected_tab(w.workspace) == source)
	testing.expect_value(t, layout.pane_count(&source.tree), 2)
	testing.expect(t, layout.find_content(&source.tree, content) != layout.INVALID_NODE)
	testing.expect_value(t, len(s.windows), 1)
	testing.expect_value(t, len(s.workspaces), 1)
	testing.expect(t, app.session_find(s, content.id) != nil)
}
