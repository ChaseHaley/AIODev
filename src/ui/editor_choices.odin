package ui

import "aio:render"
import "core:strings"

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
	p.choice_list = {}
}

@(private)
choice_choose :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	if index < 0 || index >= editor_choice_count(p, row) {return .None}
	return choose(p, row, choice_source_index(p, row, index))
}

@(private)
choice_search_height :: proc(row: ^Editor_Row, scale: f32) -> f32 {
	if !choice_searchable(row) {return 0}
	return (CHOICE_SEARCH_HEIGHT + (row.font_filter ? CHOICE_HEIGHT : 0)) * scale
}

@(private)
choice_font_toggle_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	row := editor_row(p)
	if row == nil || !row.font_filter || editor_popup(p) != .Choice {return {}}
	r := editor_popup_rect(p, l)
	s := l.scale
	return {r.x + 4 * s, r.y + (4 + CHOICE_SEARCH_HEIGHT) * s, r.width - 8 * s, CHOICE_HEIGHT * s}
}

// Restore an open font search after its preference is published through Settings.
editor_font_search_restore :: proc(p: ^Editor, query: string, toggle_focus: bool) {
	row := editor_row(p)
	if !choice_searchable(row) {return}
	editor_mode_set(p, Editor_Choice_Popup{toggle_focus = toggle_focus})
	field_set(&p.choice_search, query)
	choice_filter(p, row)
}

@(private)
choice_search_box :: proc(p: ^Editor, l: Editor_Layout, text: ^Text) -> Field_Box {
	r := editor_popup_rect(p, l)
	s := l.scale
	return {
		field = &p.choice_search, text = text,
		rect = {r.x + 4 * s, r.y + 4 * s, r.width - 8 * s, HEIGHT_STANDARD * s},
		inset = CONTROL_INSET, caret_width = 1, radius = RADIUS_CONTROL, style = .Body, scale = s,
	}
}

// The options a multiple choice has on: the pending bits of the selected row, which its owner saves
// by name.
editor_choice_set :: proc(p: ^Editor) -> u32 {
	return p.choice_set
}

@(private)
choice_set_has :: proc(mask: u32, index: int) -> bool {
	return mask & (1 << u32(index)) != 0
}

// Flips one option and saves at once, leaving the popup open for the next option.
@(private)
choice_set_toggle :: proc(p: ^Editor, index: int) -> Editor_Outcome {
	p.choice_set ~= 1 << u32(index)
	p.choice_list.index = index
	return .Save
}

@(private)
choice_set_label :: proc(row: ^Editor_Row, mask: u32) -> string {
	if mask == 0 {return "Off"}
	b := strings.builder_make(context.temp_allocator)
	for label, i in row.choice_labels {
		if !choice_set_has(mask, i) {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, label)
	}
	return strings.to_string(b)
}
