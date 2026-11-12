package ui

import "aio:commands"
import "aio:render"
import "aio:settings"
import "core:log"
import "core:strings"

// A conflict chain listed in place of the results, and the selection and scroll the results return
// to when it ends. The query and mode stay as they were.
Chain_Edit :: struct {
	chain:            Shortcut_Chain,
	selected, scroll: int,
}

// Every command's shortcuts as a conflict check reads them; temporary.
@(private)
palette_shortcut_book :: proc(registry: ^commands.Registry) -> []Shortcut_Command {
	book := make([]Shortcut_Command, len(registry.items), context.temp_allocator)
	for &command, i in registry.items {
		book[i] = {settings.binding_key(command.name), command.title, commands.active_shortcuts(&command)}
	}
	return book
}

// Applies the open shortcut row as a chain: the results become the row's command and every command
// holding the chord it recorded, until no chord among them is held twice.
@(private)
palette_chain_open :: proc(p: ^Palette, registry: ^commands.Registry, binding: ^Shortcut_Edit) -> Outcome {
	edit := Chain_Edit{selected = p.selected, scroll = p.scroll}
	book := palette_shortcut_book(registry)
	err := shortcut_chain_open(&edit.chain, book, binding.key, field_string(&binding.draft), &binding.capture)
	if err != nil || !shortcut_chain_active(&edit.chain) {
		if err != nil {log.errorf("palette: could not open the conflicting shortcuts: %v", err)}
		shortcut_chain_destroy(&edit.chain)
		shortcut_capture_resume(&binding.capture)
		return .Changed
	}
	edit_set(p, edit)
	p.scroll = 0
	palette_chain_sync(p, registry, &p.edit.(Chain_Edit))
	return .Changed
}

// Lists the chain's members as the results and follows its selection; a member the chain just
// appended is brought into view.
@(private)
palette_chain_sync :: proc(p: ^Palette, registry: ^commands.Registry, edit: ^Chain_Edit) {
	clear(&p.results)
	chain := &edit.chain
	for member in 0 ..< len(chain.members) {
		name := strings.trim_prefix(shortcut_chain_member_key(chain, member), settings.KEY_BINDING_PREFIX)
		if command := commands.find(registry, name); command != nil {
			append(&p.results, Palette_Result{kind = .Command, command = command, setting = -1, source = -1})
		}
	}
	p.selected = chain.selected
	keep_selection_visible(p)
	rows := max(1, p.visible_rows)
	if chain.appended >= p.scroll + rows {p.scroll = chain.appended - rows + 1}
}

// Ends the conflict chain, dropping what it did not save, and lists the query's results again with
// the selection and scroll from before the chain.
palette_chain_close :: proc(p: ^Palette, registry: ^commands.Registry) {
	edit, open := p.edit.(Chain_Edit)
	if !open {return}
	refresh(p, registry)
	p.selected, p.scroll = edit.selected, edit.scroll
	keep_selection_visible(p)
}

// The changes a resolved chain saves, borrowed from the palette.
palette_chain_changes :: proc(p: ^Palette) -> []Shortcut_Change {
	edit, open := &p.edit.(Chain_Edit)
	return open ? shortcut_chain_changes(&edit.chain) : nil
}

// The open conflict chain, or nil.
palette_chain :: proc(p: ^Palette) -> ^Shortcut_Chain {
	edit, open := &p.edit.(Chain_Edit)
	return open ? &edit.chain : nil
}

// The row of chain member `member` and where its chips end, while it is in the list.
palette_chain_row :: proc(
	p: ^Palette,
	l: Palette_Layout,
	member: int,
) -> (
	row: render.Rect,
	right: f32,
	shown: bool,
) {
	row, shown = row_rect(p, l, member)
	return row, palette_chain_right(row, l.scale), shown
}

// The "Used by" line under the row recording a chord another command holds, or empty.
palette_used_by :: proc(p: ^Palette) -> string {
	_, line := palette_note(p)
	return line
}

@(private)
palette_chain_result :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	edit: ^Chain_Edit,
	outcome: Chain_Outcome,
) -> Outcome {
	switch outcome {
	case .None:
		return .None
	case .Changed:
		palette_chain_sync(p, registry, edit)
		return .Changed
	case .Resolved:
		palette_chain_sync(p, registry, edit)
		return .Save_Chain
	case .Cancelled:
		palette_chain_close(p, registry)
		return .Changed
	}
	return .None
}

@(private)
palette_chain_right :: proc(row: render.Rect, scale: f32) -> f32 {
	return row.x + row.width - PALETTE_PADDING * scale
}

