package ui_test

import "core:testing"
import "core:strings"
import "aio:commands"
import "aio:render"
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
			kind = .Optional_Color, fallback = "#ffffff"}, "Colors"},
		{{key = "scrollback.lines", title = "Scrollback Lines", description = "History.", value = "10000",
			default_value = "10000", kind = .Integer, minimum = 0, maximum = 10000000}, "Scrollback"},
		{{key = "keys.pane.split_right", title = "Split Right", description = "Shortcut.", value = "Ctrl+Shift+O",
			default_value = "Ctrl+Shift+O", kind = .Shortcut}, "Pane Shortcuts"},
		{{key = "input.leader", title = "Leader Key", description = "Prefix.", value = "", kind = .Shortcut},
			"Input"},
	}
	for r in rows { testing.expect_value(t, ui.editor_add(p, r.row, r.group), nil) }
	p.open = true
	ui.editor_filter(p)
}

@(private)
visible_keys :: proc(p: ^ui.Editor) -> [dynamic]string {
	keys := make([dynamic]string, context.temp_allocator)
	for item in p.items { append(&keys, item.row < 0 ? p.groups[item.group].title : p.rows[item.row].key) }
	return keys
}

@(private)
page :: proc(p: ^ui.Editor) -> ui.Editor_Layout {
	l := ui.editor_layout({0, 40, 1200, 1400}, 1)
	p.visible_rows = l.rows
	return l
}

@(private)
center :: proc(r: render.Rect) -> (f32, f32) { return r.x+r.width/2, r.y+r.height/2 }

@(test)
editor_binding_search_and_positions_reserve_description_space :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect_value(t, ui.editor_add(&p,
		{key = "keys.tab.select_8", title = "Select Tab 8", value = "Alt+8, Ctrl+8", kind = .Shortcut},
		"Tab Shortcuts"), nil)
	testing.expect_value(t, ui.editor_add(&p,
		{key = "colors.palette.8", title = "ANSI Bright Black", description = "ANSI palette color 8.",
			kind = .Optional_Color}, "Colors"), nil)
	for query in ([?]string{"alt+8", "al8", "ctrl8", "sltb8"}) {
		ui.field_set(&p.filter, query)
		ui.editor_filter(&p)
		testing.expect_value(t, ui.editor_row(&p).key, "keys.tab.select_8")
	}
	ui.field_set(&p.filter, "")
	ui.editor_filter(&p)
	testing.expect(t, ui.editor_select_key(&p, "input.leader"))
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		for width in ([?]f32{700, 1200, 1400}) {
			l := ui.editor_layout({0, 40*scale, width*scale, 1400*scale}, scale)
			parts := ui.editor_row_parts(&p, l, p.selected)
			testing.expect(t, !parts.positions_label_below)
			testing.expect(t, parts.text_right <= parts.positions.x-12*scale)
			testing.expect(t, parts.positions.x+parts.positions.width+100*scale <= parts.field.x)
		}
		// Narrow windows stack the label below the switch, inside the row and clear of the field.
		for width in ([?]f32{360, 460, 560}) {
			l := ui.editor_layout({0, 40*scale, width*scale, 1400*scale}, scale)
			parts := ui.editor_row_parts(&p, l, p.selected)
			testing.expect(t, parts.positions_label_below)
			testing.expect(t, parts.positions.x >= parts.row.x+30*scale)
			testing.expect(t, parts.text_right <= parts.positions.x-12*scale)
			testing.expect(t, parts.positions.x+parts.positions.width+30*scale <= parts.field.x)
			testing.expect(t, parts.positions.y+parts.positions.height+18*scale <= parts.row.y+parts.row.height)
			testing.expect(t, parts.field.width >= 120*scale)
		}
	}
}

