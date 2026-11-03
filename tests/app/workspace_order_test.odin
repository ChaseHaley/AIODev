package app_test

import app "../../src"
import "aio:layout"
import "aio:platform"
import "aio:ui"
import "core:encoding/json"
import "core:testing"
import "core:time"

@(test)
workspace_order_grabbed_row_follows_pointer_instead_of_a_drop_line :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer order_destroy(&state, &w)
	if !order_fixture(t, &state, &w) {return}
	state.animations = true
	row := app.workspace_picker_row_rect(&w, 0)
	x, y := i32(row.x + 40), i32(row.y + row.height / 2)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left,
		pressed = true, x = x, y = y})
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = x,
		y = y + 40, buttons = {.Left}})
	testing.expect_value(t, app.workspace_picker_row_rect(&w, 0).y, row.y + 40)
	neighbour := app.workspace_order_position(&w.workspace_picker, 2)
	if !testing.expect(t, neighbour != nil) {return}
	testing.expect_value(t, neighbour.position.target, f32(0))
	testing.expect_value(t, neighbour.position.duration, 140 * time.Millisecond)
	testing.expect_value(t, neighbour.position.easing, ui.Easing.Decelerate)
	started := neighbour.position.started
	_ = app.workspace_order_animate(&w, true, time.tick_add(started, 70 * time.Millisecond))
	testing.expect(t, neighbour.position.value > 0 && neighbour.position.value < 1)
	testing.expect_value(t, app.workspace_picker_row_rect(&w, 0).y, row.y + 40)
	testing.expect(t, app.workspace_order_lifted(&w.workspace_picker, 0))
	testing.expect_value(t, app.workspace_picker_hit(&w, f32(x), f32(y + 40)), 0)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left,
		x = x, y = y + 40})
	testing.expect_value(t, state.workspaces[1].id, u32(1))
	grabbed := app.workspace_order_position(&w.workspace_picker, 1)
	if !testing.expect(t, grabbed != nil) {return}
	testing.expect(t, grabbed.lifted)
	testing.expect_value(t, grabbed.position.value, f32(1.25))
	testing.expect_value(t, grabbed.position.target, f32(1))
	testing.expect_value(t, grabbed.position.duration, 140 * time.Millisecond)
	testing.expect_value(t, grabbed.position.easing, ui.Easing.Decelerate)
	app.workspace_row_menu_open(&state, &w, 1)
	testing.expect_value(t, len(w.workspace_picker.order_positions), 4)
	testing.expect_value(t, app.workspace_picker_row_rect(&w, 1).y, row.y + 40)
	started = grabbed.position.started
	_ = app.workspace_order_animate(&w, true, time.tick_add(started, 70 * time.Millisecond))
	testing.expect(t, grabbed.position.value > 1 && grabbed.position.value < 1.25)
	_ = app.workspace_order_animate(&w, true, time.tick_add(started, 140 * time.Millisecond))
	testing.expect_value(t, len(w.workspace_picker.order_positions), 0)
	testing.expect(t, !app.workspace_order_animating(&w.workspace_picker))
}

@(private="file")
order_fixture :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window, count := 4) -> bool {
	for _ in 0..<count {
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

@(private="file")
order_scrolled_drop :: proc(t: ^testing.T, enabled: bool) {
	state: app.App
	w: app.Window
	defer order_destroy(&state, &w)
	if !order_fixture(t, &state, &w, 20) {return}
	state.animations = enabled
	w.height = 240
	w.workspace_picker.selected, w.workspace_picker.scroll = 6, 5
	app.workspace_picker_layout_changed(&w)
	row := app.workspace_picker_row_rect(&w, 6)
	x, y := i32(row.x + 40), i32(row.y + row.height / 2)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left,
		pressed = true, x = x, y = y})
	app.handle_event(&state, platform.Mouse_Move_Event{window = w.id, x = x,
		y = y + 37, buttons = {.Left}})
	before := app.workspace_picker_row_rect(&w, 6)
	app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left,
		x = x, y = y + 37})
	testing.expect_value(t, w.workspace_picker.scroll, 5)
	testing.expect_value(t, state.workspaces[7].id, u32(7))
	after := app.workspace_picker_row_rect(&w, 7)
	testing.expect_value(t, after.y, enabled ? before.y : row.y + row.height)
}

@(test)
workspace_order_drop_keeps_scrolled_viewport_and_settlement_continuous :: proc(t: ^testing.T) {
	order_scrolled_drop(t, true)
	order_scrolled_drop(t, false)
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
			testing.expect_value(t, app.workspace_picker_row_rect(&w, 1).y, first.y)
			testing.expect_value(t, app.workspace_picker_row_rect(&w, 0).y, last.y)
			testing.expect_value(t, state.workspaces[0].id, u32(1))
			if cancel {
				app.handle_event(&state, platform.Capture_Lost_Event{window = w.id})
			}
			app.handle_event(&state, platform.Mouse_Button_Event{window = w.id, button = .Left, x = x, y = end_y})
			testing.expect_value(t, state.workspaces[0].id, cancel ? u32(1) : u32(2))
			testing.expect_value(t, w.workspace.id, u32(1))
			testing.expect_value(t, w.workspace_picker.order.id, u32(0))
			testing.expect_value(t, len(w.workspace_picker.order_positions), 0)
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
