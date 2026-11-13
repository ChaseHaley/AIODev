package ui_test

import "aio:font"
import "aio:ui"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
LONG_DESCRIPTION :: "Accept commands from the aio command line, which scripts and coding agents use to open " +
	"tabs and panes, send them text and read their screens. Only programs running as you on this " +
	"computer can connect."

// Twenty short rows, then the long row, then one more short row, in one group.
@(private = "file")
wrap_fixture :: proc(t: ^testing.T, p: ^ui.Editor, text: ^ui.Text, fonts: ^font.System) -> bool {
	if !testing.expect(t, ui.text_init(text, fonts, nil, 13)) {return false}
	for i in 0 ..< 20 {
		row := ui.Editor_Row {
			key = fmt.tprintf("row.%d", i), title = "Row", description = "Short.", kind = .Toggle,
			value = "false",
		}
		if !testing.expect_value(t, ui.editor_add(p, row, "Group"), nil) {return false}
	}
	long := ui.Editor_Row {
		key = "control.enabled", title = "Command line control", description = LONG_DESCRIPTION,
		kind = .Toggle, value = "false", default_value = "false",
	}
	next := ui.Editor_Row{key = "after", title = "After", description = "Short.", kind = .Toggle, value = "false"}
	if !testing.expect_value(t, ui.editor_add(p, long, "Group"), nil) {return false}
	if !testing.expect_value(t, ui.editor_add(p, next, "Group"), nil) {return false}
	ui.editor_filter(p)
	return true
}

@(private = "file")
item_of :: proc(p: ^ui.Editor, key: string) -> int {
	for item, index in p.items {
		if item.row >= 0 && item.part == 0 && p.rows[item.row].key == key {return index}
	}
	return -1
}

// The lines the description takes in its row: wrapped to the space left of the control.
@(private = "file")
expected_lines :: proc(text: ^ui.Text, parts: ui.Row_Parts, scale: f32) -> []string {
	small := ui.text_styled(text, .Detail)
	width := parts.text_right - (parts.row.x + (ui.CONTROL_INSET + ui.SPACE_6) * scale)
	lines := make([dynamic]string, context.temp_allocator)
	ui.wrap(&small, LONG_DESCRIPTION, width, &lines)
	return lines[:]
}

@(private = "file")
near :: proc(a, b: f32) -> bool {return abs(a - b) < 0.01}

@(test)
editor_wrapped_description_sets_row_height_at_two_widths :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	p: ui.Editor
	defer ui.editor_destroy(&p)
	text: ui.Text
	if !wrap_fixture(t, &p, &text, fonts) {return}
	small := ui.text_styled(&text, .Detail)
	heights: [2]f32
	for width, i in ([?]f32{1000, 560}) {
		l := ui.editor_layout({0, 0, width, 2000}, 1)
		ui.editor_fit(&p, l, &text)
		long := ui.editor_row_parts(&p, l, item_of(&p, "control.enabled"))
		lines := expected_lines(&text, long, 1)
		testing.expect(t, len(lines) > 1, "the description must not fit on one line")
		testing.expect(t, near(long.row.height, l.row_height + f32(len(lines) - 1) * small.line_height))
		heights[i] = long.row.height
		// The control stays beside the title and first description line.
		testing.expect(t, near(long.toggle.y + long.toggle.height / 2, long.row.y + l.row_height / 2))
		short := ui.editor_row_parts(&p, l, item_of(&p, "after"))
		testing.expect(t, near(short.row.height, l.row_height))
		testing.expect(t, near(short.row.y, long.row.y + long.row.height))
	}
	testing.expect(t, heights[1] > heights[0], "a narrower page wraps to more lines")
	// Without a text to measure with, the rows keep the heights they were wrapped to.
	l := ui.editor_layout({0, 0, 560, 2000}, 1)
	ui.editor_fit(&p, l)
	testing.expect(t, near(ui.editor_row_parts(&p, l, item_of(&p, "control.enabled")).row.height, heights[1]))
}

@(test)
editor_press_after_a_wrapped_row_lands_on_the_row_drawn :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	p: ui.Editor
	defer ui.editor_destroy(&p)
	text: ui.Text
	if !wrap_fixture(t, &p, &text, fonts) {return}
	l := ui.editor_layout({0, 0, 560, 2000}, 1)
	ui.editor_fit(&p, l, &text)
	long := ui.editor_row_parts(&p, l, item_of(&p, "control.enabled"))
	after := ui.editor_row_parts(&p, l, item_of(&p, "after"))
	x := long.row.x + 60
	// The wrapped description's last line, below the row's first ROW_HEIGHT.
	_ = ui.editor_press(&p, l, nil, x, long.row.y + long.row.height - 4, false)
	_ = ui.editor_release(&p)
	testing.expect_value(t, ui.editor_row(&p).key, "control.enabled")
	_ = ui.editor_press(&p, l, nil, x, after.row.y + 4, false)
	_ = ui.editor_release(&p)
	testing.expect_value(t, ui.editor_row(&p).key, "after")
	_ = ui.editor_press(&p, l, nil, x, after.row.y + after.row.height - 4, false)
	_ = ui.editor_release(&p)
	testing.expect_value(t, ui.editor_row(&p).key, "after")
}