@(test)
editor_outline_jumps_without_filtering_and_tracks_scroll :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	keys := visible_keys(&p)
	browse := len(keys)
	testing.expect_value(t, browse, 15)
	testing.expect_value(t, keys[0], "Panes")
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	l := ui.editor_layout({0, 40, 1200, 500}, 1)
	p.visible_rows = l.rows
	ui.editor_jump(&p, 2)
	testing.expect_value(t, ui.editor_row(&p).key, "cursor.style")
	testing.expect_value(t, ui.editor_active_group(&p), 2)
	testing.expect_value(t, p.scroll, 5)
	testing.expect_value(t, len(p.items), browse)
	testing.expect_value(t, len(p.filter.bytes), 0)
	ui.editor_wheel(&p, l, l.list.x+10, l.list.y+10, 3)
	testing.expect_value(t, p.scroll, 2)
	testing.expect_value(t, ui.editor_active_group(&p), 0)
	ui.editor_key(&p, key({key = .Arrow_Down, modifiers = {.Alt}}))
	testing.expect_value(t, ui.editor_active_group(&p), 1)
	ui.editor_jump(&p, 6)
	testing.expect_value(t, ui.editor_active_group(&p), 6)
	testing.expect(t, p.scroll <= len(p.items)-p.visible_rows)
	ui.editor_wheel(&p, l, l.list.x+10, l.list.y+10, 1)
	testing.expect(t, ui.editor_active_group(&p) != 6)

	ui.editor_text(&p, "panes")
	keys = visible_keys(&p)
	testing.expect_value(t, len(keys), 5)
	testing.expect_value(t, keys[3], "Pane Shortcuts")
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, len(p.filter.bytes), 0)
	testing.expect_value(t, len(visible_keys(&p)), browse)
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.None)

	ui.editor_text(&p, "SPLIT")
	testing.expect_value(t, ui.editor_row(&p).key, "keys.pane.split_right")
	ui.editor_text(&p, " zzz")
	testing.expect_value(t, len(p.items), 0)
	testing.expect_value(t, ui.editor_active_group(&p), -1)
	clear := ui.editor_clear_rect(&p, l)
	testing.expect(t, clear.width > 0)
	testing.expect_value(t, ui.editor_press(&p, l, nil, clear.x+1, clear.y+1, false),
		ui.Editor_Outcome.Changed)
	testing.expect_value(t, len(p.filter.bytes), 0)
	testing.expect_value(t, len(p.items), browse)
}

@(test)
editor_lists_navigate_with_control_n_and_p :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	ui.editor_select(&p, 0)
	testing.expect_value(t, ui.editor_key(&p, key({key = .N, modifiers = {.Control}})), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	ui.editor_key(&p, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.show_headers")
	ui.editor_key(&p, key({key = .P, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_row(&p).key, "pane.gap")
	testing.expect_value(t, len(p.filter.bytes), 0)
}

@(test)
editor_inline_controls_produce_values :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	l := page(&p)

	testing.expect(t, ui.editor_select_key(&p, "pane.show_headers"))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "false")
	parts := ui.editor_row_parts(&p, l, p.selected)
	testing.expect(t, parts.toggle.width > 0 && parts.field.width == 0)
	x, y := center(parts.toggle)
	testing.expect_value(t, ui.editor_press(&p, l, nil, x, y, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "true")

	testing.expect(t, ui.editor_select_key(&p, "cursor.style"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, p.popup, ui.Editor_Popup.Choice)
	ui.editor_key(&p, key({key = .Arrow_Down}))
	ui.editor_key(&p, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "underline")
	testing.expect_value(t, p.popup, ui.Editor_Popup.None)
	parts = ui.editor_row_parts(&p, l, p.selected)
	x, y = center(parts.field)
	ui.editor_press(&p, l, nil, x, y, false)
	popup := ui.editor_popup_rect(&p, l)
	testing.expect(t, popup.y > parts.field.y)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+10, popup.y+4+30*1.5, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "bar")
	ui.editor_press(&p, l, nil, x, y, false)
	testing.expect_value(t, ui.editor_press(&p, l, nil, 5, 5, false), ui.Editor_Outcome.Changed)
	testing.expect_value(t, p.popup, ui.Editor_Popup.None)

	testing.expect(t, ui.editor_select_key(&p, "pane.gap"))
	parts = ui.editor_row_parts(&p, l, p.selected)
	testing.expect(t, parts.slider.width > 0 && parts.field.width > 0)
	ui.editor_press(&p, l, nil, parts.slider.x+parts.slider.width*0.5, parts.slider.y+2, false)
	testing.expect_value(t, ui.field_string(&p.value), "12")
	ui.editor_drag(&p, l, nil, parts.slider.x+parts.slider.width+40, parts.slider.y)
	testing.expect_value(t, ui.field_string(&p.value), "24")
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)

	testing.expect(t, ui.editor_select_key(&p, "scrollback.lines"))
	parts = ui.editor_row_parts(&p, l, p.selected)
	ui.editor_press(&p, l, nil, parts.slider.x+parts.slider.width*0.25, parts.slider.y+2, false)
	small := ui.field_string(&p.value)
	testing.expect(t, len(small) <= 3, small)
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)

	testing.expect(t, ui.editor_select_key(&p, "colors.cursor"))
	parts = ui.editor_row_parts(&p, l, p.selected)
	testing.expect(t, ui.editor_popup_rect(&p, l).width == 0)
	x, y = center(parts.swatch)
	ui.editor_press(&p, l, nil, x, y, false)
	testing.expect_value(t, p.popup, ui.Editor_Popup.Color)
	popup = ui.editor_popup_rect(&p, l)
	wheel := render.Rect{popup.x+12, popup.y+12, 140, 140}
	ui.editor_press(&p, l, nil, wheel.x+wheel.width-0.01, wheel.y+wheel.height/2, false)
	testing.expect_value(t, ui.field_string(&p.value), "#ff0000")
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Save)
	ui.editor_press(&p, l, nil, popup.x+168+56, popup.y+24+8, false)
	testing.expect_value(t, ui.field_string(&p.value), "#800000")
	ui.editor_release(&p)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+20, popup.y+170, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "")
	testing.expect_value(t, p.popup, ui.Editor_Popup.None)
}

