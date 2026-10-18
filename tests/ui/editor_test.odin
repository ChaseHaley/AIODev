package ui_test

import "core:testing"
import "aio:commands"
import "aio:ui"

@(private, rodata)
cursor_styles := [?]string{"block", "bar", "underline"}

@(private)
editor_fixture :: proc(t: ^testing.T, p: ^ui.Editor) {
	rows := [?]struct { row: ui.Editor_Row, group: string }{
		{{key = "pane.gap", title = "Pane Gap", description = "Space between panes.", value = "5",
			default_value = "5", kind = .Integer, minimum = 0, maximum = 24}, "Panes"},
		{{key = "pane.show_headers", title = "Show Pane Headers", description = "Headers.", value = "true",
			default_value = "true", kind = .Toggle}, "Panes"},
		{{key = "font.family", title = "Font Family", description = "Typeface", value = "Mono",
			default_value = "Mono", kind = .Text}, "Font"},
		{{key = "cursor.style", title = "Cursor Style", description = "Shape", value = "block",
			default_value = "block", kind = .Choice, choices = cursor_styles[:]}, "Cursor"},
		{{key = "colors.cursor", title = "Cursor Color", description = "Cursor.", value = "",
			kind = .Optional_Color}, "Colors"},
		{{key = "scrollback.lines", title = "Scrollback Lines", description = "History.", value = "10000",
			default_value = "10000", kind = .Integer, minimum = 0, maximum = 10000000}, "Scrollback"},
		{{key = "keys.pane.split_right", title = "Split Right", description = "Shortcut.", value = "Ctrl+Shift+O",
			default_value = "Ctrl+Shift+O", kind = .Shortcut}, "Pane Shortcuts"},
		{{key = "input.leader", title = "Leader Key", description = "Prefix.", value = "", kind = .Shortcut},
			"Input"},
	}
	for r in rows { testing.expect_value(t, ui.editor_add(p, r.row, r.group), nil) }
	ui.editor_collapse(p, "Pane Shortcuts", true)
	p.open = true
	ui.editor_filter(p)
}

@(private)
visible_keys :: proc(p: ^ui.Editor) -> [dynamic]string {
	keys := make([dynamic]string, context.temp_allocator)
	for item in p.items { append(&keys, item.row < 0 ? p.groups[item.group].title : p.rows[item.row].key) }
	return keys
}

@(test)
editor_groups_collapse_and_restore_after_search :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	keys := visible_keys(&p)
	browse := len(keys)
	testing.expect_value(t, browse, 14)
	testing.expect_value(t, len(p.groups), 7)
	testing.expect_value(t, keys[0], "Panes")
	testing.expect_value(t, keys[1], "pane.gap")
	testing.expect_value(t, keys[len(keys)-3], "Pane Shortcuts")
	testing.expect_value(t, keys[len(keys)-2], "Input")
	testing.expect(t, ui.editor_row(&p) == nil)
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, len(p.items), len(keys)-2)
	testing.expect_value(t, p.selected, 0)
	ui.editor_key(&p, key({key = .Arrow_Right}))
	testing.expect_value(t, len(p.items), len(keys))
	ui.editor_key(&p, key({key = .Arrow_Left}))
	testing.expect_value(t, len(p.items), len(keys)-2)

	ui.editor_text(&p, "panes")
	keys = visible_keys(&p)
	testing.expect_value(t, len(keys), 5)
	testing.expect_value(t, keys[0], "Panes")
	testing.expect_value(t, keys[3], "Pane Shortcuts")
	testing.expect_value(t, keys[4], "keys.pane.split_right")
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	ui.editor_key(&p, key({key = .Backspace}))
	testing.expect_value(t, len(p.filter.bytes), 0)
	testing.expect_value(t, len(visible_keys(&p)), browse-2)
	testing.expect_value(t, visible_keys(&p)[1], "Font")

	ui.editor_text(&p, "SPLIT")
	testing.expect_value(t, ui.editor_row(&p).key, "keys.pane.split_right")
	ui.editor_text(&p, " zzz")
	testing.expect_value(t, len(p.items), 0)
	testing.expect(t, ui.editor_row(&p) == nil)
}

