package ui_test

import "core:testing"
import "aio:render"
import "aio:settings"
import "aio:ui"

@(private)
always_exists :: proc(command: string) -> bool {return command != "missing.exe"}

@(private)
profile_center :: proc(r: render.Rect) -> (f32, f32) {return r.x + r.width / 2, r.y + r.height / 2}

@(private)
profile_fixture_table :: proc(t: ^testing.T) -> settings.Settings {
	s, diagnostics, err := settings.parse(`shell.directory = C:\work
profile.pwsh.command = pwsh.exe -NoLogo
profile.pwsh.name = PowerShell
profile.cmd.command = cmd.exe
profile.cmd.name = Command Prompt
profile.cmd.hidden = true
profile.ubuntu.command = wsl.exe -d Ubuntu
profile.missing.command = missing.exe
profile.order = cmd, pwsh
`)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, settings.profile_detect(&s, {"wsl-ubuntu", "Ubuntu", "wsl.exe -d Ubuntu", "~"}), nil)
	return s
}

@(test)
profile_table_builds_ordered_rows_and_separates_detected :: proc(t: ^testing.T) {
	s := profile_fixture_table(t)
	defer settings.destroy(&s)
	table, table_error := ui.profile_table_build(&s.profiles, always_exists)
	defer ui.profile_table_destroy(&table)
	testing.expect_value(t, table_error, nil)
	testing.expect_value(t, len(table.rows), 5)
	testing.expect_value(t, len(table.detected), 1)
	testing.expect_value(t, table.rows[0].id, "cmd")
	testing.expect_value(t, table.rows[1].id, "pwsh")
	testing.expect_value(t, table.rows[2].id, "default")
	testing.expect_value(t, table.rows[3].id, "missing")
	testing.expect_value(t, table.rows[4].id, "ubuntu")
	testing.expect_value(t, table.detected[0].id, "wsl-ubuntu")
	testing.expect_value(t, table.rows[0].badge, "C:")
	testing.expect_value(t, table.rows[1].badge, ">_")
	testing.expect_value(t, table.rows[4].badge, "$")
	testing.expect(t, table.rows[0].hidden)
	testing.expect(t, table.rows[2].is_default)
	testing.expect(t, !table.rows[1].is_default)
	testing.expect(t, table.detected[0].detected)
}

@(test)
profile_table_notes_duplicate_names_and_missing_commands :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse(`profile.first.name = Same
profile.first.command = cmd.exe
profile.second.name = same
profile.second.command = cmd.exe
profile.third.command = missing.exe
`)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	table, table_error := ui.profile_table_build(&s.profiles, always_exists)
	defer ui.profile_table_destroy(&table)
	testing.expect_value(t, table_error, nil)
	first, second, third :=
		settings.profile_find(&s.profiles, "first"), settings.profile_find(&s.profiles, "second"),
		settings.profile_find(&s.profiles, "third")
	if !testing.expect(t, first != nil && second != nil && third != nil) {return}
	got := table.rows
	testing.expect_value(t, len(got), 4)
	for row in got {
		switch row.id {
		case "first", "second":
			testing.expect_value(t, row.note, "Another profile uses this name.")
		case "third":
			testing.expect_value(t, row.note, "Command not found: missing.")
		}
	}
}

