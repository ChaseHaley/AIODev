package ui

import "core:strings"

// The selected row's choices as the shared dropdown shows them.
editor_dropdown_choices :: proc(p: ^Editor, row: ^Editor_Row) -> Dropdown_Choices {
	return {
		choices = row.choices,
		labels = row.choice_labels,
		value = field_string(&p.value),
		mask = p.choice_set,
		multiple = row.multiple,
		searchable = row.kind == .Choice && row.searchable,
		font_filter = row.font_filter,
		show_all_fonts = row.show_all_fonts,
		min_width = row.choice_min_width,
	}
}

// The selected row's open dropdown and where it opens: under the row's field, inside the page. It
// has no field while the row is scrolled out of view. ok is false when no dropdown is open.
@(private)
editor_dropdown :: proc(p: ^Editor, l: Editor_Layout) -> (c: Dropdown_Choices, a: Dropdown_Anchor, ok: bool) {
	row := editor_row(p)
	if row == nil || editor_popup(p) != .Choice {return}
	a.bounds = l.page
	if p.selected >= p.scroll && p.selected < p.scroll + l.rows {
		parts := editor_row_parts(p, l, p.selected)
		a.field, a.row = parts.field, parts.row
	}
	return editor_dropdown_choices(p, row), a, true
}

// Saves the highlighted option, or flips it in a multiple choice.
@(private)
choice_choose :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	index := dropdown_highlighted(&p.dropdown, editor_dropdown_choices(p, row))
	if index < 0 {return .None}
	return choose(p, row, index)
}

// Restore an open font search after its preference is published through Settings.
editor_font_search_restore :: proc(p: ^Editor, query: string, toggle_focus: bool) {
	row := editor_row(p)
	if row == nil || row.kind != .Choice || !row.searchable {return}
	editor_mode_set(p, Editor_Choice_Popup{})
	dropdown_restore(&p.dropdown, editor_dropdown_choices(p, row), query, toggle_focus)
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
	p.dropdown.list.index = index
	return .Save
}

// What a multiple choice's field shows: the labels of the options `mask` has on, or None.
@(private)
choice_set_label :: proc(labels: []string, mask: u32) -> string {
	if mask == 0 {return "None"}
	b := strings.builder_make(context.temp_allocator)
	for label, i in labels {
		if !choice_set_has(mask, i) {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, ", ")}
		strings.write_string(&b, label)
	}
	return strings.to_string(b)
}
