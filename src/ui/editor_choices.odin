package ui

import "aio:render"
import "aio:settings"
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
	if row == nil || row.key != "font.family" || editor_popup(p) != .Choice {return {}}
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

@(private)
choice_set_has :: proc(row: ^Editor_Row, value: string, index: int) -> bool {
	mask, _, ok := settings.set_parse(row.choices, value)
	return ok && mask & (1 << u32(index)) != 0
}

// Flips one option and saves at once, leaving the popup open for the next option.
@(private)
choice_set_toggle :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	mask, _, _ := settings.set_parse(row.choices, field_string(&p.value))
	field_set(&p.value, settings.set_text(row.choices, mask ~ (1 << u32(index))))
	p.popup_index = index
	return .Save
}

@(private)
choice_set_label :: proc(row: ^Editor_Row, value: string) -> string {
	mask, _, ok := settings.set_parse(row.choices, value)
	if !ok {return value}
	if mask == 0 {return "Off"}
	b := strings.builder_make(context.temp_allocator)
	for label, i in row.choice_labels {
		if mask & (1 << u32(i)) == 0 {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, label)
	}
	return strings.to_string(b)
}