@(test)
editor_reset_buttons_and_pointer_shapes :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	l := page(&p)
	for index in 0..<len(p.items) {
		if p.items[index].row < 0 { continue }
		parts := ui.editor_row_parts(&p, l, index)
		testing.expect(t, parts.reset.width > 0)
		testing.expect(t, parts.field.width == 0 || parts.field.x+parts.field.width <= parts.reset.x)
	}
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	parts := ui.editor_row_parts(&p, l, p.selected)
	x, y := center(parts.reset)
	testing.expect(t, ui.editor_hover(&p, l, x, y))
	testing.expect_value(t, p.hover_reset, p.selected)
	testing.expect_value(t, ui.editor_press(&p, l, nil, x, y, false), ui.Editor_Outcome.Reset)
	fx, fy := center(parts.field)
	testing.expect(t, ui.editor_over_text(&p, l, fx, fy))
	testing.expect(t, !ui.editor_over_text(&p, l, x, y))
	testing.expect(t, !ui.editor_over_text(&p, l, parts.row.x+20, fy))
	cx, cy := center(l.filter)
	testing.expect(t, ui.editor_over_text(&p, l, cx, cy))
	testing.expect(t, ui.editor_select_key(&p, "pane.show_headers"))
	toggle := ui.editor_row_parts(&p, l, p.selected).toggle
	tx, ty := center(toggle)
	testing.expect(t, !ui.editor_over_text(&p, l, tx, ty))
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	sx, sy := center(ui.editor_row_parts(&p, l, p.selected).field)
	testing.expect(t, !ui.editor_over_text(&p, l, sx, sy))
}

@(test)
editor_text_field_selects_and_replaces :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, ui.editor_editing(&p))
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
	testing.expect_value(t, ui.editor_key(&p, key({key = .Escape})), ui.Editor_Outcome.Changed)
	testing.expect(t, !ui.editor_editing(&p))
	testing.expect_value(t, ui.field_string(&p.value), "Mono")
	testing.expect(t, ui.editor_select_key(&p, "cursor.style"))
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.popup, ui.Editor_Popup.Choice)
	ui.editor_text(&p, "gap")
	testing.expect(t, !ui.editor_editing(&p))
	testing.expect_value(t, ui.field_string(&p.filter), "gap")
}

