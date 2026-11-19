package ui

import "aio:input"
import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

SAVED_FILTER_ADD_KEY :: "filter.add"

// The pattern a new filter starts with: it matches every path, so adding one hides nothing.
@(private)
SAVED_FILTER_NEW_PATTERN :: "."

// The field of a saved filter a row edits.
Filter_Field :: enum u8 {
	None,
	Name,
	Pattern,
}

// The saved filter table's state on the settings page: the one filter whose fields are open, counted
// from 1 in page order. Zero is none. Rows own the filter text, and every committed edit rebuilds the
// whole setting from them, so the table keeps no draft.
Saved_Filter_State :: struct {
	filter_expanded: int,
}

// A change to the filter list the page owner saves as the whole setting.
Filter_Edit_Kind :: enum u8 {
	// `key` names a field row; `value` is its new text.
	Field,
	Add,
	Remove,
	// Moves filter `id` into the gap before `slot`, counted among the filters before the move.
	Move,
}

Filter_Edit :: struct {
	kind:       Filter_Edit_Kind,
	id, slot:   int,
	key, value: string,
}

@(require_results)
filter_key :: proc(id: int, suffix: string = "") -> string {
	return fmt.tprintf("filter.%d%s", id, suffix)
}

@(private, require_results)
filter_row_add :: proc(
	p: ^Editor,
	id: int,
	field: Filter_Field,
	title, value, description: string,
) -> runtime.Allocator_Error {
	suffix := ""
	kind := Row_Kind.Text
	switch field {
	case .None:
		kind = .Saved_Filter
	case .Name:
		suffix = ".name"
	case .Pattern:
		suffix = ".pattern"
	}
	return editor_add(
		p,
		{
			key = filter_key(id, suffix),
			title = title,
			value = value,
			default_value = value,
			description = description,
			kind = kind,
			filter = id,
			filter_field = field,
			detail = settings.SAVED_FILTERS_KEY,
		},
		settings.group_title(settings.SAVED_FILTERS_KEY),
	)
}

// Adds a table line and its two field rows per filter, then the Add filter row.
@(require_results)
editor_saved_filters_load :: proc(p: ^Editor, value: string) -> runtime.Allocator_Error {
	cursor := settings.saved_filters_scan(value)
	id := 0
	next := settings.saved_filters_next
	for filter, more := next(&cursor); more; filter, more = next(&cursor) {
		id += 1
		filter_row_add(p, id, .None, filter.name, filter.pattern, "") or_return
		head := &p.rows[len(p.rows) - 1]
		// Search reads the pattern too, so a filter is found by what it matches.
		detail := strings.concatenate({settings.SAVED_FILTERS_KEY, " ", filter.pattern}) or_return
		delete(head.detail)
		head.detail = detail
		filter_row_add(
			p,
			id,
			.Name,
			"Name",
			filter.name,
			"What the filter field's @ inserts it by. Up to 32 characters.",
		) or_return
		filter_row_add(
			p,
			id,
			.Pattern,
			"Pattern",
			filter.pattern,
			"Regular expressions on a path, as in the filter field; ! before one hides what it matches.",
		) or_return
	}
	return editor_add(
		p,
		{
			key = SAVED_FILTER_ADD_KEY,
			title = "Add filter",
			description = "The filter field's @ inserts one by name.",
			value = "Add filter",
			kind = .Action,
			action = .Filter_Add,
			detail = settings.SAVED_FILTERS_KEY,
		},
		settings.group_title(settings.SAVED_FILTERS_KEY),
	)
}

@(private)
editor_has_filter_row :: proc(p: ^Editor, id: int) -> bool {
	for row in p.rows {
		if row.kind == .Saved_Filter && row.filter == id {return true}
	}
	return false
}

// What the user is told when a filter field cannot be stored.
@(private)
saved_filter_problem_text :: proc(problem: settings.Saved_Filter_Problem) -> string {
	switch problem {
	case .Name:
		return "Enter a name of up to 32 characters without ; | or quotes."
	case .Duplicate:
		return "Another filter already has that name."
	case .Pattern:
		return "Enter a pattern without ;."
	case .Too_Long:
		return "The filters are too long to store."
	}
	return ""
}

// The first "New filter", "New filter 2", ... that no draft holds, compared without case.
@(private)
filter_new_name :: proc(drafts: []settings.Saved_Filter_Draft) -> string {
	name := "New filter"
	for number := 2; ; number += 1 {
		taken := false
		for draft in drafts {
			if strings.equal_fold(strings.trim_space(draft.name), name) {taken = true; break}
		}
		if !taken {return name}
		name = fmt.tprintf("New filter %d", number)
	}
}

