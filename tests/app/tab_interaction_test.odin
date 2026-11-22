package app_test

import app "../../src"
import "cosmos:input"
import "cosmos:platform"
import "cosmos:render"
import "aio:term"
import "aio:views"
import "core:testing"
import "cosmos:ui"

@(private="file")
interaction_rect :: proc(s: ^app.App, w: ^app.Window, index: int, close := false) -> render.Rect {
	if w.tabs_horizontal {
		if close {return app.window_tab_close_rect(s, w, index)}
		return app.window_tab_rect(s, w, index)
	}
	if close {
		l, ok := app.rail_current_layout(w)
		if !ok {return {}}
		return views.rail_close_rect(l, index, w.scale)
	}
	return app.rail_row_rect_for_tab(w, index)
}

@(private="file")
interaction_button :: proc(s: ^app.App, id: input.Window_Id, r: render.Rect,
	button: input.Mouse_Button, pressed: bool, modifiers: input.Modifiers = {}) {
	app.handle_event(s, input.Mouse_Button_Event{window = id, button = button, pressed = pressed,
		x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2), modifiers = modifiers})
}

@(private="file")
interaction_click :: proc(s: ^app.App, w: ^app.Window, index: int, modifiers: input.Modifiers = {}) {
	r := interaction_rect(s, w, index)
	id := w.id
	for pressed in ([?]bool{true, false}) {interaction_button(s, id, r, .Left, pressed, modifiers)}
}

@(private="file")
interaction_placement :: proc(s: ^app.App, w: ^app.Window, horizontal: bool) {
	w.tabs_horizontal = horizontal
	w.width, w.height, w.scale = 1000, 700, 1
	w.rail_wide, w.rail = true, app.Rail_Docked{}
	app.window_relayout(s, w)
	app.update_motion(s)
}

@(private="file")
interaction_marks :: proc(t: ^testing.T, w: ^app.Window, expected: [3]bool) {
	for tab, i in w.workspace.tabs {testing.expect_value(t, tab.marked, expected[i])}
}

@(test)
tab_interaction_selection_context_and_drag_use_both_geometry_adapters :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{false, true}) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "tab-interaction", "profile.default.command = cmd.exe\n") {return}
		s, w := &f.state, f.state.windows[0]
		interaction_placement(s, w, horizontal)
		app.tab_new(s, w)
		app.tab_new(s, w)
		app.tab_select(s, w, 0)
		app.update_motion(s)
		interaction_click(s, w, 1, {.Control})
		interaction_marks(t, w, {true, true, false})
		interaction_click(s, w, 2, {.Shift})
		interaction_marks(t, w, {false, true, true})
		interaction_click(s, w, 0, {.Control, .Shift})
		interaction_marks(t, w, {true, true, true})
		interaction_click(s, w, 1, {.Control})
		interaction_marks(t, w, {true, false, true})
		testing.expect(t, !app.drag_held(w))
		r := interaction_rect(s, w, 0)
		selected := w.workspace.selected
		interaction_button(s, w.id, r, .Right, true)
		testing.expect(t, app.tab_menu_shown(w))
		interaction_marks(t, w, {true, false, true})
		testing.expect_value(t, w.workspace.selected, selected)
		interaction_button(s, w.id, r, .Right, false)
		app.handle_event(s, input.Key_Event{window = w.id, key = .Escape, pressed = true})
		interaction_button(s, w.id, r, .Left, true)
		pressed, held := w.drag.(app.Drag_Pressed)
		testing.expect(t, held && !pressed.grab.(app.Tab_Grab).modified)
		interaction_marks(t, w, {true, false, true})
		interaction_button(s, w.id, r, .Left, false)
		interaction_marks(t, w, {true, false, false})
		grabbed := w.workspace.tabs[0]
		interaction_button(s, w.id, r, .Left, true)
		target := interaction_rect(s, w, 2)
		app.handle_event(s, input.Mouse_Move_Event{window = w.id, buttons = {.Left},
			x = i32(target.x + target.width / 2), y = i32(target.y + target.height / 2)})
		testing.expect(t, app.tab_drag_active(w))
		testing.expect(t, w.workspace.tabs[2] == grabbed)
		app.handle_event(s, platform.Capture_Lost_Event{w.id})
		testing.expect(t, !app.drag_held(w) && w.workspace.tabs[0] == grabbed)
		interaction_button(s, w.id, target, .Left, false)
		testing.expect(t, w.workspace.tabs[0] == grabbed)
	}
}

