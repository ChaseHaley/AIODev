package ui_test

import "aio:commands"
import "aio:input"
import "aio:platform"
import "aio:ui"
import "core:testing"

@(private)
Control_Values :: struct {
	keys, values: [8]string,
	count:        int,
	fonts:        []string,
}

@(private)
control_value :: proc(user: rawptr, key: string) -> (value, label: string) {
	v := cast(^Control_Values)user
	for i in 0 ..< v.count {if v.keys[i] == key {return v.values[i], ""}}
	return "", ""
}

@(private)
control_choices :: proc(user: rawptr, key: string) -> (choices, labels: []string) {
	v := cast(^Control_Values)user
	return key == "font.family" ? v.fonts : nil, nil
}

@(private)
control_set :: proc(v: ^Control_Values, key, value: string) {
	for i in 0 ..< v.count {
		if v.keys[i] == key {
			v.values[i] = value
			return
		}
	}
	v.keys[v.count], v.values[v.count] = key, value
	v.count += 1
}

@(private)
CONTROL_ROWS := [?]ui.Palette_Setting {
	{key = "cursor.blink", title = "Cursor Blink", group = "Cursor", control = .Toggle, resettable = true,
		default_value = "false"},
	{key = "pane.gap", title = "Pane Gap", group = "Panes", control = .Slider, minimum = 0, maximum = 24,
		step = 1, resettable = true, default_value = "5"},
	{key = "cursor.style", title = "Cursor Style", group = "Cursor", control = .Choice,
		choices = {"block", "bar", "underline"}},
	{key = "status.ignore_apps", title = "Ignored Apps", group = "Status", control = .Text},
	{key = "input.leader", title = "Leader Key", group = "Input", control = .None, resettable = true,
		default_value = "ctrl+b"},
	{key = "font.family", title = "Font Family", group = "Font", control = .Choice,
		searchable = true},
}

@(private)
control_palette :: proc(t: ^testing.T, p: ^ui.Palette, v: ^Control_Values) -> commands.Registry {
	registry := commands.create()
	testing.expect_value(t, ui.palette_init(p, CONTROL_ROWS[:]), nil)
	ui.palette_set_values(p, {user = v, value = control_value, choices = control_choices})
	control_set(v, "cursor.blink", "true")
	control_set(v, "pane.gap", "5")
	control_set(v, "cursor.style", "block")
	control_set(v, "status.ignore_apps", "")
	control_set(v, "input.leader", "ctrl+b")
	control_set(v, "font.family", "Cascadia Mono")
	ui.palette_open_mode(p, &registry, .Settings)
	return registry
}

@(private)
select_setting :: proc(p: ^ui.Palette, key: string) {
	for result, i in p.results {
		if ui.palette_result_name(p, result) == key {p.selected = i}
	}
}

@(private)
press :: proc(key: input.Key, modifiers: input.Modifiers = {}) -> platform.Key_Event {
	return {key = key, modifiers = modifiers, pressed = true}
}

@(test)
palette_alt_arrows_step_a_toggle_slider_and_choice_in_place :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "cursor.blink")
	outcome, _ := ui.palette_key(&p, &registry, press(.Arrow_Left, {.Alt}))
	key, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, key, "cursor.blink")
	testing.expect_value(t, value, "false")
	testing.expect(t, p.open, "the palette stays open after a change")

	select_setting(&p, "pane.gap")
	outcome, _ = ui.palette_key(&p, &registry, press(.Arrow_Right, {.Alt}))
	_, value = ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "6")

	control_set(&v, "pane.gap", "24")
	outcome, _ = ui.palette_key(&p, &registry, press(.Arrow_Right, {.Alt}))
	testing.expect_value(t, outcome, ui.Outcome.Changed)

	select_setting(&p, "cursor.style")
	outcome, _ = ui.palette_key(&p, &registry, press(.Arrow_Left, {.Alt}))
	_, value = ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "underline")
}

@(test)
palette_enter_still_jumps_to_a_setting_with_a_control :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "cursor.blink")
	outcome, _ := ui.palette_key(&p, &registry, press(.Enter))
	testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
	testing.expect_value(t, p.chosen, "cursor.blink")
}

@(test)
palette_jump_only_setting_ignores_control_keys :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "input.leader")
	outcome, _ := ui.palette_key(&p, &registry, press(.Enter, {.Control}))
	testing.expect(t, outcome != .Set_Setting, "Ctrl+Enter does not edit a jump-only setting")
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.None)
}

