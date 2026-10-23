package app_test

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:commands"
import "aio:platform"
import "aio:term"
import "aio:ui"

_ :: log

@(test)
workspace_empty_factory_preserves_ids_and_ownership :: proc(t: ^testing.T) {
	state: app.App
	defer delete(state.workspaces)
	one := app.workspace_create_empty(&state)
	if !testing.expect(t, one != nil) { return }
	testing.expect_value(t, one.id, u32(1))
	testing.expect_value(t, one.name, "Workspace 1")
	testing.expect_value(t, len(one.tabs), 0)
	testing.expect_value(t, len(state.sessions), 0)
	testing.expect(t, app.workspace_discard_empty(&state, one))
	two := app.workspace_create_empty(&state)
	if !testing.expect(t, two != nil) { return }
	defer testing.expect(t, app.workspace_discard_empty(&state, two))
	testing.expect_value(t, two.id, u32(2))
	testing.expect_value(t, two.name, "Workspace 2")
	owner := app.Window{workspace = two}
	append(&state.windows, &owner)
	testing.expect(t, !app.workspace_discard_empty(&state, two))
	clear(&state.windows)
	delete(state.windows)
	allocator := context.allocator
	context.allocator = runtime.nil_allocator()
	failed := app.workspace_create_empty(&state)
	context.allocator = allocator
	testing.expect(t, failed == nil)
	testing.expect_value(t, state.next_workspace_id, u32(2))
	testing.expect_value(t, len(state.workspaces), 1)
	state.next_workspace_id = max(u32)
	testing.expect(t, app.workspace_create_empty(&state) == nil)
	testing.expect(t, !app.workspace_discard_empty(&state, nil))
}

