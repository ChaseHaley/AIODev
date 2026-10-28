package app_test

import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:render"
import "core:testing"

@(private="file")
creation_click :: proc(s: ^app.App, w: ^app.Window, r: render.Rect, button: input.Mouse_Button) {
	for pressed in ([?]bool{true, false}) {
		app.handle_event(s, platform.Mouse_Button_Event{window = w.id, button = button, pressed = pressed,
			x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2)})
	}
}

@(test)
tab_creation_controls_share_profiles_and_default_launch_in_both_orientations :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	text :: `profile.default.command = cmd.exe
profile.cmd.name = Command Prompt
profile.cmd.command = cmd.exe
profile.cmd.directory = ~
profile.hidden.name = Hidden
profile.hidden.command = cmd.exe
profile.hidden.hidden = true
profile.order = default, cmd, hidden
`
	if !profile_fixture_create(t, &f, "tab-creation", text) {return}
	s, w := &f.state, f.state.windows[0]
	for horizontal in ([?]bool{false, true}) {
		w.tabs_horizontal = horizontal
		w.rail_override = .Shown
		count := len(w.workspace.tabs)
		chevron := horizontal ? app.tab_chevron_rect(s, w) : app.rail_profile_rect(w)
		creation_click(s, w, chevron, .Left)
		if !testing.expect(t, w.profile_menu.open) {return}
		testing.expect_value(t, w.rail_pressed, -1)
		testing.expect_value(t, len(w.workspace.tabs), count)
		testing.expect_value(t, w.profile_menu.mode, app.Profile_Menu_Mode.New_Tab)
		cmd := -1
		for entry, i in w.profile_menu.entries[:w.profile_menu.count] {
			testing.expect(t, entry.profile_id != "hidden")
			if entry.profile_id == "cmd" {cmd = i}
		}
		if !testing.expect(t, cmd >= 0) {return}
		w.profile_menu.selected = cmd
		app.handle_event(s, platform.Key_Event{window = w.id, key = .Enter, pressed = true})
		testing.expect(t, !w.profile_menu.open)
		testing.expect_value(t, len(w.workspace.tabs), count + 1)
		testing.expect_value(t, app.focused_session(s, w).profile_id, "cmd")
		if !horizontal {testing.expect(t, !app.rail_overlay(w))}

		w.rail_override = .Shown
		plus := horizontal ? app.window_tab_new_rect(s, w) : app.rail_new_tab_rect(w)
		creation_click(s, w, plus, .Right)
		testing.expect(t, w.profile_menu.open)
		testing.expect_value(t, len(w.workspace.tabs), count + 1)
		app.handle_event(s, platform.Key_Event{window = w.id, key = .Escape, pressed = true})
		testing.expect(t, !w.profile_menu.open)
		testing.expect_value(t, w.rail_pressed, -1)
		creation_click(s, w, plus, .Left)
		testing.expect_value(t, len(w.workspace.tabs), count + 2)
		testing.expect_value(t, app.focused_session(s, w).profile_id, "default")
	}
}