@(test)
profile_columns_drop_the_directory_before_any_cell_overlaps :: proc(t: ^testing.T) {
	directory_min := f32(ui.PROFILE_DIRECTORY_MIN_WIDTH)
	actions_min := f32(ui.PROFILE_ACTIONS_MIN_WIDTH)
	icon_min := f32(ui.PROFILE_ICON_MIN_WIDTH)
	for scale in ([?]f32{1, 1.5}) {
		for width in ([?]f32 {
			960,
			directory_min,
			directory_min - 1,
			600,
			actions_min,
			actions_min - 1,
			420,
			360,
			300,
		}) {
			columns := ui.profile_columns({0, 0, width * scale, 52 * scale}, scale)
			testing.expect_value(t, columns.directory_shown, width >= directory_min)
			testing.expect_value(t, columns.actions_shown, width >= actions_min)
			testing.expect_value(t, columns.icon_shown, width >= icon_min)
			cells := [?]struct{ name: string, rect: render.Rect } {
				{"handle", columns.handle},
				{"icon", columns.icon},
				{"name", columns.name},
				{"command", columns.command},
				{"directory", columns.directory},
				{"default", columns.default},
				{"hidden", columns.hidden},
				{"actions", columns.actions},
			}
			for a, i in cells {
				if a.rect.width <= 0 {continue}
				testing.expect(
					t,
					a.rect.x + a.rect.width <= width * scale + 0.01,
				)
				for b, j in cells {
					if i == j || b.rect.width <= 0 {continue}
					overlap :=
						a.rect.x < b.rect.x + b.rect.width && b.rect.x < a.rect.x + a.rect.width
					testing.expect(t, !overlap)
				}
			}
		}
	}
}

@(test)
profile_detected_rows_keep_the_enable_action_clear_of_the_command :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5}) {
		for width in ([?]f32{420, 300, 220, 180}) {
			parts := ui.profile_row_parts(.Detected, {0, 0, width * scale, 52 * scale}, scale)
			testing.expect(t, parts.name.x + parts.name.width <= parts.enable.x - 12 * scale + 0.01)
			testing.expect(t, parts.command.x + parts.command.width <= parts.enable.x - 12 * scale + 0.01)
			testing.expect(t, parts.enable.x + parts.enable.width <= width * scale + 0.01)
		}
	}
}