// The setting text after `edit`, read from the page's rows, and the row to show afterwards. Moving,
// adding and removing also move the open filter with its block, since a reload numbers filters by
// position. A problem is the message for a field the setting cannot hold; nothing is saved then.
// A `kept` field is one the user typed into and left without Enter. Its key names a position, which
// this edit may renumber, so it is applied to the rows here, before the edit, or dropped with its
// filter, instead of being saved afterwards under whatever filter took the position.
@(require_results)
editor_saved_filters_value :: proc(
	p: ^Editor,
	edit: Filter_Edit,
	kept: Editor_Kept = {},
) -> (
	value, select_key, problem: string,
) {
	kept_filter := 0
	if kept.key != "" {
		for row in p.rows {
			if row.key == kept.key && row.filter_field != .None {kept_filter = row.filter}
		}
	}
	if edit.kind == .Remove && edit.id == kept_filter {kept_filter = 0}
	drafts := make([dynamic]settings.Saved_Filter_Draft, context.temp_allocator)
	for head in p.rows {
		if head.kind != .Saved_Filter {continue}
		draft: settings.Saved_Filter_Draft
		for row in p.rows {
			if row.filter != head.filter || row.filter_field == .None {continue}
			text := row.value
			if kept_filter != 0 && row.key == kept.key {text = kept.value}
			if edit.kind == .Field && row.key == edit.key {text = edit.value}
			switch row.filter_field {
			case .None:
			case .Name:
				draft.name = text
			case .Pattern:
				draft.pattern = text
			}
		}
		append(&drafts, draft)
	}
	select_key = edit.key
	count := len(drafts)
	switch edit.kind {
	case .Field:
	case .Add:
		append(&drafts, settings.Saved_Filter_Draft{filter_new_name(drafts[:]), SAVED_FILTER_NEW_PATTERN})
		p.filter_expanded = count + 1
		select_key = filter_key(count + 1, ".name")
	case .Remove:
		if edit.id >= 1 && edit.id <= count {
			ordered_remove(&drafts, edit.id - 1)
			if p.filter_expanded == edit.id {p.filter_expanded = 0}
			else if p.filter_expanded > edit.id {p.filter_expanded -= 1}
		}
		select_key = SAVED_FILTER_ADD_KEY
	case .Move:
		from := edit.id - 1
		slot := edit.slot > from ? edit.slot - 1 : edit.slot
		select_key = filter_key(edit.id)
		if from >= 0 && from < count && slot >= 0 && slot < count && slot != from {
			moved := drafts[from]
			ordered_remove(&drafts, from)
			inject_at(&drafts, slot, moved)
			// A reload numbers filters by position, so the open filter and the blocks still easing into
			// place are renumbered to follow their filter.
			if p.filter_expanded > 0 {
				p.filter_expanded = filter_index_after_move(p.filter_expanded - 1, from, slot) + 1
			}
			select_key = filter_key(slot + 1)
			filter_positions_follow(p, from, slot)
		}
	}
	text, refusal, err := settings.saved_filters_text(drafts[:], context.temp_allocator)
	if err != nil {return "", "", "Could not keep the filter edit."}
	if refused, has_problem := refusal.?; has_problem {return "", "", saved_filter_problem_text(refused)}
	return text, select_key, ""
}

// Whether `kept` is the text of one of the filter page's fields.
@(require_results)
editor_kept_is_filter :: proc(p: ^Editor, kept: Editor_Kept) -> bool {
	if kept.key == "" {return false}
	for row in p.rows {
		if row.key == kept.key {return row.filter_field != .None}
	}
	return false
}

// Puts the page state `editor_saved_filters_value` changed for `edit` back, after the setting it
// built was not saved: the open filter as it was (`expanded`) and the blocks' drawn positions.
editor_saved_filters_undo :: proc(p: ^Editor, edit: Filter_Edit, expanded: int) {
	p.filter_expanded = expanded
	if edit.kind != .Move {return}
	count := 0
	for row in p.rows {
		if row.kind == .Saved_Filter {count += 1}
	}
	from := edit.id - 1
	slot := edit.slot > from ? edit.slot - 1 : edit.slot
	if from >= 0 && from < count && slot >= 0 && slot < count && slot != from {
		filter_positions_follow(p, slot, from)
	}
}

// Where the filter that was at `old` is after the filter at `from` moved to `slot`.
@(private)
filter_index_after_move :: proc(old, from, slot: int) -> int {
	switch {
	case old == from:
		return slot
	case from < slot && old > from && old <= slot:
		return old - 1
	case from > slot && old >= slot && old < from:
		return old + 1
	}
	return old
}

// Renames the drawn positions of filter blocks after a move, so the blocks keep easing from where
// they are drawn when the reload gives them new keys.
@(private)
filter_positions_follow :: proc(p: ^Editor, from, slot: int) {
	for &entry in p.profile_positions {
		number, ok := strconv.parse_int(strings.trim_prefix(entry.id, "filter."))
		if !ok || !strings.has_prefix(entry.id, "filter.") {continue}
		renamed, err := strings.clone(filter_key(filter_index_after_move(number - 1, from, slot) + 1))
		if err != nil {continue}
		delete(entry.id)
		entry.id = renamed
	}
}

