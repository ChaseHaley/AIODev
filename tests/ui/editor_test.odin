package ui_test

import "core:testing"
import "core:strings"
import "aio:commands"
import "aio:render"
import "aio:settings"
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
		{{key = "input.leader", title = "Leader Key", description = "Prefix.", value = "", kind = .Shortcut,
			shortcut_mode = .Single},
			"Input"},
	}
	for r in rows { testing.expect_value(t, ui.editor_add(p, r.row, r.group), nil) }
	ui.editor_filter(p)
	_ = page(p)
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
	ui.editor_fit(p, l)
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

@(rodata, private)
section_titles := [?]string{"General", "Colors", "Shortcuts"}

@(test)
editor_sections_scope_browsing_and_search_spans_them :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	p.sections = section_titles[:]
	for &group in p.groups {
		switch group.title {
		case "Colors":
			group.section = 1
		case "Input":
			group.section, group.rank = 2, 0
		case "Pane Shortcuts":
			group.section, group.rank = 2, 1
		}
	}
	ui.editor_filter(&p)
	keys := visible_keys(&p)
	testing.expect_value(t, len(keys), 9)
	for key in keys {testing.expect(t, !strings.has_prefix(key, "colors.") && !strings.has_prefix(key, "keys."))}

	// A search lists every section; each tab counts its matches.
	ui.field_set(&p.filter, "cursor")
	ui.editor_filter(&p)
	testing.expect_value(t, len(visible_keys(&p)), 4)
	l := ui.editor_layout({0, 40, 1200, 1400}, 1, true)
	ui.editor_fit(&p, l)
	press_tab :: proc(p: ^ui.Editor, l: ui.Editor_Layout, section: int) {
		x, y := center(ui.editor_section_rect(p, l, section))
		_ = ui.editor_press(p, l, nil, x, y, false)
	}

	// A tab narrows the search to its section and keeps counting every section; the same tab
	// again lists them all, and so does editing the search.
	press_tab(&p, l, 1)
	testing.expect_value(t, ui.field_string(&p.filter), "cursor")
	keys = visible_keys(&p)
	if testing.expect_value(t, len(keys), 2) {testing.expect_value(t, keys[1], "colors.cursor")}
	counts := ui.editor_section_counts(&p)
	testing.expect_value(t, counts[0], 1)
	testing.expect_value(t, counts[1], 1)
	testing.expect_value(t, counts[2], 0)
	press_tab(&p, l, 1)
	testing.expect_value(t, len(visible_keys(&p)), 4)
	press_tab(&p, l, 0)
	testing.expect_value(t, len(visible_keys(&p)), 2)
	ui.editor_filter(&p)
	testing.expect_value(t, len(visible_keys(&p)), 4)

	// A row in a section the search is not narrowed to is still reachable by key.
	press_tab(&p, l, 0)
	testing.expect(t, ui.editor_select_key(&p, "colors.cursor"))
	testing.expect_value(t, len(visible_keys(&p)), 4)

	// Without a search a tab shows its groups in rank order, not the order they were added in.
	ui.field_set(&p.filter, "")
	ui.editor_filter(&p)
	press_tab(&p, l, 2)
	keys = visible_keys(&p)
	if testing.expect_value(t, len(keys), 4) {
		testing.expect_value(t, keys[0], "Input")
		testing.expect_value(t, keys[2], "Pane Shortcuts")
	}

	// Selecting a row by key reaches its section, as a palette jump does.
	testing.expect(t, ui.editor_select_key(&p, "colors.cursor"))
	testing.expect_value(t, p.section, 1)
	testing.expect_value(t, ui.editor_row(&p).key, "colors.cursor")
}

