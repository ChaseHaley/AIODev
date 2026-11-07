package app_test

import app "../../src"
import "aio:input"
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
	w: app.Window
	app.profile_menu_init(&w.profile_menu)
	defer app.profile_menu_destroy(&w.profile_menu)
	for mode in ([?]app.Profile_Menu_Mode{app.Profile_Menu_New_Tab{}, app.Profile_Menu_Swap_Pane{}}) {
		app.profile_menu_open(&s, &w, mode, 0, 0)
		expected := 0
		for row in table.rows {
			if row.hidden || row.command == "" {continue}
			entry, listed := app.profile_menu_entry(&w.profile_menu, expected)
			if !testing.expect(t, listed) {return}
			testing.expect_value(t, entry.action, app.Profile_Menu_Action.Profile)
			testing.expect_value(t, app.profile_menu_entry_id(&entry), row.id)
			testing.expect_value(t, w.profile_menu.items[expected].label, row.name)
			expected += 1
		}
		_, swap := mode.(app.Profile_Menu_Swap_Pane)
		testing.expect_value(t, len(w.profile_menu.items), expected + (swap ? 3 : 0))
		testing.expect_value(t, w.profile_menu.count, len(w.profile_menu.items))
	}
}

@(private="file")
creation_click :: proc(s: ^app.App, w: ^app.Window, r: render.Rect, button: input.Mouse_Button) {
	for pressed in ([?]bool{true, false}) {
		app.handle_event(s, input.Mouse_Button_Event{window = w.id, button = button, pressed = pressed,
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
		rail_show(w)
		count := len(w.workspace.tabs)
		chevron := horizontal ? app.tab_chevron_rect(s, w) : app.rail_profile_rect(w)
		creation_click(s, w, chevron, .Left)
		if !testing.expect(t, app.profile_menu_shown(w)) {return}
		testing.expect(t, app.gesture_tab_pressed(w) == nil)
		testing.expect_value(t, len(w.workspace.tabs), count)
		shown, _ := w.overlay.(app.Overlay_Profile_Menu)
		_, new_tab := shown.mode.(app.Profile_Menu_New_Tab)
		testing.expect(t, new_tab)
		cmd := -1
		for i in 0 ..< len(w.profile_menu.items) {
			entry, _ := app.profile_menu_entry(&w.profile_menu, i)
			testing.expect(t, app.profile_menu_entry_id(&entry) != "hidden")
			if app.profile_menu_entry_id(&entry) == "cmd" {cmd = i}
		}
		if !testing.expect(t, cmd >= 0) {return}
		ui.menu_select(&w.profile_menu.menu, cmd)
		app.handle_event(s, input.Key_Event{window = w.id, key = .Enter, pressed = true})
		testing.expect(t, !app.profile_menu_shown(w))
		testing.expect_value(t, len(w.workspace.tabs), count + 1)
		testing.expect_value(t, app.focused_session(s, w).profile_id, "cmd")
		if !horizontal {testing.expect(t, !app.rail_overlay(w))}

		rail_show(w)
		plus := horizontal ? app.window_tab_new_rect(s, w) : app.rail_new_tab_rect(w)
		creation_click(s, w, plus, .Right)
		testing.expect(t, app.profile_menu_shown(w))
		testing.expect_value(t, len(w.workspace.tabs), count + 1)
		app.handle_event(s, input.Key_Event{window = w.id, key = .Escape, pressed = true})
		testing.expect(t, !app.profile_menu_shown(w))
		testing.expect(t, app.gesture_tab_pressed(w) == nil)
		creation_click(s, w, plus, .Left)
		testing.expect_value(t, len(w.workspace.tabs), count + 2)
		testing.expect_value(t, app.focused_session(s, w).profile_id, "default")
	}
}

// Regression: a shell menu held a node id, so another tab taking the window could leave it naming that
// tab's pane. Choosing a profile from the old menu must never replace that pane's shell.
@(test)
profile_menu_does_not_swap_a_pane_that_reuses_the_targets_node :: proc(t: ^testing.T) {
	f: Profile_Fixture
	defer profile_fixture_destroy(t, &f)
	text :: `profile.default.command = cmd.exe
profile.cmd.name = Command Prompt
profile.cmd.command = cmd.exe
profile.cmd.directory = ~
profile.order = default, cmd
`
	if !profile_fixture_create(t, &f, "profile-menu-stale", text) {return}
	s, w := &f.state, f.state.windows[0]
	first := app.focused_session(s, w).id
	app.tab_new(s, w)
	second := app.focused_session(s, w).id
	app.tab_select(s, w, 0)
	node := app.window_tree(w).focus
	app.profile_menu_open_pane(s, w, node, 20, 20)
	cmd := -1
	for i in 0 ..< len(w.profile_menu.items) {
		entry, _ := app.profile_menu_entry(&w.profile_menu, i)
		if app.profile_menu_entry_id(&entry) == "cmd" {cmd = i}
	}
	if !testing.expect(t, cmd >= 0) {return}
	// Replace the displayed tree without a user focus-leave: asynchronous layout changes need not pass
	// through tab_select's overlay cancellation.
	w.workspace.selected = 1
	if !testing.expect(t, first != second && app.window_tree(w).focus == node && app.profile_menu_shown(w)) {
		return
	}
	ui.menu_select(&w.profile_menu.menu, cmd)
	app.profile_menu_choose(s, w)
	testing.expect(t, !app.profile_menu_shown(w) && app.confirmation_asking(w, app.Pane_Swap) == nil)
	testing.expect_value(t, app.focused_session(s, w).profile_id, "default")
	testing.expect_value(t, app.session_find(s, first).profile_id, "default")
}
