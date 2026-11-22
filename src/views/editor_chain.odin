package views

import "cosmos:render"
import "core:log"
import "core:strings"
import "cosmos:ui"

// Where the page was before a conflict chain filtered it, which closing the chain returns to: the
// selected row's key (owned) and the scroll. The search keeps its text in `filter` throughout.
Editor_Chain_View :: struct {
	key:    string,
	scroll: int,
}

// Whether the page shows a conflict chain instead of its rows. The search, outline, summary and
// Reset to Defaults are hidden meanwhile.
editor_chained :: proc(p: ^Editor) -> bool {return shortcut_chain_active(&p.chain)}

// The shortcut rows as a conflict check reads them; temporary.
@(private)
editor_shortcut_book :: proc(p: ^Editor) -> []Shortcut_Command {
	book := make([dynamic]Shortcut_Command, 0, len(p.rows), context.temp_allocator)
	for row in p.rows {
		if row.kind != .Shortcut || row.shortcut_mode != .Alternatives {continue}
		append(&book, Shortcut_Command{row.key, row.title, chain_parse(row.value)})
	}
	return book[:]
}

// Names the commands holding the chord the selected row's capture recorded last.
@(private)
editor_shortcut_check :: proc(p: ^Editor, row: ^Editor_Row) {
	if row.shortcut_mode != .Alternatives {return}
	shortcut_capture_check(&p.capture, editor_shortcut_book(p), row.key)
}

// Applies the selected row's capture as a chain: the page shows the row and every command holding
// the chord it recorded, until no chord among them is held twice.
@(private)
editor_chain_open :: proc(p: ^Editor, row: ^Editor_Row) {
	key, clone_error := strings.clone(row.key)
	if clone_error == nil {
		book := editor_shortcut_book(p)
		if err := shortcut_chain_open(&p.chain, book, row.key, ui.field_string(&p.value), &p.capture); err != nil {
			log.errorf("settings: could not open the conflicting shortcuts: %v", err)
		}
	}
	if clone_error != nil || !editor_chained(p) {
		shortcut_chain_destroy(&p.chain)
		delete(key)
		editor_message(p, "Could not show the conflicting shortcuts.", true)
		return
	}
	p.chain_view = {key, p.scroll}
	ui.field_set(&p.value, row.value)
	editor_mode_set(p, Editor_Browsing{})
	editor_message(p, "", false)
	editor_error_clear(p)
	editor_rebuild(p)
	p.scroll, p.scroll_fraction = 0, 0
	editor_chain_sync(p)
}

// The context line, then each member's row in chain order: member `m` is item m + 1.
@(private)
editor_chain_items :: proc(p: ^Editor) {
	clear(&p.items)
	append(&p.items, Editor_Item{group = -1, row = -1})
	for member in 0 ..< len(p.chain.members) {
		key := shortcut_chain_member_key(&p.chain, member)
		for row, i in p.rows {
			if row.key == key {append(&p.items, Editor_Item{group = row.group, row = i}); break}
		}
	}
	p.selected = p.chain.selected + 1
	editor_tops_build(p)
}

// Lists the chain's rows and follows its selection, keeping it on the page; a row the chain just
// appended is brought into view.
@(private)
editor_chain_sync :: proc(p: ^Editor) {
	editor_chain_items(p)
	visible := max(1, p.visible_rows)
	p.scroll_fraction = 0
	if p.selected == 1 {p.scroll = 0}
	if p.selected < p.scroll {p.scroll = p.selected}
	if p.selected >= p.scroll + visible {p.scroll = p.selected - visible + 1}
	if appended := p.chain.appended + 1; appended > 0 && appended >= p.scroll + visible {
		p.scroll = appended - visible + 1
	}
	p.scroll = clamp(p.scroll, 0, int(max_scroll(p)))
}

// Ends the conflict chain, dropping whatever it did not save, and returns the page to its search,
// selected row and scroll from before the chain.
editor_chain_close :: proc(p: ^Editor) {
	if !editor_chained(p) {return}
	view := p.chain_view
	p.chain_view = {}
	defer delete(view.key)
	shortcut_chain_destroy(&p.chain)
	editor_filter(p)
	_ = editor_select_key(p, view.key)
	editor_scroll_keep(p, f32(view.scroll))
	editor_mode_set(p, Editor_Browsing{})
}

// The changes a resolved chain saves, as settings keys and values borrowed from the page.
editor_chain_changes :: proc(p: ^Editor) -> []Shortcut_Change {return shortcut_chain_changes(&p.chain)}

@(private)
editor_chain_result :: proc(p: ^Editor, outcome: Chain_Outcome) -> Editor_Outcome {
	switch outcome {
	case .None:
		return .None
	case .Changed:
		editor_chain_sync(p)
		return .Changed
	case .Resolved:
		editor_chain_sync(p)
		return .Shortcut_Chain
	case .Cancelled:
		editor_chain_close(p)
		return .Changed
	}
	return .None
}

@(private)
editor_chain_right :: proc(row: render.Rect, scale: f32) -> f32 {
	return row.x + row.width - ui.SPACE_2 * scale
}