@(private)
profile_editor_fixture :: proc(t: ^testing.T, p: ^ui.Editor) {
	rows := [?]struct{ row: ui.Editor_Row, group: string }{
		{{key = "profile.alpha", title = "Alpha", description = "alpha.exe", value = `C:\`,
			profile = "alpha", badge = ">_", detail = "alpha.exe C:\\", kind = .Profile,
			flags = {.Default}}, "Profiles"},
		{{key = "profile.alpha.name", title = "Name", description = "Shown in menus.",
			value = "Alpha", profile = "alpha", kind = .Text}, "Profiles"},
		{{key = "profile.alpha.command", title = "Command line", description = "Executable.",
			value = "alpha.exe", profile = "alpha", kind = .Text}, "Profiles"},
		{{key = "profile.beta", title = "Beta", description = "beta.exe", value = "~",
			profile = "beta", badge = "C:", detail = "beta.exe ~", kind = .Profile}, "Profiles"},
		{{key = "profile.beta.name", title = "Name", description = "Shown in menus.",
			value = "Beta", profile = "beta", kind = .Text}, "Profiles"},
		{{key = "profile.beta.remove", title = "Remove Profile", description = "Remove.",
			value = "Remove…", profile = "beta", kind = .Action}, "Profiles"},
		{{key = "profile.beta.remove.cancel", title = "Cancel Removal", description = "Keep.",
			value = "Cancel", profile = "beta", kind = .Action}, "Profiles"},
		{{key = "profile.beta.remove.confirm", title = "Confirm Remove Profile",
			description = "Remove every line.", value = "Remove Profile", profile = "beta",
			kind = .Action}, "Profiles"},
		{{key = "profiles.add", title = "Add Profile", description = "Add a shell.",
			value = "Add Profile", kind = .Profile_Add}, "Profiles"},
		{{key = "profiles.detected", title = "Detected on this PC", value = "1",
			detail = "Gamma gamma.exe", kind = .Detected_Header}, "Profiles"},
		{{key = "profile.gamma", title = "Gamma", description = "gamma.exe", value = "~",
			profile = "gamma", badge = "$", detail = "gamma.exe ~", kind = .Detected,
			flags = {.Listed}}, "Profiles"},
	}
	for entry in rows {
		testing.expect_value(t, ui.editor_add(p, entry.row, entry.group), nil)
	}
	ui.editor_group_table(p, "Profiles")
	p.open = true
	ui.editor_filter(p)
}

@(private)
profile_item_index :: proc(p: ^ui.Editor, key: string) -> int {
	for item, index in p.items {
		if item.row >= 0 && p.rows[item.row].key == key {return index}
	}
	return -1
}

@(test)
editor_profile_table_expands_one_row_and_searches_by_name :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	testing.expect_value(t, ui.editor_row(&p).key, "profile.alpha")

	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.expanded, "alpha")
	testing.expect(t, profile_item_index(&p, "profile.alpha.name") >= 0)

	testing.expect(t, ui.editor_select_key(&p, "profile.beta"))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.expanded, "beta")
	testing.expect(t, profile_item_index(&p, "profile.alpha.name") < 0)
	testing.expect(t, profile_item_index(&p, "profile.beta.name") >= 0)

	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.expanded, "")
	testing.expect(t, profile_item_index(&p, "profile.beta.name") < 0)

	ui.field_set(&p.filter, "beta")
	ui.editor_filter(&p)
	testing.expect_value(t, ui.editor_row(&p).key, "profile.beta")
	testing.expect(t, ui.editor_reveal(&p, "profile.beta.name"))
	testing.expect_value(t, ui.editor_row(&p).key, "profile.beta.name")
	testing.expect_value(t, p.expanded, "beta")
}

@(test)
editor_profile_row_actions_write_default_hidden_and_remove :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "profile.alpha"))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Tab})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.focus, ui.Editor_Focus.Control)
	testing.expect_value(t, p.profile_control, ui.Profile_Control.Radio)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, p.action, ui.Profile_Action.Default)
	testing.expect_value(t, p.action_id, "alpha")
	ui.editor_action_clear(&p)

	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.profile_control, ui.Profile_Control.Hidden)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space, text = " "})), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, p.action, ui.Profile_Action.Hidden)
	testing.expect_value(t, p.action_value, "true")
	ui.editor_action_clear(&p)

	testing.expect(t, ui.editor_select_key(&p, "profile.beta"))
	ui.editor_profile_expand(&p, "beta")
	beta := ui.editor_row(&p)
	beta.flags += {.Hidden}
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.profile_control, ui.Profile_Control.Hidden)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space, text = " "})), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, p.action, ui.Profile_Action.Hidden)
	testing.expect_value(t, p.action_value, "false")
	ui.editor_action_clear(&p)

	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Delete})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.remove_confirm, "beta")
	testing.expect_value(t, ui.editor_row(&p).key, "profile.beta.remove.confirm")
	testing.expect(t, p.expanded == "beta")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.remove_confirm, "")
	testing.expect_value(t, ui.editor_row(&p).key, "profile.beta.remove")

	ui.editor_error_set(&p, "beta", "profile.beta.name", "Another profile uses this name.")
	testing.expect_value(t, p.error_text, "Another profile uses this name.")
	ui.editor_select_key(&p, "profile.alpha")
	testing.expect_value(t, p.error_text, "")
}

@(test)
editor_detected_section_toggles_and_enables :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "profiles.detected"))
	testing.expect(t, profile_item_index(&p, "profile.gamma") < 0)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Changed)
	testing.expect(t, p.detected_open)
	testing.expect(t, profile_item_index(&p, "profile.gamma") >= 0)
	testing.expect(t, ui.editor_select_key(&p, "profile.gamma"))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, p.action, ui.Profile_Action.Enable)
	testing.expect_value(t, p.action_id, "gamma")

	ui.editor_action_clear(&p)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Tab})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.profile_control, ui.Profile_Control.Enable)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space, text = " "})), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, p.action, ui.Profile_Action.Enable)
	testing.expect_value(t, p.action_id, "gamma")
}

@(test)
editor_profile_default_row_has_no_remove_action :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	testing.expect_value(
		t,
		ui.editor_add(
			&p,
			{
				key = "profile.default",
				title = "Default",
				description = "pwsh.exe",
				value = "~",
				profile = "default",
				badge = ">_",
				kind = .Profile,
				flags = {.Default},
			},
			"Profiles",
		),
		nil,
	)
	ui.editor_filter(&p)
	testing.expect(t, ui.editor_select_key(&p, "profile.default"))
	testing.expect(t, !ui.editor_select_key(&p, "profile.default.remove"))
	ui.editor_profile_remove_ask(&p, "default")
	testing.expect_value(t, p.remove_confirm, "")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Tab})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Delete})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.remove_confirm, "")

	layout := ui.editor_layout({0, 40, 1200, 4000}, 1)
	index := profile_item_index(&p, "profile.default")
	remove := ui.editor_profile_parts(&p, layout, index).remove
	testing.expect_value(
		t,
		ui.editor_press(&p, layout, nil, remove.x + remove.width / 2, remove.y + remove.height / 2, false),
		ui.Editor_Outcome.Changed,
	)
	testing.expect_value(t, p.expanded, "")
}

@(test)
editor_profile_drag_rewrites_the_order_text :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	l := ui.editor_layout({0, 40, 1200, 1400}, 1)
	testing.expect(t, ui.editor_select_key(&p, "profile.alpha"))
	alpha_index := profile_item_index(&p, "profile.alpha")
	handle := ui.editor_profile_parts(&p, l, alpha_index).handle
	x, y := profile_center(handle)
	testing.expect_value(t, ui.editor_press(&p, l, nil, x, y, false), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.drag, ui.Editor_Drag.Profile_Order)
	beta_index := profile_item_index(&p, "profile.beta")
	beta_row := ui.editor_row_parts(&p, l, beta_index).row
	testing.expect(t, ui.editor_drag(&p, l, nil, beta_row.x + 40, beta_row.y + beta_row.height - 2))
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Profile_Action)
	testing.expect_value(t, p.action, ui.Profile_Action.Order)
	testing.expect_value(t, p.action_id, "alpha")
	testing.expect_value(t, p.action_value, "beta, alpha, gamma")
}

@(test)
editor_profile_keyboard_moves_rows_expands_with_right_and_collapses_from_the_row :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	testing.expect_value(t, ui.editor_row(&p).key, "profile.alpha")

	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Down})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "profile.beta")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Up})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "profile.alpha")

	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Down})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.expanded, "beta")

	testing.expect_value(t, ui.editor_key(&p, key({key = .Tab})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.focus, ui.Editor_Focus.Control)
	testing.expect_value(t, p.profile_control, ui.Profile_Control.Radio)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.profile_control, ui.Profile_Control.Hidden)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.expanded, "")
}

@(test)
editor_profile_row_click_expands_and_the_icon_clear_stays_inside :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	layout := ui.editor_layout({0, 40, 1200, 4000}, 1)
	beta := profile_item_index(&p, "profile.beta")
	if !testing.expect(t, beta >= 0) {return}
	row := ui.editor_row_parts(&p, layout, beta).row
	testing.expect_value(
		t,
		ui.editor_press(&p, layout, nil, row.x + 200, row.y + row.height / 2, false),
		ui.Editor_Outcome.Changed,
	)
	testing.expect_value(t, p.expanded, "beta")

	testing.expect_value(
		t,
		ui.editor_add(
			&p,
			{
				key = "profile.beta.icon",
				title = "Icon",
				description = "PNG path.",
				value = "icon.png",
				profile = "beta",
				badge = ">_",
				kind = .Profile_Icon,
			},
			"Profiles",
		),
		nil,
	)
	ui.editor_filter(&p)
	icon := profile_item_index(&p, "profile.beta.icon")
	if !testing.expect(t, icon >= 0) {return}
	parts := ui.editor_row_parts(&p, layout, icon)
	testing.expect(t, parts.clear.x >= parts.row.x)
	testing.expect(t, parts.clear.x + parts.clear.width <= parts.row.x + parts.row.width)
	testing.expect(t, parts.field.x >= parts.row.x)
	testing.expect(t, parts.field.x + parts.field.width <= parts.clear.x)
}

@(test)
editor_profile_column_captions_only_on_the_table_group :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	profile_editor_fixture(t, &p)
	found := false
	for group in p.groups {
		testing.expect_value(t, group.title, "Profiles")
		found = true
		testing.expect(t, group.table)
	}
	testing.expect(t, found)
}