@(test)
editor_captures_shortcut_keys :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	p.leader = commands.Shortcut{.B, {.Control}}
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, p.popup, ui.Editor_Popup.Shortcuts)
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
	ui.editor_key(&p, key({key = .B, modifiers = {.Control}}))
	testing.expect(t, p.leader_pending)
	ui.editor_key(&p, key({key = .R, text = "r"}))
	testing.expect_value(t, ui.field_string(&p.value), "Leader+R")
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect(t, !ui.editor_capturing(&p))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Shift+O")

	ui.editor_key(&p, key({key = .Enter}))
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
	testing.expect_value(t, p.focus, ui.Editor_Focus.Positions)
}

@(test)
editor_alternatives_preserve_neighbors_and_allow_many_additions :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	row := ui.editor_row(&p)
	delete(row.value)
	row.value = strings.clone("Ctrl+O, Alt+O, F6")
	ui.editor_select(&p, p.selected)
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .Arrow_Down}))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .F7}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+O, F7, F6")
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, ui.field_string(&p.value), row.value)
	ui.editor_key(&p, key({key = .Enter}))
	for _ in 0..<3 { ui.editor_key(&p, key({key = .Arrow_Down})) }
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .F8}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+O, Alt+O, F6, F8")
	ui.editor_key(&p, key({key = .Escape}))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Delete})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+O, F6")
	ui.editor_select(&p, p.selected)
	ui.editor_key(&p, key({key = .Enter}))
	l := page(&p)
	popup := ui.editor_popup_rect(&p, l)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+popup.width-12, popup.y+4+45, false),
		ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+O, F6")
}

@(test)
editor_adds_beyond_four_and_scrolls_shortcut_alternatives :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	row := ui.editor_row(&p)
	delete(row.value)
	row.value = strings.clone("F1, F2, F3, F4, F5, F6, F7, F8, F9")
	ui.editor_select(&p, p.selected)
	ui.editor_key(&p, key({key = .Enter}))
	for _ in 0..<9 { ui.editor_key(&p, key({key = .Arrow_Down})) }
	testing.expect_value(t, p.popup_index, 9)
	testing.expect(t, p.popup_scroll > 0)
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .F10}))
	testing.expect_value(t, ui.field_string(&p.value), "F1, F2, F3, F4, F5, F6, F7, F8, F9, F10")
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, p.message, "")
}

@(test)
typography_sliders_use_whole_points_and_fine_line_height_steps :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	for row in ([?]ui.Editor_Row{
		{key = "font.size", title = "Font Size", value = "12", kind = .Number, minimum = 6, maximum = 32},
		{key = "font.line_height", title = "Line Height", value = "1", kind = .Number, minimum = 0.8, maximum = 2},
	}) { testing.expect_value(t, ui.editor_add(&p, row, "Font"), nil) }
	ui.editor_filter(&p)
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "font.size"))
	parts := ui.editor_row_parts(&p, l, p.selected)
	ui.editor_press(&p, l, nil, parts.slider.x+parts.slider.width*0.037, parts.slider.y+2, false)
	testing.expect_value(t, ui.field_string(&p.value), "7")
	ui.editor_release(&p)
	testing.expect(t, ui.editor_select_key(&p, "font.line_height"))
	parts = ui.editor_row_parts(&p, l, p.selected)
	ui.editor_press(&p, l, nil, parts.slider.x+parts.slider.width*0.375, parts.slider.y+2, false)
	testing.expect_value(t, ui.field_string(&p.value), "1.25")
}

@(test)
editor_records_physical_key_positions :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.focus, ui.Editor_Focus.Positions)
	ui.editor_key(&p, key({key = .Space, text = " "}))
	testing.expect(t, p.physical)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.focus, ui.Editor_Focus.Search)
	ui.editor_key(&p, key({key = .Tab}))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect(t, ui.editor_capturing(&p))
	ui.editor_key(&p, key({key = .Z, unshifted = 'y', modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Physical+Ctrl+Z")
	p.physical = false
	ui.editor_key(&p, key({key = .Backspace}))
	ui.editor_key(&p, key({key = .Z, unshifted = 'y', modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Y")
	positions := ui.editor_row_parts(&p, l, p.selected).positions
	testing.expect(t, positions.width > 0)
	x, y := center(positions)
	ui.editor_press(&p, l, nil, x, y, false)
	testing.expect(t, p.physical)
}
