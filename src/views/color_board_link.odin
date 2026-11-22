package views

import "cosmos:render"
import "cosmos:ui"

// Pointing a color at another color from the board's inspector. A color row names the color it follows
// in `link` and keeps the color that results in `value`; the inspector's source field opens a dropdown of
// the colors it may follow, and Unlink keeps the resolved color as the color's own. The page's owner
// saves either as the color's value: the target's key to follow it, a hex to hold a color.

// Every other color the board shows, and Custom color first.
@(private)
BOARD_LINK_LIMIT :: BOARD_TILE_LIMIT + 1

// The source dropdown's options, built when it opens. The strings belong to the page's rows, which a
// rebuilt page replaces together with its open dropdown.
Board_Links :: struct {
	choices, search: [BOARD_LINK_LIMIT]string,
	rows:            [BOARD_LINK_LIMIT]ui.Dropdown_Row,
	count, serial:   int,
}

// Whether the source dropdown is open over the board.
@(private)
board_link_open :: proc(p: ^Editor) -> bool {
	popup, open := p.mode.(Editor_Choice_Popup)
	return open && popup.link
}

// The tile row whose key is `ref`, or -1.
@(private)
board_ref_row :: proc(p: ^Editor, ref: string) -> int {
	if ref == "" {return -1}
	for row, index in p.rows {
		if row.ref == ref && board_tile_row(p, index) {return index}
	}
	return -1
}

// Whether `row` is `at` or follows it, through any number of colors. A chain that never ends counts too:
// nothing may be pointed at it.
@(private)
board_follows :: proc(p: ^Editor, row, at: int) -> bool {
	row := row
	for _ in 0 ..< len(p.rows) {
		if row < 0 {return false}
		if row == at {return true}
		row = board_ref_row(p, p.rows[row].link)
	}
	return true
}

// Lists the colors tile `row` may follow: every color that always has a value and does not itself follow
// `row`, so a loop can never be made here.
@(private)
board_links_build :: proc(p: ^Editor, row: int) {
	l := &p.board.links
	l.count, l.serial = 0, l.serial + 1
	add :: proc(l: ^Board_Links, choice, title, value: string) {
		color, shown := swatch_color(value)
		l.choices[l.count], l.search[l.count] = choice, title
		l.rows[l.count] = {primary = title, swatch = color, swatched = shown}
		l.count += 1
	}
	add(l, "", "Custom color", p.rows[row].value)
	for other, index in p.rows {
		if l.count >= len(l.choices) {break}
		if index == row || !board_tile_row(p, index) {continue}
		// A color that may be none is followed only by another that may be.
		if other.kind != .Color && !(other.clear && p.rows[row].clear) {continue}
		if board_follows(p, index, row) {continue}
		add(l, other.ref, other.title, other.value)
	}
}

@(private)
board_link_choices :: proc(p: ^Editor, row: ^Editor_Row) -> ui.Dropdown_Choices {
	l := &p.board.links
	return {
		choices = l.choices[:l.count],
		search_text = l.search[:l.count],
		rows = l.rows[:l.count],
		rows_serial = l.serial,
		value = row.link,
		searchable = true,
		placeholder = "Search colors",
		empty_text = "No colors found",
		fit_content = true,
	}
}

@(private)
board_link_open_popup :: proc(p: ^Editor) {
	row := editor_row(p)
	if row == nil || !board_tile_item(p, p.selected) {return}
	board_links_build(p, p.items[p.selected].row)
	editor_mode_set(p, Editor_Choice_Popup{link = true})
	ui.dropdown_open(&p.dropdown, board_link_choices(p, row))
}

// Takes option `index` of the open dropdown: Custom color keeps the resolved color as the color's own.
@(private)
board_link_choose :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	l := &p.board.links
	editor_mode_set(p, Editor_Editing{})
	p.board.control = .Link
	if index < 0 || index >= l.count || l.choices[index] == row.link {return .Changed}
	ui.field_set(&p.value, l.choices[index] == "" ? row.value : l.choices[index])
	return .Save
}

