package app_test

import app "../../src"
import "aio:commands"
import "cosmos:input"
import "cosmos:render"
import "cosmos:search"
import "aio:settings"
import "aio:views"
import "core:testing"
import "core:time"
import "cosmos:ui"

@(test)
tooltip_waits_for_its_hover_deadline :: proc(t: ^testing.T) {
	now := time.tick_now()
	w := app.Window{tooltip = ui.Tooltip_Pending{"Split right", time.tick_add(now, 700 * time.Millisecond), {}}}
	app.tooltip_tick(&w, now)
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))

	app.tooltip_tick(&w, time.tick_add(now, 700 * time.Millisecond))
	label, shown := ui.tooltip_shown(&w)
	testing.expect(t, shown && !tooltip_pending(&w))
	testing.expect_value(t, label, "Split right")
}

@(test)
tooltip_covers_scrollback_find_buttons :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1}
	ui.find_init(&w.find)
	defer ui.find_destroy(&w.find)
	ui.find_open(&w.find)
	l := ui.find_layout(900, 1, 50)
	// Each button's tooltip names the key that does the same while the bar has the keyboard.
	buttons := [?]struct {
		rect:            render.Rect,
		label, shortcut: string,
		outcome:         ui.Find_Outcome,
	} {
		{l.case_toggle, "Match case", "Alt+C", ui.Find_Change.Changed},
		{l.regex_toggle, "Use regular expression", "Alt+R", ui.Find_Change.Changed},
		{l.up, "Previous match", "Shift+Enter", search.Step.Previous},
		{l.down, "Next match", "Enter", search.Step.Next},
		{l.close, "Close find", "Esc", ui.Find_Change.Closed},
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	for button in buttons {
		x := i32(button.rect.x + button.rect.width / 2)
		y := i32(button.rect.y + button.rect.height / 2)
		_ = ui.find_hover(&w.find, l, true, f32(x), f32(y))
		app.tooltip_hover(&state, &w, .Find, input.Mouse_Move_Event{x = x, y = y})
		testing.expect_value(t, ui.tooltip_current(&w), button.label)
		testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
		testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Find, f32(x), f32(y), buffer[:]), button.shortcut)
		key := ui.FIND_KEYS[w.find.hover]
		testing.expect_value(t, ui.find_key(&w.find, {key = key.key, modifiers = key.modifiers, pressed = true}),
			button.outcome)
	}
}

// The palette's and the Settings search's keyboard button say what they do and name Alt+K, the key that
// does the same, in the shortcut slot rather than in the words.
@(test)
tooltip_key_search_names_its_toggle_key :: proc(t: ^testing.T) {
	state: app.App
	w: app.Window
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	toggle := views.KEY_SEARCH_TOGGLE
	testing.expect(t, views.key_search_toggles({key = toggle.key, modifiers = toggle.modifiers, pressed = true,
		unshifted = 'k'}))

	state.palette.keys_hover = true
	app.tooltip_hover(&state, &w, .Palette, input.Mouse_Move_Event{})
	testing.expect_value(t, ui.tooltip_current(&w), "Search by pressing a shortcut")
	testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Palette, 0, 0, buffer[:]), "Alt+K")
	state.palette.keys.state = .Recording
	app.tooltip_hover(&state, &w, .Palette, input.Mouse_Move_Event{})
	testing.expect_value(t, ui.tooltip_current(&w), "Search by typing")
	testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Palette, 0, 0, buffer[:]), "Alt+K")
	state.palette.keys_hover = false
	testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Palette, 0, 0, buffer[:]), "")

	w.editor.hover_reset = -1
	w.editor.hover_profile_item = -1
	w.editor.keys_hover = true
	app.tooltip_hover(&state, &w, .Settings_Page, input.Mouse_Move_Event{})
	testing.expect_value(t, ui.tooltip_current(&w), "Search by pressing a shortcut")
	testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Settings_Page, 0, 0, buffer[:]), "Alt+K")
}