@(test)
tab_interaction_close_requires_matching_uncancelled_left_release_in_both_adapters :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{false, true}) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "tab-interaction-close", "profile.default.command = cmd.exe\n") {return}
		s, w := &f.state, f.state.windows[0]
		interaction_placement(s, w, horizontal)
		app.tab_new(s, w)
		app.tab_new(s, w)
		app.tab_select(s, w, 0)
		app.update_motion(s)
		one, two := interaction_rect(s, w, 0, true), interaction_rect(s, w, 1, true)
		interaction_button(s, w.id, one, .Left, true)
		testing.expect(t, ui.armed_is(w.tab_close_armed, w.workspace.tabs[0].id))
		interaction_button(s, w.id, two, .Left, false)
		interaction_button(s, w.id, one, .Left, false)
		testing.expect_value(t, len(w.workspace.tabs), 3)
		for focus_loss in ([?]bool{false, true}) {
			interaction_button(s, w.id, one, .Left, true)
			if focus_loss {app.handle_event(s, platform.Focus_Event{w.id, false})}
			else {app.handle_event(s, platform.Capture_Lost_Event{w.id})}
			interaction_button(s, w.id, one, .Left, false)
			testing.expect(t, !ui.armed_down(w.tab_close_armed))
			testing.expect_value(t, len(w.workspace.tabs), 3)
		}
		interaction_button(s, w.id, two, .Left, true)
		interaction_button(s, w.id, two, .Right, false)
		testing.expect(t, ui.armed_is(w.tab_close_armed, w.workspace.tabs[1].id))
		interaction_button(s, w.id, two, .Left, false)
		testing.expect_value(t, len(w.workspace.tabs), 2)
		app.update_motion(s)
		remaining := w.workspace.tabs[1]
		interaction_button(s, w.id, interaction_rect(s, w, 0), .Middle, true)
		testing.expect_value(t, len(w.workspace.tabs), 1)
		testing.expect(t, w.workspace.tabs[0] == remaining)
	}
}

@(test)
tab_interaction_overlay_selection_dismisses_without_arming_reorder :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	if !profile_fixture_create(t, &f, "tab-interaction-overlay", "profile.default.command = cmd.exe\n") {return}
	s, w := &f.state, f.state.windows[0]
	interaction_placement(s, w, false)
	app.tab_new(s, w)
	app.tab_select(s, w, 0)
	w.width, w.rail_wide = 600, false
	rail_show(w)
	r := interaction_rect(s, w, 1)
	interaction_button(s, w.id, r, .Left, true, {.Control})
	testing.expect(t, w.workspace.tabs[0].marked && w.workspace.tabs[1].marked)
	testing.expect(t, !app.rail_visible(w) && !app.drag_held(w))
	interaction_button(s, w.id, r, .Left, false)
	rail_show(w)
	interaction_button(s, w.id, r, .Right, true)
	testing.expect(t, app.tab_menu_shown(w) && !app.rail_visible(w))
	interaction_button(s, w.id, r, .Right, false)
	app.handle_event(s, input.Key_Event{window = w.id, key = .Escape, pressed = true})
	app.tab_select(s, w, 0)
	rail_show(w)
	close := interaction_rect(s, w, 1, true)
	interaction_button(s, w.id, close, .Left, true)
	interaction_button(s, w.id, {}, .Left, false)
	testing.expect(t, !app.rail_visible(w) && len(w.workspace.tabs) == 2)
}