@(test)
workspace_controls_switch_hidden_runtimes_and_activate_owners :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "aio-workspaces-*", context.allocator)
	if !testing.expect_value(t, directory_error, nil) { return }
	defer delete(directory)
	defer testing.expect_value(t, os.remove(directory), nil)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	settings :: "shell.command = pwsh.exe -NoLogo -NoProfile\ncursor.blink = false\n"
	if !testing.expect_value(t, os.write_entire_file(path, settings), nil) { return }
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.Workspaces.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {
		return
	}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) { return }
	w := state.windows[0]
	original := w.workspace
	first_session := state.sessions[0].session
	first_pid := term.process_id(first_session)
	testing.expect(t, first_pid != 0)
	testing.expect_value(t, original.id, u32(1))
	for name in ([?]string{"workspace.new", "workspace.change", "workspace.rename", "window.new"}) {
		testing.expect(t, commands.find(&state.registry, name) != nil)
	}
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = 12, y = 20})
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker))
	app.handle_event(&state, platform.Text_Event{window = w.id, text = "missing"})
	testing.expect_value(t, len(w.workspace_picker.rows), 0)
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "missing")
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))
	app.run_action(&state, w, .New_Workspace)
	if !testing.expect_value(t, len(state.workspaces), 2) { return }
	if !testing.expect_value(t, len(state.sessions), 2) { return }
	two := w.workspace
	testing.expect(t, two != original)
	testing.expect_value(t, two.id, u32(2))
	testing.expect_value(t, len(state.windows), 1)
	testing.expect_value(t, term.process_id(first_session), first_pid)
	testing.expect(t, !app.workspace_discard_empty(&state, original))
	app.run_action(&state, w, .Rename_Workspace)
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker) && app.workspace_picker_target(&w.workspace_picker, .Rename) == two.id && !w.rename_open)
	app.handle_event(&state, platform.Text_Event{window = w.id, text = "  Build tools  "})
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect_value(t, two.name, "Build tools")
	state.sessions[1].status = .Failed
	app.workspace_picker_open(&state, w)
	for row in w.workspace_picker.rows {
		if row.id == two.id { testing.expect_value(t, row.status, "Blocked") }
	}
	state.sessions[1].status = .Exited
	app.workspace_picker_status_changed(&state)
	for row in w.workspace_picker.rows {
		if row.id == two.id { testing.expect_value(t, row.status, "Finished") }
	}
	state.sessions[1].status = .Running
	app.workspace_picker_cancel(w)
	testing.expect_value(t, two.id, u32(2))
	testing.expect(t, app.rename_target_commit(&state, w,
		{app.Rename_Kind.Workspace, two.id}, " \n\t ") == app.Rename_Outcome.Empty)
	testing.expect_value(t, two.name, "Build tools")
	app.run_action(&state, w, .Change_Workspace)
	app.handle_event(&state, platform.Text_Event{window = w.id, text = "WORKSPACE 1"})
	testing.expect_value(t, len(w.workspace_picker.rows), 1)
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
	testing.expect(t, w.workspace == original)
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))
	testing.expect_value(t, term.process_id(first_session), first_pid)
	app.run_action(&state, w, .Settings_UI)
	if !testing.expect(t, app.settings_active(w)) { return }
	settings_tab := app.selected_tab(original)
	bar := app.window_tab_bar(&state, w)
	testing.expect(t, bar.x > 0)
	testing.expect_value(t, app.window_tab_hit(w, bar, bar.x-1, 20*w.scale), -1)
	testing.expect_value(t, app.window_tab_hit(w, bar, bar.x+10*w.scale, 20*w.scale), 0)
	close := ui.tab_close_rect(bar, 1, w.scale)
	testing.expect_value(t, app.window_tab_close_hit(w, bar,
		close.x+close.width/2, close.y+close.height/2), 1)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
		x = i32(bar.x+20*w.scale), y = i32(20*w.scale)})
	testing.expect_value(t, original.selected, 0)
	grabbed := app.selected_tab(original)
	testing.expect(t, app.tab_drag_move(&state, w, bar.x+bar.tab_width+20*w.scale))
	app.tab_drag_release(w)
	testing.expect_value(t, original.selected, 1)
	testing.expect(t, app.selected_tab(original) == grabbed)
	app.tab_select(&state, w, 0)
	testing.expect(t, app.selected_tab(original) == settings_tab)
	if !testing.expect(t, app.workspace_select(&state, w, two)) { return }
	testing.expect(t, !app.settings_active(w))
	testing.expect(t, !w.editor.open)
	if !testing.expect(t, app.workspace_select(&state, w, original)) { return }
	testing.expect(t, app.settings_active(w))
	testing.expect(t, w.editor.open && len(w.editor.rows) > 0)
	testing.expect(t, app.selected_tab(original) == settings_tab)
	panes, controls, positions := raw_data(w.panes), raw_data(w.tab_controls), raw_data(w.tab_positions)
	if !testing.expect(t, app.workspace_select(&state, w, two)) { return }
	testing.expect_value(t, raw_data(w.panes), panes)
	testing.expect_value(t, raw_data(w.tab_controls), controls)
	testing.expect_value(t, raw_data(w.tab_positions), positions)
	testing.expect_value(t, os.remove(path), nil)
	testing.expect(t, !app.workspace_select(&state, w, original))
	testing.expect(t, w.workspace == two && !w.editor.open)
	testing.expect_value(t, os.write_entire_file(path, settings), nil)
	if !testing.expect(t, app.workspace_select(&state, w, original)) { return }
	app.run_action(&state, w, .New_Window)
	if !testing.expect_value(t, len(state.windows), 2) { return }
	other := state.windows[1]
	three := other.workspace
	testing.expect_value(t, three.id, u32(3))
	testing.expect(t, three != original && three != two)
	testing.expect_value(t, len(state.sessions), 3)
	other_session := state.sessions[2].session
	other_pid := term.process_id(other_session)
	testing.expect(t, other_pid != 0 && other_pid != first_pid)
	when #config(AIO_NATIVE_FOCUS, false) {
		state.options.inactive = false
		activated := app.workspace_select(&state, other, original)
		if activated {
			testing.expect(t, platform.window_is_focused(&state.platform, w.id))
			testing.expect(t, !platform.window_is_focused(&state.platform, other.id))
			log.info("workspace picker owner activation succeeded")
		} else { log.info("workspace picker owner activation was denied; ownership preserved") }
		testing.expect(t, other.workspace == three && w.workspace == original)
		state.options.inactive = true
	}
	if !testing.expect(t, app.workspace_select(&state, other, original)) { return }
	testing.expect(t, other.workspace == three && w.workspace == original)
	testing.expect_value(t, len(state.windows), 2)
	testing.expect_value(t, len(state.sessions), 3)
	testing.expect(t, app.selected_tab(original) == settings_tab)
	app.run_action(&state, other, .Change_Workspace)
	app.workspace_picker_text(&state, other, "Build tools")
	r := app.workspace_picker_row_rect(other, 0)
	app.tick(&state)
	app.handle_event(&state, platform.Mouse_Button_Event{window = other.id, button = .Left, pressed = true,
		x = i32(r.x+20*other.scale), y = i32(r.y+17*other.scale)})
	testing.expect(t, other.workspace == two)
	testing.expect(t, app.window_for_workspace(&state, three) == nil)
	testing.expect_value(t, term.process_id(other_session), other_pid)
	app.window_close(&state, other)
	testing.expect_value(t, len(state.windows), 1)
	if !testing.expect(t, app.workspace_select(&state, w, three)) { return }
	testing.expect(t, app.focused_session(&state, w).session == other_session)
	testing.expect_value(t, term.process_id(other_session), other_pid)
	testing.expect_value(t, term.process_id(first_session), first_pid)
	testing.expect_value(t, len(state.sessions), 3)
	app.tick(&state)
}