@(test)
tooltip_covers_palette_setting_reset :: proc(t: ^testing.T) {
	state: app.App
	state.palette.reset_hover = 0
	w: app.Window
	app.tooltip_hover(&state, &w, .Palette, input.Mouse_Move_Event{})
	testing.expect_value(t, ui.tooltip_current(&w), "Reset setting")
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(test)
tooltip_neighbor_buttons_skip_second_delay :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 400, height = 300, scale = 1}
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 285, y = 20})
	testing.expect_value(t, ui.tooltip_current(&w), "Minimize")
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
	app.tooltip_tick(&w, time.tick_add(time.tick_now(), time.Second))
	testing.expect(t, tooltip_visible(&w))

	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 330, y = 20})
	testing.expect_value(t, ui.tooltip_current(&w), "Maximize")
	testing.expect(t, tooltip_visible(&w) && !tooltip_pending(&w))
	app.tooltip_hover(&state, &w, .Content, input.Mouse_Move_Event{x = 355, y = 20})
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 375, y = 20})
	testing.expect_value(t, ui.tooltip_current(&w), "Close window")
	testing.expect(t, tooltip_visible(&w) && !tooltip_pending(&w))

	app.tooltip_hover(&state, &w, .Content, input.Mouse_Move_Event{x = 0, y = 20})
	app.tooltip_hover(&state, &w, .Tab_Orientation, input.Mouse_Move_Event{x = 100, y = 20})
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(test)
tooltip_workspace_color_wheel :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1}
	w.workspace_picker.state = app.Workspace_Picker_Icons{}
	r := app.workspace_icon_color_button(&w)
	app.tooltip_hover(&state, &w, .Workspace_Picker,
		input.Mouse_Move_Event{x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, ui.tooltip_current(&w), "Change icon color")
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(test)
tooltip_skips_labeled_vertical_new_tab :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 900, height = 600, scale = 1, rail_wide = true, rail = app.Rail_Docked{}}
	l := views.rail_layout({0, ui.TITLE_BAR_HEIGHT, views.RAIL_WIDTH, 560}, 1, 0, 0)
	r := views.rail_new_tab_tile(l)
	app.tooltip_hover(&state, &w, .Tabs,
		input.Mouse_Move_Event{x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, ui.tooltip_current(&w), "")
	testing.expect(t, w.tooltip == nil)
}

@(test)
tooltip_neighbor_grace_expires :: proc(t: ^testing.T) {
	state: app.App
	w := app.Window{width = 400, height = 300, scale = 1}
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 285, y = 20})
	app.tooltip_tick(&w, time.tick_add(time.tick_now(), time.Second))
	app.tooltip_hover(&state, &w, .Content, input.Mouse_Move_Event{x = 310, y = 20})
	warm, ok := &w.tooltip.(ui.Tooltip_Warm)
	if !testing.expect(t, ok) {return}
	warm.until = time.tick_add(time.tick_now(), -time.Millisecond)
	app.tooltip_hover(&state, &w, .Caption, input.Mouse_Move_Event{x = 330, y = 20})
	testing.expect(t, !tooltip_visible(&w) && tooltip_pending(&w))
}

@(private = "file")
tooltip_visible :: proc(w: ^app.Window) -> bool {
	_, shown := ui.tooltip_shown(w)
	return shown
}

@(private = "file")
tooltip_pending :: proc(w: ^app.Window) -> bool {
	_, pending := ui.tooltip_deadline(w)
	return pending
}

@(test)
tooltip_profile_chevron_uses_shared_hit_bounds :: proc(t: ^testing.T) {
	state: app.App
	// A strip always holds a tab; with none, the new-tab button and chevron have no width.
	tab: app.Tab
	workspace: app.Workspace
	append(&workspace.tabs, &tab)
	defer delete(workspace.tabs)
	w := app.Window{width = 900, height = 600, scale = 1, tabs_horizontal = true, workspace = &workspace}
	r := app.tab_chevron_rect(&state, &w)
	app.tooltip_hover(&state, &w, .Tabs,
		input.Mouse_Move_Event{x = i32(r.x + r.width / 2), y = i32(r.y + r.height / 2)})
	testing.expect(t, ui.tooltip_current(&w) != "", "the chevron has a tooltip inside its hit bounds")
	app.tooltip_hover(&state, &w, .Tabs,
		input.Mouse_Move_Event{x = i32(r.x + r.width + 1), y = i32(r.y + r.height / 2)})
	testing.expect_value(t, ui.tooltip_current(&w), "")
	app.tooltip_hover(&state, &w, .Tabs,
		input.Mouse_Move_Event{x = i32(r.x + r.width / 2), y = i32(r.y + r.height + 1)})
	testing.expect_value(t, ui.tooltip_current(&w), "")
}