// Opens or closes one filter's fields, closing any other, and selects its table line.
editor_filter_toggle :: proc(p: ^Editor, id: int) {
	p.filter_expanded = p.filter_expanded == id ? 0 : id
	editor_rebuild(p)
	for item, index in p.items {
		if item.row < 0 {continue}
		row := &p.rows[item.row]
		if row.kind == .Saved_Filter && row.filter == id {editor_select(p, index); return}
	}
}

// Keys on a filter's table line: Enter or Right and Left open and close its fields, Delete from the
// line's controls removes it, and Ctrl+Up or Down moves it one place.
editor_filter_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	if row == nil || row.kind != .Saved_Filter {return .None, false}
	if .Control in e.modifiers && (e.key == .Arrow_Up || e.key == .Arrow_Down) {
		// Search hides lines, so a move could not show where the filter lands.
		if filtering(p) {return .Changed, true}
		count := 0
		for candidate in p.rows {if candidate.kind == .Saved_Filter {count += 1}}
		from := row.filter - 1
		slot := e.key == .Arrow_Up ? from - 1 : from + 2
		if slot < 0 || slot > count {return .Changed, true}
		editor_request_set(p, Filter_Edit{kind = .Move, id = row.filter, slot = slot})
		return .Filter_Action, true
	}
	#partial switch e.key {
	case .Enter, .Numpad_Enter:
		editor_filter_toggle(p, row.filter)
		return .Changed, true
	case .Arrow_Right:
		if p.filter_expanded != row.filter {editor_filter_toggle(p, row.filter)}
		return .Changed, true
	case .Arrow_Left:
		if p.filter_expanded == row.filter {editor_filter_toggle(p, row.filter)}
		return .Changed, true
	case .Delete:
		if editor_editing(p) {
			editor_request_set(p, Filter_Edit{kind = .Remove, id = row.filter})
			return .Filter_Action, true
		}
	}
	return .None, false
}

// A press on a filter's table line: the grip starts a reorder drag, the trash removes it, and the
// rest opens or closes its fields.
@(private)
editor_filter_press :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	index: int,
	x, y, scale: f32,
) -> Editor_Outcome {
	cells := editor_block_parts(parts.row, scale)
	if render.rect_contains(cells.handle, x, y) {
		if filtering(p) {return .Changed}
		grab := (y - parts.row.y) / parts.row.height
		order_begin(p, Order_Filter{row.filter}, block_index_at(p, index, .Saved_Filters), grab)
		return .Changed
	}
	if render.rect_contains(cells.remove, x, y) {
		editor_mode_set(p, Editor_Editing{})
		editor_request_set(p, Filter_Edit{kind = .Remove, id = row.filter})
		return .Filter_Action
	}
	editor_filter_toggle(p, row.filter)
	return .Changed
}

// A filter's table line: the grip, its name, its pattern in detail text beside the name, the chevron of
// its fields and remove.
@(private)
editor_filter_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32,
	scale: f32,
) -> render.Build_Status {
	s, r := scale, parts.row
	cells := editor_block_parts(r, s)
	small := text_styled(text, .Detail)
	grip_ink := selected || editor_order_dragging(p, .Saved_Filters) ? theme.muted : theme.faint
	icon_draw(list, .Grip, cells.handle, grip_ink, ICON_BUTTON, s)
	remove_hovered := editor_row_control_hovered(p, row, cells.remove, pointer)
	if table_button_draw(list, cells.remove, .Trash, ICON_BUTTON, theme, s, false, remove_hovered, selected,
		   pointer) != .None {return .Ok}
	chevron := render.Rect{cells.remove.x - HEIGHT_COMPACT * s, r.y, HEIGHT_COMPACT * s, r.height}
	expanded := p.filter_expanded == row.filter
	icon_draw(list, expanded ? .Chevron_Down : .Chevron_Right, chevron, theme.muted, ICON_INDICATOR, s)
	right := chevron.x - SPACE_2 * s
	x := cells.expand.x
	baseline := r.y + (r.height - text.line_height) / 2 + text.ascent
	name_width := min(text_width(text, row.title), max(1, (right - x) * 0.6))
	if result := draw_fading_text(text, list, row.title, x, baseline, theme.text, name_width); result != .Ok {
		return result
	}
	detail_x := x + name_width + SPACE_3 * s
	detail_baseline := r.y + (r.height - small.line_height) / 2 + small.ascent
	return draw_fading_text(&small, list, row.value, detail_x, detail_baseline, theme.faint, right - detail_x)
}