@(test)
editor_page_scrollbar_drags_to_the_last_line :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	l := ui.editor_layout({0, 40, 1200, 400}, 1)
	ui.editor_fit(&p, l)
	bar, visible := ui.editor_page_scrollbar(&p, l)
	if !testing.expect(t, visible) {return}
	x, y := center(bar.thumb)
	_ = ui.editor_press(&p, l, nil, x, y, false)
	testing.expect(t, ui.editor_scrollbar_dragging(&p))
	testing.expect(t, ui.editor_drag(&p, l, nil, x, bar.track.y + bar.track.height + 100))
	testing.expect_value(t, p.scroll, len(p.items) - l.rows)
	testing.expect_value(t, ui.editor_release(&p), ui.Editor_Outcome.Changed)
	testing.expect(t, !ui.editor_scrollbar_dragging(&p))
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
	ui.editor_fit(&p, l)
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
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Choice)
	ui.editor_key(&p, key({key = .Arrow_Down}))
	ui.editor_key(&p, key({key = .N, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "underline")
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)
	parts = ui.editor_row_parts(&p, l, p.selected)
	x, y = center(parts.field)
	ui.editor_press(&p, l, nil, x, y, false)
	popup := ui.editor_popup_rect(&p, l)
	testing.expect(t, popup.y > parts.field.y)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+10, popup.y+4+30*1.5, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, ui.field_string(&p.value), "bar")
	ui.editor_press(&p, l, nil, x, y, false)
	testing.expect_value(t, ui.editor_press(&p, l, nil, 5, 5, false), ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)

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
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Color)
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
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)
}

@(test)
editor_choice_popup_highlights_the_option_under_the_pointer :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	ui.editor_hover_clear(&p)
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "cursor.style"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Choice)
	popup := ui.editor_popup_rect(&p, l)
	second := popup.y + 4 + 30 * 1.5
	testing.expect(t, ui.editor_hover(&p, l, popup.x+10, second))
	testing.expect_value(t, p.choice_list.index, 1)
	// The same option reports no change once it is already highlighted.
	testing.expect(t, !ui.editor_hover(&p, l, popup.x+10, second))
	// Below the popup must not steal the highlight from the open list.
	testing.expect(t, !ui.editor_hover(&p, l, popup.x+10, popup.y+popup.height+40))
	testing.expect_value(t, p.choice_list.index, 1)
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
	// Tab focuses a list without opening it, and typing does not leave it for the search.
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, ui.editor_editing(&p))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)
	ui.editor_text(&p, "gap")
	testing.expect(t, ui.editor_editing(&p))
	testing.expect_value(t, ui.field_string(&p.filter), "")
	ui.editor_key(&p, key({key = .Space, text = " "}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Choice)
	// Ctrl+F takes the keyboard to the search, even from an open list.
	ui.editor_key(&p, key({key = .F, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Search)
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)
	ui.editor_text(&p, "gap")
	testing.expect_value(t, ui.field_string(&p.filter), "gap")
}

@(test)
editor_tab_walks_the_page_like_a_browser :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	testing.expect(t, ui.editor_select_key(&p, "pane.show_headers"))
	before := ui.editor_row(&p).value
	first := p.selected
	// The search shows its Ctrl+F keycap only while the keyboard is elsewhere, beside its text.
	l := page(&p)
	testing.expect_value(t, ui.editor_search_key_rect(&p, l).width, 0)
	// Landing on a switch focuses it without flipping it; the next Tab moves to the next row.
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	testing.expect_value(t, ui.field_string(&p.value), before)
	search_key := ui.editor_search_key_rect(&p, l)
	testing.expect(t, search_key.width > 0)
	testing.expect(t, search_key.x + search_key.width <= l.filter.x + l.filter.width)
	testing.expect(t, !ui.editor_over_text(&p, l, search_key.x + search_key.width / 2, search_key.y + 2))
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, p.selected > first)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.selected, first)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	// Before the first row lies the search, past the last Reset to Defaults, and round again.
	ui.editor_key(&p, key({key = .F, modifiers = {.Control}}))
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Reset_All)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	last := len(p.items) - 1
	for last >= 0 && p.items[last].row < 0 {last -= 1}
	testing.expect_value(t, p.selected, last)
	testing.expect(t, ui.editor_focus(&p) != ui.Editor_Focus.Search)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Reset_All)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Search)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.selected, last)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
}