// A control that runs a command shows that command's first shortcut beside its label, read from the
// registry at each draw: Settings rebinding it changes the tooltip at once, and unbinding it removes it.
@(test)
tooltip_shortcut_follows_the_commands_binding :: proc(t: ^testing.T) {
	state := app.App{registry = commands.create()}
	defer commands.destroy(&state.registry)
	if !testing.expect_value(t, app.register_actions(&state.registry), commands.Error.None) {return}
	w := app.Window{width = 900, height = 600, scale = 1}
	r := app.title_action_rect(&state, &w, .Palette)
	x, y := r.x + r.width / 2, r.y + r.height / 2
	app.tooltip_hover(&state, &w, .Title_Action, input.Mouse_Move_Event{x = i32(x), y = i32(y)})
	testing.expect_value(t, ui.tooltip_current(&w), "Everything palette")
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Title_Action, x, y, buffer[:]), "Ctrl+Shift+P")

	steps := [?]struct {
		setting, shortcut: string,
	}{{"keys.app.command_palette = Ctrl+Alt+K\n", "Ctrl+Alt+K"}, {"keys.app.command_palette =\n", ""}}
	for step in steps {
		parsed, diagnostics, parse_error := settings.parse(step.setting)
		settings.diagnostics_destroy(&diagnostics)
		if !testing.expect_value(t, parse_error, nil) {return}
		_, report_error := app.binding_report(&state.registry, &parsed)
		settings.destroy(&parsed)
		if !testing.expect_value(t, report_error, nil) {return}
		testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Title_Action, x, y, buffer[:]), step.shortcut)
	}

	// Minimize belongs to Windows and runs no command.
	testing.expect_value(t, app.tooltip_shortcut(&state, &w, .Caption, f32(w.width) - 130, 20, buffer[:]), "")
}

// A tooltip draws its shortcut as the Settings search draws Ctrl+F: the whole chord in one keycap, at the
// tooltip's right inset and centred on its line, in a tooltip grown to hold it.
@(test)
tooltip_draws_its_shortcut_as_a_keycap :: proc(t: ^testing.T) {
	f: Palette_Fixture
	defer palette_fixture_destroy(t, &f)
	if !palette_fixture_create(t, &f, "tooltip-keycap", second_window = false) {return}
	s, w := &f.state, f.state.windows[0]
	r := app.title_action_rect(s, w, .Palette)
	x, y := r.x + r.width / 2, r.y + r.height / 2
	w.pointer = {x, y}
	app.tooltip_hover(s, w, .Title_Action, input.Mouse_Move_Event{x = i32(x), y = i32(y)})
	app.tooltip_tick(w, time.tick_add(time.tick_now(), time.Second))
	if !testing.expect(t, tooltip_visible(w)) {return}
	render.draw_list_reset(&w.list)
	if !testing.expect_value(t, app.tooltip_draw(s, w), render.Build_Status.Ok) {return}

	scale := w.scale
	keycap_text := ui.text_styled(&w.ui_text, .Detail)
	keycap, panel: render.Rect
	found_keycap, found_panel := false, false
	for instance in w.list.rects {
		if instance.color == s.theme.border && instance.stroke == scale &&
		   instance.rect.height == ui.KEYCAP_HEIGHT * scale {keycap, found_keycap = instance.rect, true}
		if instance.color == s.theme.surface {panel, found_panel = instance.rect, true}
	}
	if !testing.expect(t, found_keycap && found_panel, "the tooltip draws a panel and a keycap") {return}
	testing.expect_value(t, keycap.width, ui.keycap_width(&keycap_text, "Ctrl+Shift+P", scale))
	testing.expectf(t, abs(keycap.x + keycap.width - (panel.x + panel.width - 8 * scale)) < 0.5,
		"the keycap ends at the right inset: %v in %v", keycap, panel)
	testing.expectf(t, abs(keycap.y + keycap.height / 2 - (panel.y + panel.height / 2)) < 0.5,
		"the keycap is centred on the line: %v in %v", keycap, panel)
	testing.expect(t, panel.height >= ui.KEYCAP_HEIGHT * scale + 2 * scale, "the keycap fits inside the tooltip")
}