@(test)
palette_choice_list_opens_moves_and_chooses :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "cursor.style")
	ui.palette_key(&p, &registry, press(.Enter, {.Control}))
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Choice)
	outcome, _ := ui.palette_key(&p, &registry, press(.Escape))
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect(t, p.open, "Escape closes only the list")
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.None)

	ui.palette_key(&p, &registry, press(.Enter, {.Control}))
	ui.palette_key(&p, &registry, press(.Arrow_Down))
	outcome, _ = ui.palette_key(&p, &registry, press(.Enter))
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "bar")
}

@(test)
palette_long_choice_list_filters_typed_text :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	v.fonts = {"Aptos", "Bahnschrift", "Calibri", "Cambria", "Cascadia Code", "Cascadia Mono",
		"Consolas", "Courier New", "Georgia", "JetBrains Mono", "Lucida Console", "Segoe UI", "Verdana"}
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "font.family")
	ui.palette_key(&p, &registry, press(.Enter, {.Control}))
	ui.palette_text(&p, &registry, "jet")
	testing.expect_value(t, ui.palette_query(&p), "")
	outcome, _ := ui.palette_key(&p, &registry, press(.Enter))
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "JetBrains Mono")
}

@(test)
palette_text_entry_commits_on_enter :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "status.ignore_apps")
	ui.palette_key(&p, &registry, press(.Enter, {.Control}))
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.Text)
	ui.palette_text(&p, &registry, "vim, less")
	outcome, _ := ui.palette_key(&p, &registry, press(.Enter))
	key, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, key, "status.ignore_apps")
	testing.expect_value(t, value, "vim, less")
	testing.expect_value(t, ui.palette_editing(&p), ui.Palette_Edit_Kind.None)
}

@(test)
palette_slider_typed_value_snaps_and_clamps :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	select_setting(&p, "pane.gap")
	ui.palette_key(&p, &registry, press(.Enter, {.Control}))
	ui.palette_text(&p, &registry, "99")
	outcome, _ := ui.palette_key(&p, &registry, press(.Enter))
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "24")
}

@(test)
palette_toggle_click_changes_value_and_title_click_jumps :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	l := ui.palette_layout(&p, 1000, 800, 1)
	row_y := l.list.y + l.row_height / 2
	toggle_x := l.list.x + l.list.width - 46 - 18
	outcome, _ := ui.palette_mouse_press(&p, &registry, l, toggle_x, row_y)
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "false")
	testing.expect(t, p.open, "a control click keeps the palette open")

	outcome, _ = ui.palette_mouse_press(&p, &registry, l, l.list.x + 60, row_y)
	testing.expect_value(t, outcome, ui.Outcome.Open_Setting)
}

@(test)
palette_slider_drag_saves_on_release :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	l := ui.palette_layout(&p, 1000, 800, 1)
	row_y := l.list.y + l.row_height * 1.5
	right := l.list.x + l.list.width - 46
	track_left := right - 156 + 7
	track_right := track_left + 98
	outcome, _ := ui.palette_mouse_press(&p, &registry, l, track_left + 2, row_y)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect(t, ui.palette_slider_dragging(&p), "a track press starts a drag")
	ui.palette_slider_drag(&p, l, track_right + 40)
	outcome = ui.palette_pointer_release(&p)
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "24")
	testing.expect(t, !ui.palette_slider_dragging(&p), "release ends the drag")
}

@(test)
palette_reset_button_restores_the_default_and_ignores_an_unchanged_setting :: proc(t: ^testing.T) {
	p: ui.Palette
	v: Control_Values
	registry := control_palette(t, &p, &v)
	defer commands.destroy(&registry)
	defer ui.palette_destroy(&p)

	l := ui.palette_layout(&p, 1000, 800, 1)
	reset_x := l.list.x + l.list.width - 8 - 13
	blink_y := l.list.y + l.row_height / 2
	outcome, _ := ui.palette_mouse_press(&p, &registry, l, reset_x, blink_y)
	_, value := ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, value, "false")
	testing.expect(t, p.open, "a reset keeps the palette open")

	gap_y := l.list.y + l.row_height * 1.5
	outcome, _ = ui.palette_mouse_press(&p, &registry, l, reset_x, gap_y)
	testing.expect_value(t, outcome, ui.Outcome.Changed)
	testing.expect_value(t, p.selected, 1)

	// A jump-only setting still has its reset button.
	leader_y := l.list.y + l.row_height * 4.5
	control_set(&v, "input.leader", "ctrl+a")
	outcome, _ = ui.palette_mouse_press(&p, &registry, l, reset_x, leader_y)
	key: string
	key, value = ui.palette_chosen_value(&p)
	testing.expect_value(t, outcome, ui.Outcome.Set_Setting)
	testing.expect_value(t, key, "input.leader")
	testing.expect_value(t, value, "ctrl+b")
}
