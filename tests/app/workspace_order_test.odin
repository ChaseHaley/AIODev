package app_test

import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:ui"
import "core:encoding/json"
import "core:testing"

@(private="file")
order_fixture :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window) -> bool {
	for _ in 0..<4 {
		workspace := app.workspace_create_empty(state)
		if !testing.expect(t, workspace != nil) {return false}
		tab := new(app.Tab)
		if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {free(tab); return false}
		append(&workspace.tabs, tab)
	}
	w^ = {id = 1, width = 800, height = 600, scale = 1, workspace = state.workspaces[0]}
	append(&state.windows, w)
	app.workspace_picker_open(state, w)
	return true
}

@(private="file")
order_destroy :: proc(state: ^app.App, w: ^app.Window) {
	app.workspace_picker_destroy(w)
	for workspace in state.workspaces {app.workspace_destroy(workspace)}
	delete(state.workspaces)
	delete(state.windows)
}

@(test)
workspace_order_keeps_identity_selection_filters_and_saved_order :: proc(t: ^testing.T) {
	state: app.App
	w, other: app.Window
	defer order_destroy(&state, &w)
	defer app.workspace_picker_destroy(&other)
	if !order_fixture(t, &state, &w) {return}
	active, tab := w.workspace, w.workspace.tabs[0]
	other = {id = 2, width = 800, height = 600, scale = 1, workspace = state.workspaces[1]}
	append(&state.windows, &other)
	app.workspace_picker_open(&state, &other)
	app.workspace_picker_select(&w, 2)
	state.workspaces[1].provisional = true
	app.workspace_picker_text(&state, &w, "")
	app.workspace_picker_select(&w, 1)
	testing.expect(t, app.workspace_reorder(&state, 3, 1))
	testing.expect_value(t, state.workspaces[0].id, u32(3))
	testing.expect_value(t, state.workspaces[1].id, u32(1))
	testing.expect_value(t, state.workspaces[2].id, u32(2))
	testing.expect_value(t, app.workspace_index(&state, 0).id, u32(3))
	testing.expect_value(t, w.workspace_picker.rows[w.workspace_picker.selected].id, u32(3))
	testing.expect_value(t, other.workspace_picker.rows[0].id, u32(3))
	testing.expect_value(t, w.workspace, active)
	testing.expect_value(t, w.workspace.tabs[0], tab)
	testing.expect_value(t, app.workspace_order_neighbor(&state, 3, -1), u32(0))
	testing.expect_value(t, app.workspace_order_neighbor(&state, 1, 1), u32(4))
	testing.expect(t, !app.workspace_reorder(&state, 2, 1))
	testing.expect(t, !app.workspace_reorder(&state, 3, 3))
	testing.expect(t, !app.workspace_reorder(&state, 3, 99))
	text, ok := app.layout_state_encode(&state, context.temp_allocator)
	if !testing.expect(t, ok) {return}
	saved: app.Layout_State
	if !testing.expect_value(t, json.unmarshal(transmute([]u8)text, &saved,
		allocator = context.temp_allocator), nil) {return}
	testing.expect_value(t, saved.workspaces[0].name, state.workspaces[0].name)
	testing.expect_value(t, saved.workspaces[1].name, active.name)
	// A filter hides intermediate entries but still moves the original live records.
	app.workspace_picker_text(&state, &w, state.workspaces[3].name)
	testing.expect_value(t, len(w.workspace_picker.rows), 1)
	testing.expect(t, app.workspace_reorder(&state, 4, 3))
	testing.expect_value(t, len(w.workspace_picker.rows), 1)
	testing.expect_value(t, w.workspace_picker.rows[0].id, u32(4))
	testing.expect_value(t, state.workspaces[0].id, u32(4))
	testing.expect_value(t, state.workspaces[3].id, u32(2))
}

@(test)
workspace_order_drag_commits_on_release_and_cancel_preserves_order :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer order_destroy(&state, &w)
	if !order_fixture(t, &state, &w) {return}
	for scale in ([?]f32{1, 1.5, 2}) {
		w.scale = scale
		first := app.workspace_picker_row_rect(&w, 0)
		last := app.workspace_picker_row_rect(&w, 3)
		x, y, end_y := i32(first.x + 40 * scale), i32(first.y + first.height / 2), i32(last.y + last.height / 2)
		for cancel in ([?]bool{true, false}) {
			app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left,
				pressed = true, x = x, y = y})
			app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = x, y = end_y, buttons = {.Left}})
			testing.expect(t, w.workspace_picker.order.active)
			testing.expect_value(t, state.workspaces[0].id, u32(1))
			if cancel {
				app.handle_event(&state, platform.Capture_Lost_Event{window = w.id})
			}
			app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, x = x, y = end_y})
			testing.expect_value(t, state.workspaces[0].id, cancel ? u32(1) : u32(2))
			testing.expect_value(t, w.workspace.id, u32(1))
			testing.expect_value(t, w.workspace_picker.order.id, u32(0))
			testing.expect(t, app.workspace_picker_active(&w.workspace_picker))
		}
		testing.expect(t, app.workspace_reorder(&state, 1, 2))
	}
	// Row menu keyboard access moves the same workspace and disables at the boundary.
	app.workspace_row_menu_open(&state, &w, 1)
	w.workspace_picker.menu_selected = 4
	app.workspace_picker_key(&state, &w, {key = .Enter, pressed = true})
	testing.expect_value(t, state.workspaces[1].id, u32(1))
	app.workspace_row_menu_open(&state, &w, 1)
	w.workspace_picker.menu_selected = 3
	app.workspace_picker_key(&state, &w, {key = .Enter, pressed = true})
	testing.expect_value(t, state.workspaces[0].id, u32(1))
	testing.expect_value(t, ui.field_string(&w.workspace_picker.query), "")
}
