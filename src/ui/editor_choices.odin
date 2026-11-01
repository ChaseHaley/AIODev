package ui

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
	return choice_searchable(row) ? CHOICE_SEARCH_HEIGHT * scale : 0
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