// Saves the color the selected tile resolves to as its own, so it stops following.
@(private)
board_unlink :: proc(p: ^Editor) -> Editor_Outcome {
	row := editor_row(p)
	if row == nil || row.link == "" {return .Changed}
	ui.field_set(&p.value, row.value)
	return .Save
}

// Where the inspector's source field is drawn; empty while the board is hidden.
@(private)
color_board_link_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	if !color_board_shown(p) {return {}}
	b := color_board_layout(p, l)
	return b.inspector.link
}

// The mark on a tile whose color follows another.
@(private)
board_link_badge_draw :: proc(list: ^render.Draw_List, theme: Theme, swatch: render.Rect, s: f32) {
	size := 16 * s
	badge := render.Rect{swatch.x + swatch.width - size - 2 * s, swatch.y + 2 * s, size, size}
	ui.draw_rect(list, {rect = badge, color = theme.pane, radius = ui.pill_radius(badge)})
	ui.draw_rect(list, {rect = badge, color = theme.border, radius = ui.pill_radius(badge), stroke = s})
	ui.icon_draw(list, .Link, badge, theme.text, ui.ICON_INDICATOR, s)
}

// The inspector's source row: its label, the field with the color it follows (or Custom color) and,
// while it follows one, Unlink.
@(private)
board_link_draw :: proc(
	p: ^Editor,
	b: ^Board_Inspector,
	row: ^Editor_Row,
	list: ^render.Draw_List,
	text: ^ui.Text,
	theme: Theme,
	clip: render.Rect,
	s: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	board := &p.board
	small := ui.text_styled(text, .Detail)
	body := ui.text_styled(text, .Body)
	label_baseline := b.link.y + (b.link.height - small.line_height) / 2 + small.ascent
	x := b.token.x + BOARD_PAD * s
	label_room := (BOARD_FIELD_LABEL - ui.SPACE_1) * s
	if r := ui.draw_text(&small, list, "Source", x, label_baseline, theme.muted, label_room); r != .Ok {return r}
	keyboard := p.selected == b.item && editor_focus(p) == .Control
	ui.box_draw(list, b.link, theme, board_link_open(p) || (keyboard && board.control == .Link), s)
	if board.hover_hit.target == .Link {
		if ui.hover_rim_draw(list, theme, b.link, ui.RADIUS_CONTROL * s, 1, s, pointer) != .None {return .Ok}
	}
	inset := ui.CONTROL_INSET * s
	mark := render.Rect{b.link.x + inset, b.link.y + (b.link.height - 12 * s) / 2, 12 * s, 12 * s}
	board_swatch_draw(list, theme, mark, clip, row.value, s)
	ui.draw_rect(list, {rect = mark, color = theme.border, radius = ui.RADIUS_CONTROL * s, stroke = s})
	chevron := render.Rect {
		b.link.x + b.link.width - inset - ui.ICON_INDICATOR * s,
		b.link.y,
		ui.ICON_INDICATOR * s,
		b.link.height,
	}
	ui.icon_draw(list, .Chevron_Down, chevron, theme.muted, ui.ICON_INDICATOR, s)
	left := mark.x + mark.width + ui.SPACE_2 * s
	name := "Custom color"
	if row.link != "" {
		icon := render.Rect{left, b.link.y, ui.ICON_INDICATOR * s, b.link.height}
		ui.icon_draw(list, .Link, icon, theme.muted, ui.ICON_INDICATOR, s)
		left += (ui.ICON_INDICATOR + ui.SPACE_1) * s
		name = row.link
		if target := board_ref_row(p, row.link); target >= 0 {name = p.rows[target].title}
	}
	baseline := b.link.y + (b.link.height - body.line_height) / 2 + body.ascent
	room := max(1, chevron.x - ui.SPACE_1 * s - left)
	if r := ui.draw_text(&body, list, name, left, baseline, theme.text, room); r != .Ok {return r}
	if row.link == "" {return .Ok}
	focused := keyboard && board.control == .Unlink
	return ui.text_button_draw(list, text, theme, b.unlink, "Unlink", focused, s, pointer)
}