@(test)
editor_selecting_a_wrapped_row_scrolls_all_of_it_into_view :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	p: ui.Editor
	defer ui.editor_destroy(&p)
	text: ui.Text
	if !wrap_fixture(t, &p, &text, fonts) {return}
	l := ui.editor_layout({0, 0, 560, 400}, 1)
	ui.editor_fit(&p, l, &text)
	testing.expect(t, ui.editor_select_key(&p, "control.enabled"))
	ui.editor_fit(&p, l, &text)
	long := ui.editor_row_parts(&p, l, p.selected)
	testing.expect(t, long.row.height > l.row_height)
	testing.expect_value(t, p.scroll_fraction, 0)
	testing.expect(t, long.row.y >= l.list.y - 0.01, "the row's top shows")
	testing.expect(t, long.row.y + long.row.height <= l.list.y + l.list.height + 0.01, "its last line shows")
	// Stepping down from it brings the next row in whole, below the wrapped one.
	ui.editor_key(&p, key({key = .Arrow_Down}))
	ui.editor_fit(&p, l, &text)
	after := ui.editor_row_parts(&p, l, p.selected)
	testing.expect_value(t, ui.editor_row(&p).key, "after")
	long = ui.editor_row_parts(&p, l, item_of(&p, "control.enabled"))
	testing.expect(t, near(after.row.y, long.row.y + long.row.height))
	testing.expect(t, after.row.y + after.row.height <= l.list.y + l.list.height + 0.01)
	// The page's last line meets the bottom of the list at the furthest scroll.
	p.scroll = 1000
	ui.editor_fit(&p, l, &text)
	after = ui.editor_row_parts(&p, l, item_of(&p, "after"))
	testing.expect(t, abs(after.row.y + after.row.height - (l.list.y + l.list.height)) < 0.01)
	bar, visible := ui.editor_page_scrollbar(&p, l)
	testing.expect(t, visible)
	testing.expect(t, abs(bar.thumb.y + bar.thumb.height - (bar.track.y + bar.track.height)) < 1)
}

@(test)
editor_search_matches_words_on_a_wrapped_line :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	p: ui.Editor
	defer ui.editor_destroy(&p)
	text: ui.Text
	if !wrap_fixture(t, &p, &text, fonts) {return}
	l := ui.editor_layout({0, 0, 1000, 700}, 1)
	ui.editor_fit(&p, l, &text)
	lines := expected_lines(&text, ui.editor_row_parts(&p, l, item_of(&p, "control.enabled")), 1)
	if !testing.expect(t, len(lines) > 1) {return}
	query := "this computer"
	testing.expect(t, !strings.contains(lines[0], query), "the words are past the first line")
	testing.expect(t, strings.contains(lines[len(lines) - 1], query))
	ui.field_set(&p.filter, query)
	ui.editor_filter(&p)
	ui.editor_fit(&p, l, &text)
	index := item_of(&p, "control.enabled")
	if !testing.expect(t, index >= 0, "the search finds the row by its wrapped words") {return}
	testing.expect_value(t, item_of(&p, "after"), -1)
	small := ui.text_styled(&text, .Detail)
	testing.expect(t, near(ui.editor_row_parts(&p, l, index).row.height,
		l.row_height + f32(len(lines) - 1) * small.line_height))
}

// The pointer over the first description line of the row at page line `index`, and the tooltip
// the page offers there.
@(private = "file")
description_tooltip_at :: proc(p: ^ui.Editor, l: ui.Editor_Layout, text: ^ui.Text, index: int) -> string {
	r := ui.editor_row_parts(p, l, index).row
	small := ui.text_styled(text, .Detail)
	top := r.y + (l.row_height - text.line_height - 2 - small.line_height) / 2
	x := r.x + ui.CONTROL_INSET + ui.SPACE_6 + 6
	_ = ui.editor_hover(p, l, x, top + text.line_height + 2 + small.line_height / 2, text)
	return ui.editor_description_tooltip(p)
}

@(test)
editor_cut_description_offers_its_whole_text_as_a_tooltip :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	p: ui.Editor
	defer ui.editor_destroy(&p)
	text: ui.Text
	if !wrap_fixture(t, &p, &text, fonts) {return}
	huge := strings.repeat(LONG_DESCRIPTION + " ", 6, context.temp_allocator)
	capped := ui.Editor_Row{key = "capped", title = "Capped", description = huge, kind = .Toggle, value = "false"}
	if !testing.expect_value(t, ui.editor_add(&p, capped, "Group"), nil) {return}
	ui.editor_filter(&p)
	// Wrapped whole, or short enough for one line: nothing to show.
	l := ui.editor_layout({0, 0, 560, 4000}, 1)
	ui.editor_fit(&p, l, &text)
	testing.expect_value(t, description_tooltip_at(&p, l, &text, item_of(&p, "control.enabled")), "")
	testing.expect_value(t, description_tooltip_at(&p, l, &text, item_of(&p, "after")), "")
	// Past the line cap the last line ends in an ellipsis, and the tooltip holds all of it.
	testing.expect_value(t, description_tooltip_at(&p, l, &text, item_of(&p, "capped")), huge)
	// Left under 80 DIP the description keeps one ellipsized line.
	narrow := ui.editor_layout({0, 0, 300, 4000}, 1)
	ui.editor_fit(&p, narrow, &text)
	long := item_of(&p, "control.enabled")
	testing.expect(t, near(ui.editor_row_parts(&p, narrow, long).row.height, narrow.row_height))
	testing.expect_value(t, description_tooltip_at(&p, narrow, &text, long), LONG_DESCRIPTION)
	testing.expect_value(t, description_tooltip_at(&p, narrow, &text, item_of(&p, "after")), "")
	// Off the description, even on its row, there is none.
	r := ui.editor_row_parts(&p, narrow, long).row
	_ = ui.editor_hover(&p, narrow, r.x + 40, r.y + 6, &text)
	testing.expect_value(t, ui.editor_description_tooltip(&p), "")
}