@(test)
editor_press_off_the_search_takes_its_keyboard :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "pane.show_headers"))
	before := ui.editor_row(&p).value
	// A press on a row, away from its switch, focuses the switch without flipping it.
	row := ui.editor_row_parts(&p, l, p.selected).row
	testing.expect_value(t, ui.editor_press(&p, l, nil, row.x + 4, row.y + row.height / 2, false),
		ui.Editor_Outcome.Changed)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	testing.expect_value(t, ui.field_string(&p.value), before)
	ui.editor_text(&p, "zz")
	testing.expect_value(t, ui.field_string(&p.filter), "")
	// A press on the page outside any control leaves nothing focused: typing goes nowhere, the
	// search shows its Ctrl+F keycap, Tab resumes at the selected row and Ctrl+F returns.
	ui.editor_key(&p, key({key = .F, modifiers = {.Control}}))
	ui.editor_text(&p, "pane")
	ui.editor_press(&p, l, nil, l.page.x + 2, l.page.y + 2, false)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Page)
	ui.editor_text(&p, "y")
	testing.expect_value(t, ui.field_string(&p.filter), "pane")
	testing.expect(t, ui.editor_search_key_rect(&p, l).width > 0)
	selected := p.selected
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, p.selected, selected)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	ui.editor_press(&p, l, nil, l.page.x + 2, l.page.y + 2, false)
	ui.editor_key(&p, key({key = .F, modifiers = {.Control}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Search)
}

@(test)
editor_captures_shortcut_keys :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	p.capture.leader = commands.Shortcut{.B, {.Control}}
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Shortcuts)
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
	testing.expect_value(t, p.capture.state, ui.Shortcut_Capture_State.Leader_Pending)
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
	// Saving keeps the capture's message, so a refused save that resumes the capture still shows it.
	testing.expect_value(t, p.message, ui.CAPTURE_HINT)

	testing.expect(t, ui.editor_select_key(&p, "input.leader"))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .B, modifiers = {.Control}}))
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+A")
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, !ui.editor_capturing(&p))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Positions)
	testing.expect_value(t, p.message, "")
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
	testing.expect_value(t, p.capture.alternatives.index, 9)
	testing.expect(t, p.capture.alternatives.scroll > 0)
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
		{key = "font.size", title = "Font Size", value = "12", kind = .Number, minimum = 6, maximum = 32,
			step = 1},
		{key = "font.line_height", title = "Line Height", value = "1", kind = .Number, minimum = 0.8,
			maximum = 2, step = 0.05},
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
	shortcut := p.selected
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Positions)
	ui.editor_key(&p, key({key = .Space, text = " "}))
	testing.expect(t, p.capture.physical)
	// Shift+Tab from the next row comes back to the switch, then to the field.
	ui.editor_key(&p, key({key = .Tab}))
	testing.expect(t, p.selected != shortcut)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, p.selected, shortcut)
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Positions)
	ui.editor_key(&p, key({key = .Tab, modifiers = {.Shift}}))
	testing.expect_value(t, ui.editor_focus(&p), ui.Editor_Focus.Control)
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Shortcuts)
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect(t, ui.editor_capturing(&p))
	ui.editor_key(&p, key({key = .Z, unshifted = 'y', modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Physical+Ctrl+Z")
	p.capture.physical = false
	ui.editor_key(&p, key({key = .Backspace}))
	ui.editor_key(&p, key({key = .Z, unshifted = 'y', modifiers = {.Control}}))
	testing.expect_value(t, ui.field_string(&p.value), "Ctrl+Y")
	positions := ui.editor_row_parts(&p, l, p.selected).positions
	testing.expect(t, positions.width > 0)
	x, y := center(positions)
	ui.editor_press(&p, l, nil, x, y, false)
	testing.expect(t, p.capture.physical)
}

@(test)
editor_multiple_choice_toggles_options_and_stays_open :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	entry := settings.schema_find("status.notify_blocked")
	if !testing.expect(t, entry != nil) {return}
	row := ui.schema_row(entry^)
	row.value = "banner, sound"
	// The page edits option bits; its owner projects them from the value and saves their names.
	row.choice_mask, _, _ = settings.set_parse(row.choices, row.value)
	testing.expect(t, row.multiple)
	testing.expect_value(t, ui.editor_add(&p, row, "Program Status"), nil)
	ui.editor_filter(&p)
	l := page(&p)
	testing.expect(t, ui.editor_select_key(&p, "status.notify_blocked"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Choice)
	testing.expect_value(t, p.choice_list.index, 0)
	// Enter flips the highlighted option and leaves the list open for the next one.
	testing.expect_value(t, ui.editor_key(&p, key({key = .Enter})), ui.Editor_Outcome.Save)
	testing.expect_value(t, settings.set_text(row.choices, ui.editor_choice_set(&p)), "sound")
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Choice)
	ui.editor_key(&p, key({key = .Arrow_Down}))
	testing.expect_value(t, ui.editor_key(&p, key({key = .Space})), ui.Editor_Outcome.Save)
	testing.expect_value(t, settings.set_text(row.choices, ui.editor_choice_set(&p)), "tray, sound")
	popup := ui.editor_popup_rect(&p, l)
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+10, popup.y+4+30*3.5, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, settings.set_text(row.choices, ui.editor_choice_set(&p)), "tray")
	testing.expect_value(t, ui.editor_press(&p, l, nil, popup.x+10, popup.y+4+30*1.5, false), ui.Editor_Outcome.Save)
	testing.expect_value(t, settings.set_text(row.choices, ui.editor_choice_set(&p)), "none")
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Choice)
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.None)
}

