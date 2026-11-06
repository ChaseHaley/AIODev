package app_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import app "../../src"
import "aio:platform"
import "aio:term"
import "aio:ui"

@(test)
pane_drag_dropdown_preserves_runtime_for_each_destination :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "aio-pane-workspace-drag-*", context.allocator)
	if !testing.expect_value(t, err, nil) {return}
	defer delete(directory)
	defer os.remove(directory)
	path := strings.concatenate({directory, "/settings.ini"})
	defer delete(path)
	defer os.remove(path)
	if !testing.expect_value(t, os.write_entire_file(path,
		idle_shell_settings(t, "cursor.blink = false\n")), nil) {return}
	state := app.App{options = {data_dir = directory, inactive = true}}
	state.app_id = fmt.aprintf("AIODev.Test.PaneWorkspaceDrag.%d", os.get_pid())
	defer app.app_destroy(&state)
	if !testing.expect_value(t, platform.init(&state.platform, state.app_id), platform.Init_Result.Primary) {return}
	state.platform_ready = true
	if !testing.expect(t, app.app_init(&state)) {return}
	w := state.windows[0]
	for destination in 0 ..< 3 {
		app.run_action(&state, w, .Split_Right)
		source := w.workspace
		tab := app.selected_tab(source)
		node := tab.tree.focus
		runtime := app.focused_session(&state, w).session
		pid := term.process_id(runtime)
		count := len(state.sessions)
		if destination == 0 {
			if !testing.expect(t, app.workspace_create_empty(&state) != nil) {return}
		}
		app.pane_drag_press(&state, w, node, 400, 200)
		chip := app.workspace_button_rect(w)
		app.handle_event(&state, platform.Mouse_Move_Event{window = w.id,
			x = i32(chip.x + chip.width / 2), y = i32(chip.y + chip.height / 2), buttons = {.Left}})
		if !testing.expect(t, w.pane_drag.active && w.workspace_picker.drag) {return}
		testing.expect_value(t, app.workspace_picker_count(w), len(w.workspace_picker.rows) + 2)
		index := destination == 0 ? 0 : len(w.workspace_picker.rows) + destination - 1
		row := app.workspace_picker_row_rect(w, index)
		point := [2]i32{i32(row.x + row.width / 2), i32(row.y + row.height / 2)}
		app.handle_event(&state, platform.Mouse_Move_Event{window = w.id,
			x = point.x, y = point.y, buttons = {.Left}})
		testing.expect_value(t, w.workspace_picker.selected, index)
		app.handle_event(&state, platform.Mouse_Button_Event{window = w.id,
			x = point.x, y = point.y, button = .Left, pressed = false})
		testing.expect(t, !w.pane_drag.active && !app.workspace_picker_active(&w.workspace_picker))
		owner := destination == 2 ? state.windows[len(state.windows) - 1] : w
		// A new destination exists at once, with its suggested name open for editing in its own chip.
		if destination != 0 {
			testing.expect(t, app.chip_name_shown(owner))
			testing.expect_value(t, ui.field_selected_text(&owner.rename), owner.workspace.name)
			app.rename_finish(&state, owner, true)
		}
		testing.expect(t, owner.workspace != source)
		testing.expect_value(t, app.focused_session(&state, owner).session, runtime)
		testing.expect_value(t, term.process_id(runtime), pid)
		testing.expect_value(t, len(state.sessions), count)
		testing.expect_value(t, app.tab_pane_count(tab), 1)
	}
}