// Cancel · Esc at the footer's right, its label where the footer's last hint would end.
@(private)
palette_chain_cancel_rect :: proc(l: Palette_Layout, text: ^Text) -> render.Rect {
	if text == nil || l.footer.height <= 0 {return {}}
	right := l.footer.x + l.footer.width - (DIALOG_PADDING - CONTROL_INSET) * l.scale
	return chain_cancel_rect(text, right, l.footer.y + l.footer.height / 2, l.scale)
}

@(private)
palette_chain_hit :: proc(
	p: ^Palette,
	edit: ^Chain_Edit,
	l: Palette_Layout,
	text: ^Text,
	x, y: f32,
) -> Chain_Hit {
	if render.rect_contains(palette_chain_cancel_rect(l, text), x, y) {return {member = -1, part = .Cancel}}
	index := row_at(p, l, x, y)
	if index < 0 {return {}}
	row, _ := row_rect(p, l, index)
	return shortcut_chain_hit(&edit.chain, index, row, palette_chain_right(row, l.scale), text, l.scale, x, y)
}

@(private)
palette_chain_press :: proc(
	p: ^Palette,
	registry: ^commands.Registry,
	edit: ^Chain_Edit,
	l: Palette_Layout,
	text: ^Text,
	x, y: f32,
) -> Outcome {
	hit := palette_chain_hit(p, edit, l, text, x, y)
	if hit.part == .None && !render.rect_contains(l.panel, x, y) {
		palette_close(p)
		return .Closed
	}
	return palette_chain_result(p, registry, edit, shortcut_chain_press(&edit.chain, hit))
}

@(private)
palette_chain_hover :: proc(
	p: ^Palette,
	edit: ^Chain_Edit,
	l: Palette_Layout,
	text: ^Text,
	x, y: f32,
) -> Outcome {
	return shortcut_chain_hover(&edit.chain, palette_chain_hit(p, edit, l, text, x, y)) ? .Changed : .None
}

// The chain's line above its rows, then each member's row with its chips and the "Used by" line
// under a recording chip.
@(private)
palette_chain_draw :: proc(
	p: ^Palette,
	edit: ^Chain_Edit,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
	pointer: [2]f32,
) -> render.Build_Status {
	scale := l.scale
	chain := &edit.chain
	padding := PALETTE_PADDING * scale
	if l.lead.height > 0 {
		if render.push_layer(list, l.lead) != .None {return .Ok}
		small := text_styled(text, .Detail)
		baseline := l.lead.y + (l.lead.height - small.line_height) / 2 + small.ascent
		if result := draw_text(&small, list, shortcut_chain_context(chain), l.lead.x + padding, baseline,
		                       theme.muted, max(1, l.lead.width - 2 * padding)); result != .Ok {return result}
	}
	if render.push_layer(list, l.list) != .None {return .Ok}
	title_text := text^
	for index in p.scroll ..< min(len(p.results), p.scroll + l.rows) {
		row, _ := row_rect(p, l, index)
		if index == p.selected {
			draw_rect(list, {rect = row, color = theme.selection, radius = RADIUS_CONTROL * scale})
			if render.rect_contains(row, pointer.x, pointer.y) {
				if result := hover_rim_draw(list, theme, row, RADIUS_CONTROL * scale, 1, scale, pointer, false);
				   result != .None {return .Ok}
			}
		}
		right := palette_chain_right(row, scale)
		left, status := shortcut_chain_chips_draw(chain, index, row, right, list, text, theme, scale)
		if status != .Ok {return status}
		icon_size := ICON_BUTTON * scale
		icon := render.Rect{row.x + padding, row.y + (row.height - icon_size) / 2, icon_size, icon_size}
		icon_draw(list, PALETTE_MODES[.Commands].icon, icon, theme.muted, ICON_BUTTON, scale)
		title_x := row.x + padding + PALETTE_GLYPH_WIDTH * scale
		baseline := row.y + (row.height - title_text.line_height) / 2 + title_text.ascent
		room := max(1, left - SPACE_3 * scale - title_x)
		if result := draw_fading_text(&title_text, list, shortcut_chain_member_title(chain, index), title_x,
		                              baseline, theme.text, room); result != .Ok {return result}
	}
	note, line := palette_note(p)
	if note < 0 {return .Ok}
	row, shown := row_rect(p, l, note)
	if !shown {return .Ok}
	return used_by_draw(list, text, theme, line, palette_chain_right(row, scale), row.y + row.height)
}
