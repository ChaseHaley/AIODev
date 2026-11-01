package ui

import "aio:render"

@(private)
CHOICE_SEARCH_HEIGHT :: 36

@(private)
choice_searchable :: proc(row: ^Editor_Row) -> bool {
	return row != nil && row.kind == .Choice && row.searchable
}

editor_choice_count :: proc(p: ^Editor, row: ^Editor_Row) -> int {
	return choice_searchable(row) ? len(p.choice_matches) : len(row.choices)
}

@(private)
choice_source_index :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> int {
	return choice_searchable(row) ? p.choice_matches[index] : index
}

// Keep the installed choices intact; only the popup's index map changes while searching.
@(private)
choice_filter :: proc(p: ^Editor, row: ^Editor_Row) {
	choice_matches_filter(&p.choice_matches, row.choices, row.choice_labels, field_string(&p.choice_search))
	p.popup_index, p.popup_scroll = 0, 0
}

@(private)
choice_choose :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	if index < 0 || index >= editor_choice_count(p, row) {return .None}
	return choose(p, row, choice_source_index(p, row, index))
}

@(private)
choice_search_height :: proc(row: ^Editor_Row, scale: f32) -> f32 {
	if !choice_searchable(row) {return 0}
	return (CHOICE_SEARCH_HEIGHT + (row.key == "font.family" ? CHOICE_HEIGHT : 0)) * scale
}

@(private)
choice_font_toggle_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	row := editor_row(p)
	if row == nil || row.key != "font.family" || p.popup != .Choice {return {}}
	r := editor_popup_rect(p, l)
	s := l.scale
	return {r.x + 4 * s, r.y + (4 + CHOICE_SEARCH_HEIGHT) * s, r.width - 8 * s, CHOICE_HEIGHT * s}
}

@(private)
choice_toggle_fonts :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	row.show_all_fonts = !row.show_all_fonts
	row.choices, row.other_font_choices = row.other_font_choices, row.choices
	choice_filter(p, row)
	return .Font_Filter
}

// Restore an open font search after its preference is published through Settings.
editor_font_search_restore :: proc(p: ^Editor, query: string, toggle_focus: bool) {
	row := editor_row(p)
	if !choice_searchable(row) {return}
	p.popup, p.focus = .Choice, .Control
	field_set(&p.choice_search, query)
	p.choice_toggle_focus = toggle_focus
	choice_filter(p, row)
}

@(private)
choice_search_box :: proc(p: ^Editor, l: Editor_Layout, text: ^Text) -> Field_Box {
	r := editor_popup_rect(p, l)
	s := l.scale
	return {
		field = &p.choice_search, text = text,
		rect = {r.x + 4 * s, r.y + 4 * s, r.width - 8 * s, 30 * s},
		inset = 10, caret_width = 1, radius = 4, scale = s,
	}
}