@(test)
settings_page_revision_tracks_edits_navigation_and_external_conflicts :: proc(t: ^testing.T) {
	p: ui.Editor
	defer ui.editor_destroy(&p)
	editor_fixture(t, &p)
	source, err := strings.clone("font.family = Mono\n")
	if !testing.expect_value(t, err, nil) {return}
	ui.editor_revision_open(&p, source)
	_, current := p.revision.(ui.Editor_Current)
	testing.expect(t, current)
	testing.expect(t, !ui.editor_draft(&p))
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	ui.editor_text(&p, "Other")
	testing.expect(t, ui.editor_draft(&p))
	_, current = p.revision.(ui.Editor_Current)
	testing.expect(t, current, "a draft does not change the page's revision")
	testing.expect_value(t, ui.field_string(&p.value), "Other")
	testing.expect_value(t, ui.editor_source(&p), source)
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	ui.editor_text(&p, "Mono")
	testing.expect(t, !ui.editor_draft(&p), "restoring the saved value ends the draft")
	testing.expect(t, ui.editor_select_key(&p, "keys.pane.split_right"))
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect_value(t, ui.editor_popup(&p), ui.Editor_Popup.Shortcuts)
	testing.expect(t, !ui.editor_draft(&p), "opening the shortcut menu is not a draft")
	ui.editor_key(&p, key({key = .Enter}))
	testing.expect(t, ui.editor_draft(&p), "capture is a draft before a key is recorded")
	ui.editor_key(&p, key({key = .Escape}))
	testing.expect(t, !ui.editor_draft(&p), "cancelling capture returns to the saved value")
	ui.editor_revision_stale(&p, .Changed_Outside)
	testing.expect(t, ui.editor_select_key(&p, "font.family"))
	ui.editor_key(&p, key({key = .Enter}))
	ui.editor_key(&p, key({key = .A, modifiers = {.Control}}))
	ui.editor_text(&p, "Pending")
	stale, is_stale := p.revision.(ui.Editor_Stale)
	testing.expect(t, is_stale, "editing a stale page cannot make its old source current")
	testing.expect_value(t, stale.reason, ui.Editor_Stale_Reason.Changed_Outside)
	testing.expect_value(t, ui.field_string(&p.value), "Pending")
	testing.expect_value(t, ui.editor_source(&p), source)
}
