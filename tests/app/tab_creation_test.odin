package app_test

import app "../../src"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:testing"

@(test)
profile_menu_matches_configured_settings_rows :: proc(t: ^testing.T) {
	s: app.App
	parsed, diagnostics, err := settings.parse(`profile.default.directory = ~/Projects/AIODev
profile.cmd.name = Command Prompt
profile.cmd.command = cmd.exe
profile.windows-powershell.name = Windows PowerShell
profile.windows-powershell.command = powershell.exe -NoLogo
profile.hidden.command = cmd.exe
profile.hidden.hidden = true
profile.order = default, cmd, windows-powershell, pwsh, hidden
`)
	if !testing.expect_value(t, err, nil) {return}
	s.settings = parsed
	defer settings.destroy(&s.settings)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, settings.profile_detect(
		&s.settings, {"pwsh", "PowerShell 7", "pwsh.exe -NoLogo", "~"},
	), nil)
	table, table_error := ui.profile_table_build(&s.settings.profiles)
	if !testing.expect_value(t, table_error, nil) {return}
	defer ui.profile_table_destroy(&table)
	testing.expect_value(t, len(table.rows), 4)
	testing.expect_value(t, len(table.detected), 0)
	w: app.Window
	app.profile_menu_init(&w.profile_menu)
	defer app.profile_menu_destroy(&w.profile_menu)
	for mode in ([?]app.Profile_Menu_Mode{.New_Tab, .Swap_Pane}) {
		app.profile_menu_open(&s, &w, mode, 0, 0)
		expected := 0
		for row in table.rows {
			if row.hidden || row.command == "" {continue}
			if !testing.expect(t, expected < w.profile_menu.count) {return}
			entry := w.profile_menu.entries[expected]
			testing.expect_value(t, entry.profile_id, row.id)
			testing.expect_value(t, entry.visible_index, expected)
			testing.expect_value(t, w.profile_menu.items[expected].label, row.name)
			expected += 1
		}
		testing.expect_value(t, w.profile_menu.count, expected + (mode == .New_Tab ? 0 : 3))
	}
}

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
