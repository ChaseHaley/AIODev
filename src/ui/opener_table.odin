package ui

import "aio:input"
import "aio:render"
import "core:strings"

// The link program table's state on the settings page: the one program whose fields are open.
// Owned.
Opener_Editor_State :: struct {
	opener_expanded: string,
}

@(private)
opener_editor_destroy :: proc(state: ^Opener_Editor_State) {
	delete(state.opener_expanded)
}

// Sets the one link program whose fields are open, "" for none. A page about to reload calls this
// directly, since the reload rebuilds the page.
editor_opener_set_expanded :: proc(p: ^Editor, id: string) {
	owned := strings.clone(id)
	delete(p.opener_expanded)
	p.opener_expanded = owned
}

// Opens or closes one link program's fields, closing any other, and selects its table line.
editor_opener_toggle :: proc(p: ^Editor, id: string) {
	target := strings.clone(id, context.temp_allocator)
	editor_opener_set_expanded(p, p.opener_expanded == target ? "" : target)
	editor_rebuild(p)
	for item, index in p.items {
		if item.row < 0 {continue}
		row := &p.rows[item.row]
		if row.kind == .Opener && row.opener == target {editor_select(p, index); return}
	}
}

@(private)
editor_has_opener_row :: proc(p: ^Editor, id: string) -> bool {
	for row in p.rows {
		if row.kind == .Opener && row.opener == id {return true}
	}
	return false
}

@(private)
opener_remove_request :: proc(p: ^Editor, id: string) -> Editor_Outcome {
	editor_request_set(p, Opener_Remove_Request{strings.clone(id)})
	return .Opener_Action
}

// Keys on a link program's table line: Enter or Right and Left open and close its fields, Delete
// from the line's controls asks to remove it, and Ctrl+Up or Down moves it one place.
editor_opener_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	if row == nil || row.kind != .Opener {return .None, false}
	if .Control in e.modifiers && (e.key == .Arrow_Up || e.key == .Arrow_Down) {
		// Search hides lines, so a move could not show where the program lands.
		if filtering(p) {return .Changed, true}
		from, count := 0, 0
		for candidate in p.rows {
			if candidate.kind != .Opener {continue}
			if candidate.opener == row.opener {from = count}
			count += 1
		}
		slot := e.key == .Arrow_Up ? from - 1 : from + 2
		if slot < 0 || slot > count {return .Changed, true}
		editor_request_set(p, Opener_Order_Request{strings.clone(row.opener), slot})
		return .Opener_Action, true
	}
	#partial switch e.key {
	case .Enter, .Numpad_Enter:
		editor_opener_toggle(p, row.opener)
		return .Changed, true
	case .Arrow_Right:
		if p.opener_expanded != row.opener {editor_opener_toggle(p, row.opener)}
		return .Changed, true
	case .Arrow_Left:
		if p.opener_expanded == row.opener {editor_opener_toggle(p, row.opener)}
		return .Changed, true
	case .Delete:
		if editor_editing(p) {return opener_remove_request(p, row.opener), true}
	}
	return .None, false
}

// A press on a link program's table line: the grip starts a reorder drag, the trash asks to
// remove it, and the rest opens or closes its fields.
@(private)
editor_opener_press :: proc(
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
		order_begin(p, Order_Opener{strings.clone(row.opener)}, block_index_at(p, index, .Openers), grab)
		return .Changed
	}
	if render.rect_contains(cells.remove, x, y) {
		editor_mode_set(p, Editor_Editing{})
		return opener_remove_request(p, row.opener)
	}
	editor_opener_toggle(p, row.opener)
	return .Changed
}

// A link program's table line: the grip, its name over its command line, where it opens, the
// chevron of its fields and remove.
@(private)
editor_opener_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	scale: f32,
) -> render.Build_Status {
	s, r := scale, parts.row
	cells := editor_block_parts(r, s)
	small := text_styled(text, .Detail)
	grip_ink := selected || editor_order_dragging(p, .Openers) ? theme.muted : theme.faint
	icon_draw(list, .Grip, cells.handle, grip_ink, ICON_BUTTON, s)
	icon_draw(list, .Trash, cells.remove, theme.muted, ICON_BUTTON, s)
	chevron := render.Rect{cells.remove.x - HEIGHT_COMPACT * s, r.y, HEIGHT_COMPACT * s, r.height}
	expanded := p.opener_expanded == row.opener
	icon_draw(list, expanded ? .Chevron_Down : .Chevron_Right, chevron, theme.muted, ICON_INDICATOR, s)
	placement := chevron.x - 8 * s - text_width(&small, row.value)
	if result := draw_text(
		&small,
		list,
		row.value,
		placement,
		r.y + (r.height - small.line_height) / 2 + small.ascent,
		theme.muted,
		max(1, chevron.x - placement),
	); result != .Ok {return result}
	width := max(1, placement - cells.expand.x - 12 * s)
	name_baseline, command_baseline := stacked_baselines(r, text, &small, s)
	if result := draw_text(text, list, row.title, cells.expand.x, name_baseline, theme.text, width);
	   result != .Ok {return result}
	return draw_fading_text(&small, list, row.description, cells.expand.x, command_baseline, theme.muted, width)
}