@(test)
tab_interaction_final_close_can_retire_the_event_window_in_both_adapters :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{false, true}) {
		for button in ([?]input.Mouse_Button{.Left, .Middle}) {
			f: Profile_Fixture
			defer profile_fixture_destroy(t, &f)
			if !profile_fixture_create(t, &f, "tab-interaction-lifetime", "profile.default.command = cmd.exe\n") {return}
			s, survivor := &f.state, f.state.windows[0]
			pid := term.process_id(app.focused_session(s, survivor).session)
			app.workspace_new(s, survivor, true)
			app.rename_finish(s, survivor, true)
			w := s.windows[1]
			interaction_placement(s, w, horizontal)
			app.tab_new(s, w)
			for tab in w.workspace.tabs {tab.marked = true}
			app.update_motion(s)
			id, workspace_id := w.id, w.workspace.id
			r := interaction_rect(s, w, 0, button == .Left)
			for pressed in ([?]bool{true, false}) {interaction_button(s, id, r, button, pressed)}
			testing.expect(t, app.window_find(s, id) == nil && app.workspace_find(s, workspace_id) == nil)
			testing.expect_value(t, len(s.windows), 1)
			testing.expect_value(t, term.process_id(app.focused_session(s, survivor).session), pid)
			interaction_placement(s, survivor, horizontal)
			id = survivor.id
			r = interaction_rect(s, survivor, 0, button == .Left)
			for pressed in ([?]bool{true, false}) {interaction_button(s, id, r, button, pressed)}
			testing.expect(t, s.run == .Quit && len(s.windows) == 0 && len(s.workspaces) == 0 && len(s.sessions) == 0)
		}
	}
}

// The tab under the pointer stays hovered and pressed while it is dragged to another slot and after the drop;
// the tab sliding into the slot it left takes neither its highlight nor its hover motion.
@(test)
tab_hover_and_press_stay_with_the_dragged_tab_in_both_adapters :: proc(t: ^testing.T) {
	for horizontal in ([?]bool{true, false}) {
		f: Profile_Fixture
		defer profile_fixture_destroy(t, &f)
		if !profile_fixture_create(t, &f, "tab-hover-identity", "profile.default.command = cmd.exe\n") {return}
		s, w := &f.state, f.state.windows[0]
		interaction_placement(s, w, horizontal)
		app.tab_new(s, w)
		app.tab_new(s, w)
		app.tab_select(s, w, 0)
		app.update_motion(s)
		grabbed, neighbour := w.workspace.tabs[0], w.workspace.tabs[1]
		r := interaction_rect(s, w, 0)
		x, y := i32(r.x + r.width / 2), i32(r.y + r.height / 2)
		app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = x, y = y})
		app.update_motion(s)
		testing.expect(t, app.tab_hovered(w, 0))
		if horizontal {testing.expect_value(t, app.tab_motion(w, 0).hover.value, f32(1))}
		s.animations = true
		app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, pressed = true, x = x, y = y})
		if horizontal {x += i32(1.25 * r.width)} else {y += i32(1.25 * r.height)}
		app.handle_event(s, input.Mouse_Move_Event{window = w.id, buttons = {.Left}, x = x, y = y})
		if !testing.expect(t, app.tab_drag_active(w)) {return}
		if !testing.expect(t, w.workspace.tabs[1] == grabbed && w.workspace.tabs[0] == neighbour) {return}
		app.update_motion(s)
		// Mid-drag: the grabbed tab, now second, keeps the hover and the press; the neighbour in its old slot
		// shows neither and its hover motion does not start.
		testing.expect(t, app.tab_hovered(w, 1) && app.tab_pressed(w, 1))
		testing.expect(t, !app.tab_hovered(w, 0) && !app.tab_pressed(w, 0))
		if horizontal {
			testing.expect_value(t, app.tab_motion(w, 1).hover.target, f32(1))
			testing.expect_value(t, app.tab_motion(w, 1).press.target, f32(1))
			testing.expect_value(t, app.tab_motion(w, 0).hover.target, f32(0))
			testing.expect_value(t, app.tab_motion(w, 0).hover.value, f32(0))
		}
		app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = .Left, x = x, y = y})
		testing.expect(t, !app.drag_held(w) && w.workspace.tabs[1] == grabbed)
		s.animations = false
		app.update_motion(s)
		// After the drop, before and after the pointer moves again.
		testing.expect(t, app.tab_hovered(w, 1) && !app.tab_hovered(w, 0))
		if horizontal {
			testing.expect_value(t, app.tab_motion(w, 1).hover.value, f32(1))
			testing.expect_value(t, app.tab_motion(w, 0).hover.value, f32(0))
		}
		app.handle_event(s, input.Mouse_Move_Event{window = w.id, x = x, y = y})
		app.update_motion(s)
		testing.expect(t, app.tab_hovered(w, 1) && !app.tab_hovered(w, 0))
		if horizontal {testing.expect_value(t, app.tab_motion(w, 1).hover.value, f32(1))}
	}
}