// The row of member `member` and where its chips end, while it is on the page.
editor_chain_row :: proc(
	p: ^Editor,
	l: Editor_Layout,
	member: int,
) -> (
	row: render.Rect,
	right: f32,
	shown: bool,
) {
	index := member + 1
	if index < p.scroll || index >= editor_shown_end(p, p.visible_rows) {return}
	row = editor_row_parts(p, l, index).row
	return row, editor_chain_right(row, l.scale), true
}

// Cancel · Esc, a ghost button whose label sits where the page's summary line does.
@(private)
editor_chain_cancel_rect :: proc(l: Editor_Layout, text: ^ui.Text) -> render.Rect {
	if text == nil {return {}}
	s := l.scale
	heading := ui.text_styled(text, .Display)
	x := l.outline.width > 0 ? l.status_x : l.filter.x + ui.text_width(&heading, "Settings") + ui.SPACE_4 * s
	small := ui.text_styled(text, .Detail)
	width := ui.text_width(&small, CHAIN_CANCEL_LABEL) + 2 * ui.CONTROL_INSET * s
	height := ui.HEIGHT_COMPACT * s
	return {x - ui.CONTROL_INSET * s, l.page.y + HEADER_CENTER * s - height / 2, width, height}
}

@(private)
editor_chain_hit :: proc(p: ^Editor, l: Editor_Layout, text: ^ui.Text, x, y: f32) -> Chain_Hit {
	if render.rect_contains(editor_chain_cancel_rect(l, text), x, y) {return {member = -1, part = .Cancel}}
	if !render.rect_contains(l.list, x, y) {return {}}
	member := editor_line_at(p, l, y) - 1
	if member < 0 || member >= len(p.chain.members) {return {}}
	row, right, shown := editor_chain_row(p, l, member)
	if !shown {return {}}
	return shortcut_chain_hit(&p.chain, member, row, right, text, l.scale, x, y)
}

@(private)
editor_chain_press :: proc(p: ^Editor, l: Editor_Layout, text: ^ui.Text, x, y: f32) -> Editor_Outcome {
	return editor_chain_result(p, shortcut_chain_press(&p.chain, editor_chain_hit(p, l, text, x, y)))
}

@(private)
editor_chain_hover :: proc(p: ^Editor, l: Editor_Layout, text: ^ui.Text, x, y: f32) -> bool {
	hit := editor_chain_hit(p, l, text, x, y)
	item := hit.part != .None && hit.part != .Cancel ? hit.member + 1 : -1
	changed := item != p.hover_item
	p.hover_item = item
	return shortcut_chain_hover(&p.chain, hit) || changed
}

@(private)
editor_chain_pointer :: proc(p: ^Editor, l: Editor_Layout, text: ^ui.Text, x, y: f32) -> bool {
	#partial switch editor_chain_hit(p, l, text, x, y).part {
	case .Chip, .Remove, .Add, .Cancel:
		return true
	}
	return false
}

// The page while chained: Cancel · Esc in place of the summary, the context line, each member's row
// with its chips and the "Used by" line under a recording chip.
@(private)
editor_chain_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^ui.Text,
	theme: Theme,
	pointer: [2]f32,
) -> render.Build_Status {
	s := l.scale
	chain := &p.chain
	cancel := editor_chain_cancel_rect(l, text)
	if result := chain_cancel_draw(list, text, theme, cancel, chain.hover.part == .Cancel, s); result != .Ok {
		return result
	}
	if render.push_layer(list, l.list) != .None {return .Ok}
	for index in p.scroll ..< editor_shown_end(p, p.visible_rows) {
		r := editor_row_parts(p, l, index).row
		if index == 0 {
			baseline := r.y + r.height - ui.SPACE_3 * s
			if result := ui.draw_text(
				text, list, shortcut_chain_context(chain), r.x + ui.CONTROL_INSET * s, baseline,
				theme.muted, max(1, r.width - 2 * ui.CONTROL_INSET * s),
			); result != .Ok {return result}
			continue
		}
		selected := index == p.selected
		if selected {
			ui.draw_rect(list, {rect = r, color = theme.selection, radius = ui.RADIUS_CONTROL * s})
		} else if index == p.hover_item {
			ui.draw_rect(list, {rect = r, color = theme.hover, radius = ui.RADIUS_CONTROL * s})
		}
		if index == p.hover_item {
			if result := ui.hover_rim_draw(list, theme, r, ui.RADIUS_CONTROL * s, 1, s, pointer, !selected);
			   result != .None {return .Ok}
		}
		right := editor_chain_right(r, s)
		left, status := shortcut_chain_chips_draw(chain, index - 1, r, right, list, text, theme, s)
		if status != .Ok {return status}
		x := r.x + ITEM_INSET * s
		baseline := r.y + (r.height - text.line_height) / 2 + text.ascent
		if result := ui.draw_text(text, list, shortcut_chain_member_title(chain, index - 1), x,
			baseline, theme.text,
		                       max(1, left - ui.SPACE_4 * s - x)); result != .Ok {return result}
	}
	// The line under a recording chip is drawn over the next row's top margin, after every row.
	if chain.recording >= 0 {
		if row, right, shown := editor_chain_row(p, l, chain.recording); shown {
			top := row.y + (row.height + ui.HEIGHT_COMPACT * s) / 2 + ui.SPACE_1 * s
			if result := used_by_draw(list, text, theme, shortcut_chain_used_by(chain), right, top); result != .Ok {
				return result
			}
		}
	}
	return .Ok
}
