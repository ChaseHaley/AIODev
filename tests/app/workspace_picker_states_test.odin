package app_test

import app "../../src"
import "aio:layout"
import "aio:platform"
import "core:testing"

@(private="file")
picker_fixture :: proc(t: ^testing.T, state: ^app.App, w: ^app.Window) -> bool {
	for _ in 0..<3 {
		workspace := app.workspace_create_empty(state)
		if !testing.expect(t, workspace != nil) {return false}
		tab := new(app.Tab)
		if !testing.expect_value(t, layout.init(&tab.tree, {.Settings, 0}), nil) {free(tab); return false}
		append(&workspace.tabs, tab)
	}
	w^ = {id = 1, width = 800, height = 600, scale = 1, workspace = state.workspaces[0]}
	append(&state.windows, w)
	return true
}

@(private="file")
picker_destroy :: proc(state: ^app.App, w: ^app.Window) {
	app.workspace_picker_destroy(w)
	delete(w.rename.bytes)
	for workspace in state.workspaces {app.workspace_destroy(workspace)}
	delete(state.workspaces)
	delete(state.windows)
}

// A move target belongs to the list it was opened in: opening the picker again, or the icon grid and
// coming back, offers workspaces to switch to.
@(test)
workspace_picker_reopen_and_icon_return_drop_a_move_target :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer picker_destroy(&state, &w)
	if !picker_fixture(t, &state, &w) {return}
	p := &w.workspace_picker
	app.workspace_move_open(&state, &w, true, 0)
	_, moving := app.workspace_picker_move(p)
	if !testing.expect(t, moving) {return}
	testing.expect_value(t, app.workspace_picker_count(&w), len(p.rows) + 1)
	app.workspace_picker_open(&state, &w)
	_, moving = app.workspace_picker_move(p)
	testing.expect(t, !moving && app.workspace_picker_browsing(p))
	testing.expect_value(t, len(p.rows), 3)
	testing.expect_value(t, app.workspace_picker_count(&w), len(p.rows) + len(app.WORKSPACE_ACTIONS))

	app.workspace_move_open(&state, &w, true, 0)
	app.workspace_icon_open(&state, &w)
	app.workspace_picker_key(&state, &w, {key = .Escape, pressed = true})
	testing.expect_value(t, app.workspace_picker_mode(p), app.Workspace_Picker_Mode.List)
	_, moving = app.workspace_picker_move(p)
	testing.expect(t, !moving)
	testing.expect_value(t, len(p.rows), 3)
}

// The chip's double-click compares with the press that opened the list. A press kept from an earlier
// opening used to turn a later chip press, on a list opened another way, into naming the workspace.
@(test)
workspace_chip_double_click_needs_the_press_that_opened_the_list :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	defer picker_destroy(&state, &w)
	if !picker_fixture(t, &state, &w) {return}
	chip := app.workspace_button_rect(&w)
	x, y := i32(chip.x + chip.width / 2), i32(chip.y + chip.height / 2)
	press :: proc(state: ^app.App, w: ^app.Window, x, y: i32, time_ns: i64) {
		app.handle_event(state, platform.Mouse_Button_Event{window = w.id, button = .Left, pressed = true,
			x = x, y = y, time_ns = time_ns})
		app.handle_event(state, platform.Mouse_Button_Event{window = w.id, button = .Left, x = x, y = y,
			time_ns = time_ns})
	}
	press(&state, &w, x, y, 1_000_000_000)
	if !testing.expect(t, app.workspace_picker_active(&w.workspace_picker)) {return}
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
	app.handle_event(&state, platform.Key_Event{window = w.id, key = .Escape})
	app.workspace_picker_open(&state, &w)
	press(&state, &w, x, y, 1_100_000_000)
	testing.expect(t, !app.rename_shown(&w))
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))

	press(&state, &w, x, y, 2_000_000_000)
	testing.expect(t, app.workspace_picker_active(&w.workspace_picker))
	press(&state, &w, x, y, 2_100_000_000)
	_, chip_name := w.overlay.(app.Overlay_Chip_Name)
	testing.expect(t, chip_name)
	testing.expect(t, !app.workspace_picker_active(&w.workspace_picker))
}