@(test)
editor_lists_navigate_with_control_n_and_p :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect_value(t, ui.editor_key(&p, key({key = .N, modifiers = {.Control}})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	ui.editor_key(&p, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.show_headers")
	ui.editor_key(&p, key({key = .P, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	testing.expect_value(t, len(p.filter.bytes), 0)
	ui.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.show_headers")
}

@(test)
editor_typed_controls_produce_values :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "pane.show_headers"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect(t, p.editing)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space, text = " "})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "false")

	testing.expect(t, ui.editor_select_key(&p, "cursor.style"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Arrow_Right})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "bar")
	testing.expect(t, ui.editor_select_key(&p, "cursor.style"))
	testing.expect_value(t, ui.field_string(&p.value), "block")
	l := ui.editor_layout(&p, 1200, 900, 1)
	third := l.choices[2]
	testing.expect_value(t, ui.editor_press(&p, l, nil, third.x+2, third.y+2, 1, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "underline")

	testing.expect(t, ui.editor_select_key(&p, "pane.gap"))
	l = ui.editor_layout(&p, 1200, 900, 1)
	testing.expect(t, l.slider.width > 0)
	ui.editor_press(&p, l, nil, l.slider.x+l.slider.width*0.5, l.slider.y+2, 1, false)
	testing.expect_value(t, ui.field_string(&p.value), "12")
	ui.editor_drag(&p, l, nil, l.slider.x+l.slider.width+40, l.slider.y, 1)
	testing.expect_value(t, ui.field_string(&p.value), "24")
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)

	testing.expect(t, ui.editor_select_key(&p, "scrollback.lines"))
	l = ui.editor_layout(&p, 1200, 900, 1)
	ui.editor_press(&p, l, nil, l.slider.x+l.slider.width*0.25, l.slider.y+2, 1, false)
	small := ui.field_string(&p.value)
	testing.expect(t, len(small) <= 3, small)
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)

	testing.expect(t, ui.editor_select_key(&p, "colors.cursor"))
	l = ui.editor_layout(&p, 1200, 900, 1)
	center_y := l.wheel.y+l.wheel.height/2
	ui.editor_press(&p, l, nil, l.wheel.x+l.wheel.width-0.01, center_y, 1, false)
	testing.expect_value(t, ui.field_string(&p.value), "#ff0000")
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)
	ui.editor_press(&p, l, nil, l.ramp.x+l.ramp.width/2, l.ramp.y+2, 1, false)
	testing.expect_value(t, ui.field_string(&p.value), "#800000")
	ui.editor_release(&p)
	testing.expect_value(t, ui.editor_press(&p, l, nil, l.theme_default.x+2, l.theme_default.y+2, 1, false),
		ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "")
}

@(test)
editor_text_field_selects_and_replaces :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, p.editing)
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_selection(&p), "Mono")
	ui.editor_text(&p, "aé🙂z")
	ui.editor_key(&p, key({key = .Arrow_Left}))
	ui.editor_key(&p, key({key = .Backspace}))
	testing.expect_value(t, ui.field_string(&p.value), "aéz")
	ui.editor_key(&p, key({key = .Home}))
	ui.editor_key(&p, key({key = .Delete}))
	testing.expect_value(t, ui.field_string(&p.value), "éz")
	ui.editor_key(&p, key({key = .End, modifiers = {.Shift}}))
	ui.editor_cut(&p)
	testing.expect_value(t, ui.field_string(&p.value), "")
	ui.editor_paste(&p, "Cascadia\nignored")
	testing.expect_value(t, ui.field_string(&p.value), "Cascadia")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.editor_row(&p).value, "Mono")
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Closed)
	testing.expect(t, !p.open)
}

@(test)
editor_captures_shortcut_keys :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	p.leader = commands.Shortcut{.B, {.Control}}
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect(t, ui.editor_capturing(&p))
	ui.editor_key(&p, key({key = .Control_Left, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Shift+O")
	ui.editor_text(&p, "x")
	ui.editor_paste(&p, "typed")
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Shift+O")
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Tab")
	ui.editor_key(&p, key({key = .X, text = "x"}))
	testing.expect(t, p.error)
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Tab")
	ui.editor_key(&p, key({key = .B, modifiers = {.Control}}))
	testing.expect(t, p.leader_pending)
	ui.editor_key(&p, key({key = .R, text = "r"}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Tab, Leader+R")
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect(t, !ui.editor_capturing(&p))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Shift+O")

	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .Backspace}))
	testing.expect_value(t, ui.field_string(&p.value), "")
	ui.editor_key(&p, key({key = .F5}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "F5")

	testing.expect(t, ui.editor_select_key(&p, "input.leader"))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .B, modifiers = {.Control}}))
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+A")
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, !ui.editor_capturing(&p))
	testing.expect_value(t, p.button_focus, 1)
}

@(test)
editor_layout_hit_targets_scale :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.75, 2}) {
		p: ui.Editor
		defer ui.editor_destroy(&p)
		testing.expect_value(t, ui.editor_add(&p, {key = "x", title = "X"}, "Group"), nil)
		ui.editor_filter(&p)
		ui.editor_select(&p, 1)
		l := ui.editor_layout(&p, 1200*scale, 900*scale, scale)
		testing.expect(t, l.rows > 0)
		testing.expect(t, l.detail.y > l.list.y+l.list.height)
		testing.expect(t, l.value.y+l.value.height < l.save.y)
		testing.expect(t, l.close.x+l.close.width < l.panel.x+l.panel.width)
		testing.expect_value(t, ui.editor_press(&p, l, nil, l.save.x+1, l.save.y+1, scale, false), ui.Editor_Outcome.Save)
		testing.expect_value(t, ui.editor_press(&p, l, nil, l.reset.x+1, l.reset.y+1, scale, false),
			ui.Editor_Outcome.Reset)
		testing.expect_value(t, ui.editor_press(&p, l, nil, l.close.x+1, l.close.y+1, scale, false),
			ui.Editor_Outcome.Closed)
	}
}

@(test)
editor_records_physical_key_positions :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.button_focus, 4)
	ui.editor_key(&p, key({key = .Space, text = " "}))
	testing.expect(t, p.physical)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.button_focus, 0)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, ui.editor_capturing(&p))
	ui.editor_key(&p, key({key = .Z, unshifted = 'y', modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Physical+Ctrl+Z")
	p.physical = false
	ui.editor_key(&p, key({key = .Backspace}))
	ui.editor_key(&p, key({key = .Z, unshifted = 'y', modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Y")
	l := ui.editor_layout(&p, 1200, 900, 1)
	ui.editor_press(&p, l, nil, l.positions.x+2, l.positions.y+2, 1, false)
	testing.expect(t, p.physical)
	testing.expect(t, !ui.editor_capturing(&p))
}
