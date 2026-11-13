package ui

import "aio:colour"
import "aio:input"
import "aio:platform"
import "aio:render"
import "base:runtime"
import "core:math"
import "core:strconv"
import "core:strings"

// The Colors section drawn as a swatch board: each color row is a small tile in its role group, and
// one inspector beside the board shows the theme's card and edits the chosen color with the picker
// always open. The rows stay page rows, so search, reveals, saving and the outline treat them as any
// other; the board only changes how the unsearched section is laid out, drawn and driven. A search
// lists the same rows as rows again.

// The page owner names at most BOARD_GROUP_LIMIT groups holding at most BOARD_TILE_LIMIT colors.
// Rows of the board's section outside those groups are the card's controls.
BOARD_GROUP_LIMIT :: 16
BOARD_TILE_LIMIT :: 64
@(private)
BOARD_CARD_LIMIT :: 8
@(private)
BOARD_CHIP_LIMIT :: 6

@(private)
BOARD_TILE_WIDTH :: f32(64)
@(private)
BOARD_TILE_GAP :: SPACE_2
@(private)
BOARD_SWATCH :: f32(36)
// Two Detail lines of label under the swatch.
@(private)
BOARD_LABEL :: f32(28)
// A line of tiles with its labels and the gap under them. With its heading, a group of one line is two
// page lines tall, so the outline lands a group's heading at the top of the page.
@(private)
BOARD_TILE_LINE :: f32(84)
@(private)
BOARD_GROUP_HEADING :: f32(20)
@(private)
BOARD_SIDE_HEADING :: f32(52)
@(private)
BOARD_GROUP_GAP :: SPACE_6
@(private)
BOARD_GAP :: SPACE_6
@(private)
BOARD_INSPECTOR_WIDTH :: f32(320)
// The picker's own width: the hue wheel, the brightness column and their insets (color_parts).
@(private)
BOARD_INSPECTOR_MIN :: f32(292)
@(private)
BOARD_PAD :: SPACE_3
@(private)
BOARD_FIELD_LABEL :: f32(76)
@(private)
BOARD_RESET_WIDTH :: f32(76)
@(private)
BOARD_CHIP_HEIGHT :: f32(22)
@(private)
BOARD_TEXT_LINE :: f32(16)

// Which part of the inspector has the keyboard while the selected row is a tile and its control has the
// focus: the tile itself, the hex field, No Color or Reset. The picker's drags edit the hex field.
Board_Control :: enum u8 {
	Tile,
	Hex,
	No_Color,
	Reset,
}

// What the inspector's card says about the theme the board edits; the board owns the strings. `base`
// names where a color's Reset returns, beside the value it returns to.
Board_Card :: struct {
	title, badge, detail, note, base: string,
	// A theme edited in place; its badge takes the accent.
	custom:                           bool,
}

@(private)
Board_Group :: struct {
	group: int,
	// A static heading over this group and those after it that share it; empty for none.
	side:  string,
}

@(private)
Board_Target :: enum u8 {
	None,
	Tile,
	Chip,
	Field,
	Button,
	Wheel,
	Ramp,
	Hex,
	No_Color,
	Reset,
}

// A part of the board under a point, with the page line it acts on.
@(private)
Board_Hit :: struct {
	target: Board_Target,
	item:   int,
}

// The board a page draws for its sections' color rows, and what moves on it.
Color_Board :: struct {
	groups:                       [BOARD_GROUP_LIMIT]Board_Group,
	group_count:                  int,
	card:                         Board_Card,
	// The color row the inspector shows: the tile last selected, kept while a card control has the
	// selection. Validated on use, so the zero page falls back to the first tile.
	row:                          int,
	control:                      Board_Control,
	// The selection ring slides from where it was drawn, kept relative to the board's content origin.
	ring:                         Motion,
	ring_from:                    render.Rect,
	ring_row:                     int,
	ring_shown:                   bool,
	// The picker's markers glide to a new color; a point is the wheel's unit position and the value.
	marker:                       Motion,
	marker_from, marker_to:       [3]f32,
	marker_shown:                 bool,
	// The tile under the pointer lights up, and the one it left fades out.
	hover, fade:                  Motion,
	hover_row, fade_row:          int,
	hovered, faded:               bool,
	hover_hit:                    Board_Hit,
}

@(private)
Board_Place :: struct {
	item: int,
	rect: render.Rect,
}

@(private)
Board_Side_Place :: struct {
	title: string,
	tiles: int,
	rect:  render.Rect,
}

// The inspector's parts on screen. Text line positions are the tops of their lines.
@(private)
Board_Inspector :: struct {
	rect, card, token, picker, hex, base, reset: render.Rect,
	title_y, detail_y, note_y, token_y, same_y:  f32,
	fields, buttons:                             [BOARD_CARD_LIMIT]Board_Place,
	field_count, button_count:                   int,
	chips:                                       [BOARD_CHIP_LIMIT]Board_Place,
	chip_count, same_count:                      int,
	// The color row shown and its page line; -1 without one.
	row, item:                                   int,
}

@(private)
Board_Layout :: struct {
	tiles:                                  [BOARD_TILE_LIMIT]Board_Place,
	headings:                               [BOARD_GROUP_LIMIT]Board_Place,
	sides:                                  [BOARD_GROUP_LIMIT]Board_Side_Place,
	tile_count, heading_count, side_count: int,
	inspector:                              Board_Inspector,
	// The screen position of the board's content origin at the current scroll.
	origin:                                 [2]f32,
	// The content's height in page lines.
	lines:                                  int,
	scale:                                  f32,
}

// Names a group of color rows as part of the board, under the static `side` heading. A group with no
// rows has nothing to draw and is skipped.
editor_board_group :: proc(p: ^Editor, title, side: string) -> bool {
	for group, index in p.groups {
		if group.title != title {continue}
		if p.board.group_count >= BOARD_GROUP_LIMIT {return false}
		p.board.groups[p.board.group_count] = {index, side}
		p.board.group_count += 1
		return true
	}
	return true
}

@(require_results)
editor_board_card :: proc(p: ^Editor, card: Board_Card) -> runtime.Allocator_Error {
	owned := card
	owned.title = strings.clone(card.title) or_return
	owned.badge = strings.clone(card.badge) or_return
	owned.detail = strings.clone(card.detail) or_return
	owned.note = strings.clone(card.note) or_return
	owned.base = strings.clone(card.base) or_return
	board_card_destroy(&p.board.card)
	p.board.card = owned
	return nil
}

@(private)
board_card_destroy :: proc(card: ^Board_Card) {
	delete(card.title)
	delete(card.badge)
	delete(card.detail)
	delete(card.note)
	delete(card.base)
	card^ = {}
}

@(private)
color_board_destroy :: proc(b: ^Color_Board) {
	board_card_destroy(&b.card)
}

// Whether the page shows its board: the board's section without a search or conflict chain.
color_board_shown :: proc(p: ^Editor) -> bool {
	b := &p.board
	if b.group_count == 0 || len(p.sections) == 0 || filtering(p) || editor_chained(p) {return false}
	return p.groups[b.groups[0].group].section == p.section
}

@(private)
board_group :: proc(p: ^Editor, group: int) -> (Board_Group, bool) {
	for g in p.board.groups[:p.board.group_count] {
		if g.group == group {return g, true}
	}
	return {}, false
}

@(private)
board_tile_row :: proc(p: ^Editor, row: int) -> bool {
	if row < 0 || row >= len(p.rows) {return false}
	r := &p.rows[row]
	_, grouped := board_group(p, r.group)
	return grouped && (r.kind == .Color || r.kind == .Optional_Color)
}

@(private)
board_tile_item :: proc(p: ^Editor, index: int) -> bool {
	return index >= 0 && index < len(p.items) && board_tile_row(p, p.items[index].row)
}

// A row of the board's section outside its groups: one of the card's controls.
@(private)
board_card_item :: proc(p: ^Editor, index: int) -> bool {
	if p.board.group_count == 0 || index < 0 || index >= len(p.items) || p.items[index].row < 0 {
		return false
	}
	group := p.items[index].group
	_, grouped := board_group(p, group)
	return !grouped && p.groups[group].section == p.groups[p.board.groups[0].group].section
}

// The color row the inspector shows: the last tile selected, or the board's first.
@(private)
board_token :: proc(p: ^Editor) -> int {
	if board_tile_row(p, p.board.row) {return p.board.row}
	for _, i in p.rows {if board_tile_row(p, i) {return i}}
	return -1
}

@(private)
board_item_of :: proc(p: ^Editor, row: int) -> int {
	if row < 0 {return -1}
	for item, index in p.items {if item.row == row {return index}}
	return -1
}

// The key of the row the inspector shows, or "".
color_board_token_key :: proc(p: ^Editor) -> string {
	row := board_token(p)
	return row >= 0 ? p.rows[row].key : ""
}

// The page line that opens the board: the color the inspector last showed.
@(private)
color_board_first :: proc(p: ^Editor) -> int {
	return board_item_of(p, board_token(p))
}

// A selection that lands on a tile makes it the inspector's color; any selection hands the
// keyboard to the tile rather than a part of the inspector.
@(private)
color_board_follow :: proc(p: ^Editor) {
	if p.selected >= 0 && p.selected < len(p.items) && board_tile_row(p, p.items[p.selected].row) {
		p.board.row = p.items[p.selected].row
	}
	p.board.control = .Tile
}

@(private)
board_move_rect :: proc(r: render.Rect, dx, dy: f32) -> render.Rect {
	return {r.x + dx, r.y + dy, r.width, r.height}
}

// Tile width and gaps. A board too narrow for two groups of four side by side at the full tile size
// closes the tiles up, down to BOARD_TILE_MIN, to fit them; failing that, to keep a group of four on
// one line; and only then lets groups wrap.
@(private)
Board_Tiling :: struct {
	tile, gap, group_gap: f32,
	// 2 when two groups of four share a line, 1 when one group of four fits a line, 0 otherwise.
	fit:                  int,
}

@(private)
BOARD_TILE_MIN :: f32(52)

@(private)
board_tiling :: proc(width: f32) -> Board_Tiling {
	pair :: proc(t: Board_Tiling) -> f32 {return 8 * t.tile + 6 * t.gap + t.group_gap}
	roomy := Board_Tiling{BOARD_TILE_WIDTH, BOARD_TILE_GAP, BOARD_GROUP_GAP, 2}
	if width >= pair(roomy) {return roomy}
	close := Board_Tiling{0, SPACE_1, SPACE_4, 2}
	close.tile = min(BOARD_TILE_WIDTH, math.floor((width - pair(close)) / 8))
	if close.tile >= BOARD_TILE_MIN {return close}
	close.tile, close.fit = min(BOARD_TILE_WIDTH, math.floor((width - 3 * close.gap) / 4)), 1
	if close.tile >= BOARD_TILE_MIN {return close}
	roomy.fit = 0
	return roomy
}

@(private)
board_run_width :: proc(t: Board_Tiling, count: int) -> f32 {
	return f32(count) * t.tile + f32(max(0, count - 1)) * t.gap
}

// Lays out the board for the page at its current scroll: the inspector at the right while the list
// is wide enough for it and three tiles, above the board otherwise. Beside the board the inspector
// scrolls with it only until its bottom shows, and then stays, so its picker stays in reach.
@(private)
color_board_layout :: proc(p: ^Editor, l: Editor_Layout) -> (b: Board_Layout) {
	s := l.scale
	if s <= 0 || l.row_height <= 0 {return}
	b.scale = s
	width := l.list.width / s
	inspector := BOARD_INSPECTOR_WIDTH
	narrow := width - BOARD_INSPECTOR_MIN - BOARD_GAP
	if board_tiling(narrow).fit > board_tiling(width - inspector - BOARD_GAP).fit {
		inspector = BOARD_INSPECTOR_MIN
	}
	board := width - inspector - BOARD_GAP
	stacked := board < board_run_width(board_tiling(board), 3)
	if stacked {inspector, board = min(BOARD_INSPECTOR_WIDTH, width), width}
	b.inspector = board_inspector_layout(p, inspector, s)
	top := f32(0)
	if stacked {top = math.ceil((b.inspector.rect.height + BOARD_GAP * s) / l.row_height) * l.row_height}
	height := board_flow(p, &b, board_tiling(board), board, s)
	content := stacked ? top + height : max(height, b.inspector.rect.height)
	b.lines = int(math.ceil(content / l.row_height - 0.001))
	scroll := f32(p.scroll) * l.row_height
	b.origin = {l.list.x, l.list.y + top - scroll}
	for &tile in b.tiles[:b.tile_count] {tile.rect = board_move_rect(tile.rect, b.origin.x, b.origin.y)}
	for &heading in b.headings[:b.heading_count] {
		heading.rect = board_move_rect(heading.rect, b.origin.x, b.origin.y)
	}
	for &side in b.sides[:b.side_count] {side.rect = board_move_rect(side.rect, b.origin.x, b.origin.y)}
	x, y := l.list.x, l.list.y - scroll
	if !stacked {
		overflow := max(0, b.inspector.rect.height - l.list.height)
		x = l.list.x + (board + BOARD_GAP) * s
		y = l.list.y + clamp(scroll - overflow, 0, max(0, content - b.inspector.rect.height)) - scroll
	}
	board_inspector_move(&b.inspector, x, y)
	return
}

// Places the headings and tiles from the content origin, groups flowing left to right and wrapping
// below; returns the board's height in pixels.
@(private)
board_flow :: proc(p: ^Editor, b: ^Board_Layout, t: Board_Tiling, width, s: f32) -> f32 {
	per_line := max(1, int((width + t.gap) / (t.tile + t.gap)))
	x, y, band: f32
	side := ""
	started := false
	for item, index in p.items {
		if item.row >= 0 {continue}
		group, grouped := board_group(p, item.group)
		if !grouped {continue}
		tiles := 0
		for next := index + 1; next < len(p.items) && p.items[next].row >= 0; next += 1 {
			if board_tile_item(p, next) {tiles += 1}
		}
		if !started || group.side != side {
			x, y, band = 0, y + band, 0
			if group.side != "" {
				b.sides[b.side_count] = {group.side, 0, {0, y * s, width * s, BOARD_SIDE_HEADING * s}}
				b.side_count += 1
				y += BOARD_SIDE_HEADING
			}
			side, started = group.side, true
		}
		if group.side != "" {b.sides[b.side_count - 1].tiles += tiles}
		columns := clamp(tiles, 1, per_line)
		lines := max(1, (tiles + per_line - 1) / per_line)
		group_width := board_run_width(t, columns)
		if x > 0 && x + group_width > width {x, y, band = 0, y + band, 0}
		b.headings[b.heading_count] = {index, {x * s, y * s, group_width * s, BOARD_GROUP_HEADING * s}}
		b.heading_count += 1
		placed := 0
		for next := index + 1; next < len(p.items) && p.items[next].row >= 0; next += 1 {
			if !board_tile_item(p, next) || b.tile_count >= BOARD_TILE_LIMIT {continue}
			column, line := placed % per_line, placed / per_line
			tile := render.Rect {
				(x + f32(column) * (t.tile + t.gap)) * s,
				(y + BOARD_GROUP_HEADING + f32(line) * BOARD_TILE_LINE) * s,
				t.tile * s,
				(BOARD_SWATCH + SPACE_1 + BOARD_LABEL) * s,
			}
			b.tiles[b.tile_count] = {next, tile}
			b.tile_count += 1
			placed += 1
		}
		x += group_width + t.group_gap
		band = max(band, BOARD_GROUP_HEADING + f32(lines) * BOARD_TILE_LINE)
	}
	return (y + band) * s
}

// The inspector from its own top left: the theme's card with its fields and buttons, then the color's
// title, picker, base value and the colors that share its value.
@(private)
board_inspector_layout :: proc(p: ^Editor, width, s: f32) -> (b: Board_Inspector) {
	pad := BOARD_PAD
	b.row = board_token(p)
	b.item = board_item_of(p, b.row)
	y := pad
	b.title_y = y * s
	y += BOARD_GROUP_HEADING
	b.detail_y = y * s
	y += BOARD_TEXT_LINE
	if p.board.card.note != "" {
		b.note_y = y * s
		y += BOARD_TEXT_LINE
	}
	y += SPACE_2
	actions := 0
	for item, index in p.items {
		if !board_card_item(p, index) {continue}
		if p.rows[item.row].kind == .Action {actions += 1; continue}
		if b.field_count >= BOARD_CARD_LIMIT {continue}
		field := render.Rect {
			(pad + BOARD_FIELD_LABEL) * s,
			y * s,
			(width - 2 * pad - BOARD_FIELD_LABEL) * s,
			HEIGHT_STANDARD * s,
		}
		b.fields[b.field_count] = {index, field}
		b.field_count += 1
		y += HEIGHT_STANDARD + SPACE_2
	}
	if actions > 0 {
		count := min(actions, BOARD_CARD_LIMIT)
		button := (width - 2 * pad - f32(count - 1) * SPACE_2) / f32(count)
		for item, index in p.items {
			if b.button_count >= count || !board_card_item(p, index) || p.rows[item.row].kind != .Action {continue}
			left := pad + f32(b.button_count) * (button + SPACE_2)
			b.buttons[b.button_count] = {index, {left * s, y * s, button * s, HEIGHT_TOOLBAR * s}}
			b.button_count += 1
		}
		y += HEIGHT_TOOLBAR
	} else {
		y -= SPACE_2
	}
	y += pad
	b.card = {0, 0, width * s, y * s}
	y += SPACE_3
	top := y
	y += pad
	b.token_y = y * s
	// The title, then two lines of description.
	y += BOARD_GROUP_HEADING + 2 * BOARD_TEXT_LINE
	optional := b.row >= 0 && p.rows[b.row].kind == .Optional_Color
	// color_parts insets the wheel by SPACE_3, so the picker starts that far above and left of it. The
	// hex field sits under its swatch, and No Color, for a color that may have none, under its wheel.
	b.picker = {0, (y - SPACE_3) * s, BOARD_INSPECTOR_MIN * s, 0}
	c := color_parts(b.picker, optional, s)
	b.hex = {c.swatch.x, c.swatch.y + c.swatch.height + SPACE_2 * s, c.swatch.width, HEIGHT_STANDARD * s}
	bottom := optional ? c.no_color.y + c.no_color.height : c.wheel.y + c.wheel.height
	b.picker.height = bottom + SPACE_3 * s - b.picker.y
	y = bottom / s + SPACE_3
	b.base = {pad * s, y * s, (width - 2 * pad) * s, HEIGHT_COMPACT * s}
	b.reset = {(width - pad - BOARD_RESET_WIDTH) * s, y * s, BOARD_RESET_WIDTH * s, HEIGHT_COMPACT * s}
	y += HEIGHT_COMPACT + SPACE_2
	b.same_y = y * s
	y += BOARD_TEXT_LINE
	if b.row >= 0 && p.rows[b.row].value != "" {
		value := p.rows[b.row].value
		chip := (width - 2 * pad - SPACE_2) / 2
		for item, index in p.items {
			if item.row == b.row || !board_tile_item(p, index) || p.rows[item.row].value != value {continue}
			b.same_count += 1
			if b.chip_count >= BOARD_CHIP_LIMIT {continue}
			column, line := b.chip_count % 2, b.chip_count / 2
			b.chips[b.chip_count] = {index, {
				(pad + f32(column) * (chip + SPACE_2)) * s,
				(y + SPACE_1 + f32(line) * (BOARD_CHIP_HEIGHT + SPACE_1)) * s,
				chip * s,
				BOARD_CHIP_HEIGHT * s,
			}}
			b.chip_count += 1
		}
		y += SPACE_1 + f32((b.chip_count + 1) / 2) * (BOARD_CHIP_HEIGHT + SPACE_1)
		if b.same_count > b.chip_count {y += BOARD_TEXT_LINE}
	}
	y += pad
	b.token = {0, top * s, width * s, (y - top) * s}
	b.rect = {0, 0, width * s, y * s}
	return
}

@(private)
board_inspector_move :: proc(b: ^Board_Inspector, dx, dy: f32) {
	for r in ([?]^render.Rect{&b.rect, &b.card, &b.token, &b.picker, &b.hex, &b.base, &b.reset}) {
		r^ = board_move_rect(r^, dx, dy)
	}
	for y in ([?]^f32{&b.title_y, &b.detail_y, &b.note_y, &b.token_y, &b.same_y}) {y^ += dy}
	for &place in b.fields[:b.field_count] {place.rect = board_move_rect(place.rect, dx, dy)}
	for &place in b.buttons[:b.button_count] {place.rect = board_move_rect(place.rect, dx, dy)}
	for &place in b.chips[:b.chip_count] {place.rect = board_move_rect(place.rect, dx, dy)}
}

@(private)
board_optional :: proc(p: ^Editor, b: ^Board_Inspector) -> bool {
	return b.row >= 0 && p.rows[b.row].kind == .Optional_Color
}

@(private)
board_modified :: proc(row: ^Editor_Row) -> bool {return row.value != row.default_value}

@(private)
color_board_hit :: proc(p: ^Editor, b: ^Board_Layout, x, y, s: f32) -> Board_Hit {
	inspector := &b.inspector
	if render.rect_contains(inspector.rect, x, y) {
		for place in inspector.fields[:inspector.field_count] {
			if render.rect_contains(place.rect, x, y) {return {.Field, place.item}}
		}
		for place in inspector.buttons[:inspector.button_count] {
			if render.rect_contains(place.rect, x, y) {return {.Button, place.item}}
		}
		for place in inspector.chips[:inspector.chip_count] {
			if render.rect_contains(place.rect, x, y) {return {.Chip, place.item}}
		}
		if inspector.item < 0 {return {}}
		c := color_parts(inspector.picker, board_optional(p, inspector), s)
		ramp := render.Rect{c.ramp.x, c.ramp.y - 6 * s, c.ramp.width, c.ramp.height + 12 * s}
		switch {
		case render.rect_contains(c.wheel, x, y):
			return {.Wheel, inspector.item}
		case render.rect_contains(ramp, x, y):
			return {.Ramp, inspector.item}
		case render.rect_contains(inspector.hex, x, y):
			return {.Hex, inspector.item}
		case render.rect_contains(c.no_color, x, y):
			return {.No_Color, inspector.item}
		case render.rect_contains(inspector.reset, x, y):
			return {.Reset, inspector.item}
		}
		return {}
	}
	for tile in b.tiles[:b.tile_count] {
		if render.rect_contains(tile.rect, x, y) {return {.Tile, tile.item}}
	}
	return {}
}

// Selects `item` with its control focused, and puts `control` of the inspector under the keyboard.
// Leaving the hex field for any other part shows the saved value again.
@(private)
board_choose :: proc(p: ^Editor, item: int, control: Board_Control) {
	if item != p.selected {editor_select(p, item)}
	editor_mode_set(p, Editor_Editing{})
	p.board.control = control
	if control != .Hex && board_tile_item(p, item) {
		field_set(&p.value, p.rows[p.items[item].row].value)
		sync_color(p)
	}
}

// Whether the hex field has the keyboard: the picker is held or was last used, or the field was
// focused.
@(private)
board_hex_focused :: proc(p: ^Editor) -> bool {
	if !board_tile_item(p, p.selected) {return false}
	#partial switch _ in p.mode {
	case Editor_Color_Popup:
		return true
	case Editor_Editing:
		return p.board.control == .Hex
	}
	return false
}

@(private)
board_field_press :: proc(p: ^Editor, text: ^Text, rect: render.Rect, x, s: f32, extend: bool) {
	if text != nil {
		box := field_box_standard(&p.value, text, rect, s)
		field_pointer(&p.value, field_box_offset(box, x), true, extend)
	} else {
		field_select_all(&p.value)
	}
	editor_mode_set(p, Editor_Editing{drag = .Value})
}

// A press inside the list while the board is shown. Outside it the picker is no popup to dismiss, so
// the press carries on to the search, outline or tabs.
@(private)
color_board_press :: proc(
	p: ^Editor,
	l: Editor_Layout,
	text: ^Text,
	x, y: f32,
	extend: bool,
) -> (
	Editor_Outcome,
	bool,
) {
	if !color_board_shown(p) {return .None, false}
	if !render.rect_contains(l.list, x, y) {
		if editor_popup(p) == .Color {
			editor_mode_set(p, Editor_Editing{})
			p.board.control = .Hex
		}
		return .None, false
	}
	s := l.scale
	b := color_board_layout(p, l)
	hit := color_board_hit(p, &b, x, y, s)
	switch hit.target {
	case .None:
		editor_blur(p)
	case .Tile, .Chip:
		board_choose(p, hit.item, .Tile)
	case .Field:
		board_choose(p, hit.item, .Tile)
		for place in b.inspector.fields[:b.inspector.field_count] {
			if place.item == hit.item {board_field_press(p, text, place.rect, x, s, extend)}
		}
	case .Button:
		board_choose(p, hit.item, .Tile)
		return .Save, true
	case .Wheel, .Ramp:
		board_choose(p, hit.item, .Hex)
		drag: Color_Drag = hit.target == .Wheel ? .Wheel : .Ramp
		editor_mode_set(p, Editor_Color_Popup{drag})
		pick_color(p, color_parts(b.inspector.picker, board_optional(p, &b.inspector), s), drag, x, y)
	case .Hex:
		board_choose(p, hit.item, .Hex)
		board_field_press(p, text, b.inspector.hex, x, s, extend)
	case .No_Color:
		board_choose(p, hit.item, .No_Color)
		field_set(&p.value, "")
		return .Save, true
	case .Reset:
		board_choose(p, hit.item, .Reset)
		if board_modified(editor_row(p)) {return .Reset, true}
	}
	return .Changed, true
}

// The hover over the board; true when it changed.
@(private)
color_board_hover :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	hit: Board_Hit
	if color_board_shown(p) && render.rect_contains(l.list, x, y) && !editor_dragging(p) {
		b := color_board_layout(p, l)
		hit = color_board_hit(p, &b, x, y, l.scale)
	}
	return board_hover_set(p, hit)
}

@(private)
board_hover_set :: proc(p: ^Editor, hit: Board_Hit) -> bool {
	b := &p.board
	if hit == b.hover_hit {return false}
	b.hover_hit = hit
	row := hit.target == .Tile ? p.items[hit.item].row : -1
	if row == (b.hovered ? b.hover_row : -1) {return true}
	if b.hovered {b.fade, b.fade_row, b.faded = b.hover, b.hover_row, true}
	b.hover, b.hover_row, b.hovered = {}, row, row >= 0
	return true
}

@(private)
color_board_pointer :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> (platform.Cursor_Shape, bool) {
	if !color_board_shown(p) || !render.rect_contains(l.list, x, y) {return .Arrow, false}
	b := color_board_layout(p, l)
	hit := color_board_hit(p, &b, x, y, l.scale)
	switch hit.target {
	case .None:
		return .Arrow, true
	case .Field, .Hex:
		return .Text, true
	case .Reset:
		return board_modified(&p.rows[p.items[hit.item].row]) ? .Hand : .Arrow, true
	case .Tile, .Chip, .Button, .Wheel, .Ramp, .No_Color:
	}
	return .Hand, true
}

@(private)
color_board_over_text :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	b := color_board_layout(p, l)
	hit := color_board_hit(p, &b, x, y, l.scale)
	return hit.target == .Field || hit.target == .Hex
}

// The parts editor_row_parts reports for a board line: a tile's rect with the inspector's hex field
// and Reset, or a card control as its field.
@(private)
color_board_row_parts :: proc(p: ^Editor, l: Editor_Layout, index: int) -> (parts: Row_Parts, ok: bool) {
	if !color_board_shown(p) {return}
	b := color_board_layout(p, l)
	for tile in b.tiles[:b.tile_count] {
		if tile.item != index {continue}
		parts.row = tile.rect
		if index == b.inspector.item {parts.field, parts.reset = b.inspector.hex, b.inspector.reset}
		return parts, true
	}
	for place in b.inspector.fields[:b.inspector.field_count] {
		if place.item == index {return {row = place.rect, field = place.rect}, true}
	}
	for place in b.inspector.buttons[:b.inspector.button_count] {
		if place.item == index {return {row = place.rect, field = place.rect}, true}
	}
	for heading in b.headings[:b.heading_count] {
		if heading.item == index {return {row = heading.rect}, true}
	}
	return {row = b.inspector.card}, true
}

// The picker while the board's hex field is being edited: the inspector's, at its fixed place.
@(private)
color_board_popup_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	if editor_popup(p) != .Color || !board_tile_item(p, p.selected) {return {}}
	b := color_board_layout(p, l)
	return b.inspector.item == p.selected ? b.inspector.picker : {}
}

@(private)
color_board_max_scroll :: proc(p: ^Editor) -> int {
	l := p.fit_layout
	if l.row_height <= 0 {return 0}
	return max(0, color_board_lines(p, l) - max(1, l.rows))
}

// How many page lines the board and its inspector take, for the page's scrollbar and reports.
color_board_lines :: proc(p: ^Editor, l: Editor_Layout) -> int {
	b := color_board_layout(p, l)
	return b.lines
}

// The pixel distance from the top of the content to `y` on screen.
@(private)
board_content_y :: proc(p: ^Editor, l: Editor_Layout, y: f32) -> f32 {
	return y - l.list.y + f32(p.scroll) * l.row_height
}

// Scrolls the selected tile into view, with its group's heading when it is the first line.
@(private)
color_board_reveal :: proc(p: ^Editor) {
	l := p.fit_layout
	if l.row_height <= 0 || l.rows <= 0 {return}
	b := color_board_layout(p, l)
	for tile in b.tiles[:b.tile_count] {
		if tile.item != p.selected {continue}
		top := board_content_y(p, l, tile.rect.y) - BOARD_GROUP_HEADING * l.scale
		bottom := board_content_y(p, l, tile.rect.y + tile.rect.height)
		if top < f32(p.scroll) * l.row_height {p.scroll = int(math.floor(top / l.row_height))}
		if bottom > f32(p.scroll + l.rows) * l.row_height {
			p.scroll = int(math.ceil(bottom / l.row_height - 0.001)) - l.rows
		}
		p.scroll = clamp(p.scroll, 0, max(0, b.lines - l.rows))
		return
	}
}

// The scroll line that shows group header `header` at the top, with its side's heading over the
// side's first group.
@(private)
color_board_line :: proc(p: ^Editor, header: int) -> int {
	l := p.fit_layout
	if l.row_height <= 0 {return 0}
	b := color_board_layout(p, l)
	for heading in b.headings[:b.heading_count] {
		if heading.item != header {continue}
		top := heading.rect.y
		for side in b.sides[:b.side_count] {
			if abs(side.rect.y + side.rect.height - top) < 1 && heading.rect.x == b.origin.x {top = side.rect.y}
		}
		return int(math.floor(board_content_y(p, l, top) / l.row_height + 0.001))
	}
	return 0
}

// The group at the top of the board, or the card's at the very top.
@(private)
color_board_group_at :: proc(p: ^Editor) -> int {
	l := p.fit_layout
	active := p.items[0].group
	if p.scroll == 0 || l.row_height <= 0 {return active}
	b := color_board_layout(p, l)
	best := f32(-1)
	for heading in b.headings[:b.heading_count] {
		y := board_content_y(p, l, heading.rect.y)
		if y <= f32(p.scroll + 1) * l.row_height + 1 && y > best {
			active, best = p.items[heading.item].group, y
		}
	}
	return active
}

// Typing on a focused tile starts editing its hex value; Reset and No Color take no typing. True
// when the text goes nowhere.
@(private)
color_board_text :: proc(p: ^Editor) -> bool {
	if !color_board_shown(p) || editor_focus(p) != .Control || !board_tile_item(p, p.selected) {return false}
	if board_hex_focused(p) {return false}
	if p.board.control != .Tile {return true}
	p.board.control = .Hex
	field_select_all(&p.value)
	return false
}

// Leaves the hex field without saving, back on its tile.
@(private)
board_hex_cancel :: proc(p: ^Editor) {
	board_choose(p, p.selected, .Tile)
}

// Keys while the board is shown. Arrows move between tiles, Enter or Space edits the focused tile's
// hex value or presses the focused button, Escape leaves the hex field and Tab walks the board as a
// browser walks a form. Keys it leaves go on to the page.
@(private)
color_board_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	if !color_board_shown(p) || .Alt in e.modifiers {return .None, false}
	b := &p.board
	focus := editor_focus(p)
	control := .Control in e.modifiers
	tile := board_tile_item(p, p.selected)
	hex := board_hex_focused(p)
	card := focus == .Control && board_card_item(p, p.selected)
	#partial switch e.key {
	case .Tab:
		if control {return .None, false}
		return board_tab(p, .Shift in e.modifiers), true
	case .Escape:
		if !hex {return .None, false}
		board_hex_cancel(p)
		return .Changed, true
	case .Enter, .Numpad_Enter, .Space:
		if hex {
			if e.key == .Space {return .None, false}
			editor_mode_set(p, Editor_Editing{})
			b.control = .Tile
			return .Save, true
		}
		if !tile || focus != .Control {return .None, false}
		switch b.control {
		case .Tile, .Hex:
			b.control = .Hex
			field_select_all(&p.value)
			return .Changed, true
		case .No_Color:
			field_set(&p.value, "")
			return .Save, true
		case .Reset:
			return board_modified(row) ? .Reset : .None, true
		}
	case .Arrow_Up, .Arrow_Down, .Page_Up, .Page_Down:
		if control && (e.key == .Page_Up || e.key == .Page_Down) {return .None, false}
		if hex {return .None, true}
		up := e.key == .Arrow_Up || e.key == .Page_Up
		if card {return board_card_step(p, up ? -1 : 1), true}
		return board_move(p, e.key), true
	case .Arrow_Left, .Arrow_Right, .Home, .End:
		if hex || card || focus == .Search {return .None, false}
		return board_move(p, e.key), true
	case .N, .P:
		if !control || hex || card {return .None, false}
		return board_move(p, e.key == .N ? .Arrow_Right : .Arrow_Left), true
	}
	// A focused tile, No Color or Reset takes no typing; the hex field does.
	if tile && focus == .Control && !hex && !control {return .None, true}
	return .None, false
}

// Moves the selection to another tile: along the board's order for Left, Right, Home and End, and to
// the nearest tile of the line above or below for Up, Down and the page keys. From a card control it
// returns to the inspector's tile first.
@(private)
board_move :: proc(p: ^Editor, key: input.Key) -> Editor_Outcome {
	l := p.fit_layout
	b := color_board_layout(p, l)
	if b.tile_count == 0 {return .None}
	current := -1
	for tile, i in b.tiles[:b.tile_count] {if tile.item == b.inspector.item {current = i}}
	target := max(0, current)
	if current >= 0 && board_tile_item(p, p.selected) {
		#partial switch key {
		case .Arrow_Left:
			target = max(0, current - 1)
		case .Arrow_Right:
			target = min(b.tile_count - 1, current + 1)
		case .Home:
			target = 0
		case .End:
			target = b.tile_count - 1
		case .Arrow_Up, .Arrow_Down:
			target = board_line_step(&b, current, key == .Arrow_Up)
		case .Page_Up, .Page_Down:
			travelled: f32
			for travelled < l.list.height {
				next := board_line_step(&b, target, key == .Page_Up)
				if next == target {break}
				travelled += abs(b.tiles[next].rect.y - b.tiles[target].rect.y)
				target = next
			}
		}
	}
	focus := editor_focus(p)
	if b.tiles[target].item != p.selected {editor_select(p, b.tiles[target].item)}
	if focus == .Control {
		editor_mode_set(p, Editor_Editing{})
		p.board.control = .Tile
	}
	return .Changed
}

// The tile in the nearest line above or below `from` closest to it horizontally, or `from` itself.
@(private)
board_line_step :: proc(b: ^Board_Layout, from: int, up: bool) -> int {
	origin := b.tiles[from].rect
	center := origin.x + origin.width / 2
	best, best_dy, best_dx := from, max(f32), max(f32)
	for tile, i in b.tiles[:b.tile_count] {
		dy := up ? origin.y - tile.rect.y : tile.rect.y - origin.y
		if dy < 1 {continue}
		dx := abs(tile.rect.x + tile.rect.width / 2 - center)
		if dy < best_dy - 1 || (abs(dy - best_dy) < 1 && dx < best_dx) {best, best_dy, best_dx = i, dy, dx}
	}
	return best
}

// Moves between the card's controls, which stay in their own column.
@(private)
board_card_step :: proc(p: ^Editor, step: int) -> Editor_Outcome {
	for index := p.selected + step; index >= 0 && index < len(p.items); index += step {
		if !board_card_item(p, index) {continue}
		editor_select(p, index)
		editor_mode_set(p, Editor_Editing{})
		if text_kind(p.rows[p.items[index].row].kind) {field_select_all(&p.value)}
		return .Changed
	}
	return .None
}

@(private)
Board_Stop_Kind :: enum u8 {
	Search,
	Tile,
	Card,
	Hex,
	No_Color,
	Reset,
	Reset_All,
}

@(private)
Board_Stop :: struct {
	kind: Board_Stop_Kind,
	item: int,
}

// Tab and Shift+Tab over the board: the search, the board as one stop on its chosen tile, each card
// control, the hex field, No Color for a color that may have none, Reset while the color differs from
// its base, then Reset to Defaults, and round again.
@(private)
board_tab :: proc(p: ^Editor, back: bool) -> Editor_Outcome {
	stops: [BOARD_CARD_LIMIT + 6]Board_Stop
	count := 0
	add :: proc(stops: []Board_Stop, count: ^int, stop: Board_Stop) {
		if count^ < len(stops) {stops[count^] = stop; count^ += 1}
	}
	token := color_board_first(p)
	add(stops[:], &count, {.Search, -1})
	if token >= 0 {add(stops[:], &count, {.Tile, token})}
	for _, index in p.items {
		if board_card_item(p, index) {add(stops[:], &count, {.Card, index})}
	}
	if token >= 0 {
		row := &p.rows[p.items[token].row]
		add(stops[:], &count, {.Hex, token})
		if row.kind == .Optional_Color {add(stops[:], &count, {.No_Color, token})}
		if board_modified(row) {add(stops[:], &count, {.Reset, token})}
	}
	add(stops[:], &count, {.Reset_All, -1})
	focus := editor_focus(p)
	current: Board_Stop
	switch focus {
	case .Search, .Positions:
		current = {.Search, -1}
	case .Reset_All:
		current = {.Reset_All, -1}
	case .Page, .Control:
		current = {.Card, p.selected}
		if board_tile_item(p, p.selected) {
			current.kind = .Tile
			if focus == .Control {
				switch {
				case board_hex_focused(p):
					current.kind = .Hex
				case p.board.control == .No_Color:
					current.kind = .No_Color
				case p.board.control == .Reset:
					current.kind = .Reset
				}
			}
		}
	}
	at := 0
	for stop, i in stops[:count] {
		if stop.kind == current.kind && (stop.item == current.item || stop.item < 0) {at = i}
	}
	// From the page itself, Tab resumes on the selection's own stop.
	step := back ? -1 : 1
	next := stops[(at + step + count) %% count]
	if focus == .Page && !back {next = stops[at]}
	switch next.kind {
	case .Search:
		if focus != .Search {editor_keep(p); stop_editing(p)}
	case .Reset_All:
		if focus != .Search {editor_keep(p); stop_editing(p)}
		editor_mode_set(p, Editor_Reset_All{})
	case .Tile:
		board_choose(p, next.item, .Tile)
	case .Card:
		editor_keep(p)
		board_choose(p, next.item, .Tile)
		if text_kind(editor_row(p).kind) {field_select_all(&p.value)}
	case .Hex:
		board_choose(p, next.item, .Hex)
		field_select_all(&p.value)
	case .No_Color:
		board_choose(p, next.item, .No_Color)
	case .Reset:
		board_choose(p, next.item, .Reset)
	}
	return .Changed
}

// Carries the board's choice and motion into a page rebuilt for a new revision, finding its rows by
// key since a theme copied from a file gains card rows before them.
@(private)
color_board_carry :: proc(to, from: ^Editor) {
	same :: proc(to, from: ^Editor, row: int) -> int {
		if row < 0 || row >= len(from.rows) {return -1}
		for candidate, i in to.rows {if candidate.key == from.rows[row].key {return i}}
		return -1
	}
	a, b := &to.board, &from.board
	a.row = same(to, from, board_token(from))
	a.control = b.control
	// Reset leaves the keyboard once it has nothing left to reset.
	if a.control == .Reset && (!board_tile_row(to, a.row) || !board_modified(&to.rows[a.row])) {
		a.control = .Tile
	}
	a.ring, a.ring_from, a.ring_shown = b.ring, b.ring_from, b.ring_shown
	a.ring_row = same(to, from, b.ring_row)
	a.marker, a.marker_from, a.marker_to, a.marker_shown = b.marker, b.marker_from, b.marker_to, b.marker_shown
	a.hover, a.fade, a.hovered, a.faded = b.hover, b.fade, b.hovered, b.faded
	a.hover_row, a.fade_row = same(to, from, b.hover_row), same(to, from, b.fade_row)
	if len(to.items) == len(from.items) {a.hover_hit = b.hover_hit}
}

@(private)
board_hsv :: proc(p: ^Editor, row: int) -> [3]f32 {
	if p.selected >= 0 && p.selected < len(p.items) && p.items[p.selected].row == row {return p.hsv}
	c, ok, _ := colour.parse(p.rows[row].value, .Permissive)
	if !ok {return {0, 0, 1}}
	h, s, v := colour.rgb_to_hsv(c)
	return {h, s, v}
}

@(private)
board_marker_point :: proc(hsv: [3]f32) -> [3]f32 {
	angle := math.to_radians(hsv[0])
	return {math.cos(angle) * hsv[1], math.sin(angle) * hsv[1], hsv[2]}
}

@(private)
board_marker_drawn :: proc(b: ^Color_Board) -> [3]f32 {
	if !motion_active(b.marker) {return b.marker_to}
	return b.marker_from + (b.marker_to - b.marker_from) * b.marker.value
}

// The swatch of the tile showing `row`.
@(private)
board_swatch_rect :: proc(b: ^Board_Layout, p: ^Editor, row: int) -> render.Rect {
	for tile in b.tiles[:b.tile_count] {
		if p.items[tile.item].row != row {continue}
		return {tile.rect.x, tile.rect.y, tile.rect.width, BOARD_SWATCH * b.scale}
	}
	return {}
}

// The selection ring as drawn on its way to `row`'s tile: sliding from where it was while it moves.
@(private)
board_ring_toward :: proc(p: ^Editor, b: ^Board_Layout, row: int) -> render.Rect {
	board := &p.board
	target := board_swatch_rect(b, p, row)
	if !board.ring_shown || board.ring_row != row || !motion_active(board.ring) {return target}
	from := board_move_rect(board.ring_from, b.origin.x, b.origin.y)
	t := board.ring.value
	return {
		from.x + (target.x - from.x) * t,
		from.y + (target.y - from.y) * t,
		from.width + (target.width - from.width) * t,
		from.height + (target.height - from.height) * t,
	}
}

@(private)
board_ring_rect :: proc(p: ^Editor, b: ^Board_Layout) -> render.Rect {
	return board_ring_toward(p, b, b.inspector.row)
}

// Advances the board's motion: the selection ring sliding to a newly chosen tile and the picker's
// markers gliding to a new color, both 140 ms decelerating, and the tile hover fading in 80 ms. A
// pointer drag on the picker moves its markers at once. True when the page must draw again.
@(private)
color_board_animate :: proc(p: ^Editor, enabled: bool, frame: Frame_Time) -> bool {
	b := &p.board
	if !color_board_shown(p) || p.fit_layout.row_height <= 0 {
		b.ring, b.marker, b.hover, b.fade = {}, {}, {}, {}
		b.ring_shown, b.marker_shown, b.hovered, b.faded = false, false, false, false
		b.hover_hit = {}
		return false
	}
	if token := board_token(p); token >= 0 {
		if !b.ring_shown || (token != b.ring_row && !enabled) {
			b.ring, b.ring_row, b.ring_shown = {value = 1, target = 1}, token, true
		} else if token != b.ring_row {
			layout := color_board_layout(p, p.fit_layout)
			drawn := board_ring_toward(p, &layout, b.ring_row)
			b.ring_from = board_move_rect(drawn, -layout.origin.x, -layout.origin.y)
			b.ring, b.ring_row = {value = 1, target = 1}, token
			// A ring with nowhere to come from appears on its tile.
			if drawn.width > 0 {
				b.ring = {}
				motion_target(&b.ring, 1, REORDER_DURATION, .Decelerate, enabled)
			}
		}
		point := board_marker_point(board_hsv(p, token))
		dragging := false
		if picker, open := p.mode.(Editor_Color_Popup); open {dragging = picker.drag != .None}
		if !b.marker_shown || dragging || !enabled {
			b.marker, b.marker_from, b.marker_to, b.marker_shown = {value = 1, target = 1}, point, point, true
		} else if point != b.marker_to {
			b.marker_from = board_marker_drawn(b)
			b.marker, b.marker_to = {}, point
			motion_target(&b.marker, 1, REORDER_DURATION, .Decelerate, enabled)
		}
	}
	changed := motion_update(&b.ring, frame)
	changed = motion_update(&b.marker, frame) || changed
	motion_target(&b.hover, b.hovered ? 1 : 0, CONTROL_MOTION_DURATION, .Linear, enabled)
	motion_target(&b.fade, 0, CONTROL_MOTION_DURATION, .Linear, enabled)
	changed = motion_update(&b.hover, frame) || changed
	changed = motion_update(&b.fade, frame) || changed
	if !motion_active(b.fade) {b.faded = false}
	return changed
}

color_board_animating :: proc(p: ^Editor) -> bool {
	b := &p.board
	return motion_active(b.ring) || motion_active(b.marker) || motion_active(b.hover) || motion_active(b.fade)
}

// A part of the board, for the state report and tests.
Board_Part :: enum {
	Wheel,
	Ramp,
	Hex,
	No_Color,
	Reset,
	Ring,
	Inspector,
}

// Where the board draws `part` at the page's scroll; zero while the board is hidden.
color_board_rect :: proc(p: ^Editor, l: Editor_Layout, part: Board_Part) -> render.Rect {
	if !color_board_shown(p) {return {}}
	b := color_board_layout(p, l)
	inspector := &b.inspector
	c := color_parts(inspector.picker, board_optional(p, inspector), l.scale)
	switch part {
	case .Wheel:
		return c.wheel
	case .Ramp:
		return c.ramp
	case .Hex:
		return inspector.hex
	case .No_Color:
		return c.no_color
	case .Reset:
		return inspector.reset
	case .Ring:
		return board_ring_rect(p, &b)
	case .Inspector:
		return inspector.rect
	}
	return {}
}

// Splits a label into the line that fits `width`, broken at a space, and the rest.
@(private)
board_label_split :: proc(t: ^Text, s: string, width: f32) -> (first, rest: string) {
	if text_width(t, s) <= width {return s, ""}
	cut := -1
	for r, offset in s {
		if r == ' ' && offset > 0 && text_width(t, s[:offset]) <= width {cut = offset}
	}
	if cut < 0 {return s, ""}
	return s[:cut], s[cut + 1:]
}

// `r` cut to `clip`. A scope opened on it replaces the list's clip, so it must not reach past it.
@(private)
board_clip :: proc(r, clip: render.Rect) -> render.Rect {
	left, top := max(r.x, clip.x), max(r.y, clip.y)
	right, bottom := min(r.x + r.width, clip.x + clip.width), min(r.y + r.height, clip.y + clip.height)
	return {left, top, max(0, right - left), max(0, bottom - top)}
}

// A color's fill: a translucent one over a checker so its alpha shows, and none as a crossed swatch.
@(private)
board_swatch_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	r, clip: render.Rect,
	value: string,
	s: f32,
) {
	radius := RADIUS_CONTROL * s
	color, ok := swatch_color(value)
	if !ok {
		draw_rect(list, {rect = r, color = theme.pane, radius = radius})
		inset := 3 * s
		a := [2]f32{r.x + inset, r.y + r.height - inset}
		b := [2]f32{r.x + r.width - inset, r.y + inset}
		_ = render.push_segment(list, a, b, 1.5 * s, theme.error)
		return
	}
	if color.a < 1 {
		draw_rect(list, {rect = r, color = theme.pane, radius = radius})
		scope, opened := clip_scope_open(list, board_clip(r, clip), radius)
		if opened {
			cell := 6 * s
			start := r.x + r.width * 0.55
			checker := theme.text
			checker.a = 0.22
			for column := 0; start + f32(column) * cell < r.x + r.width; column += 1 {
				for line := 0; f32(line) * cell < r.height; line += 1 {
					if (column + line) % 2 == 1 {continue}
					square := render.Rect{start + f32(column) * cell, r.y + f32(line) * cell, cell, cell}
					draw_rect(list, {rect = square, color = checker})
				}
			}
			clip_scope_close(list, scope)
		}
	}
	draw_rect(list, {rect = r, color = color, radius = radius})
}

@(private)
board_tile_draw :: proc(
	p: ^Editor,
	tile: Board_Place,
	token: int,
	list: ^render.Draw_List,
	small: ^Text,
	theme: Theme,
	clip: render.Rect,
	s: f32,
) -> render.Build_Status {
	b := &p.board
	row_index := p.items[tile.item].row
	row := &p.rows[row_index]
	radius := RADIUS_CONTROL * s
	swatch := render.Rect{tile.rect.x, tile.rect.y, tile.rect.width, BOARD_SWATCH * s}
	board_swatch_draw(list, theme, swatch, clip, row.value, s)
	modified := board_modified(row)
	if modified {
		// The base color as a strip along the bottom, so before and after sit side by side.
		scope, opened := clip_scope_open(list, board_clip(swatch, clip), radius)
		if opened {
			strip := render.Rect{swatch.x, swatch.y + swatch.height - 8 * s, swatch.width, 8 * s}
			draw_rect(list, {rect = {strip.x, strip.y - s, strip.width, s}, color = theme.pane})
			if base, ok := swatch_color(row.default_value); ok {
				draw_rect(list, {rect = strip, color = theme.pane})
				draw_rect(list, {rect = strip, color = base})
			}
			clip_scope_close(list, scope)
		}
	}
	draw_rect(list, {rect = swatch, color = theme.border, radius = radius, stroke = s})
	light: f32
	if b.hovered && b.hover_row == row_index {light = b.hover.value}
	if b.faded && b.fade_row == row_index {light = max(light, b.fade.value)}
	if light > 0 {
		ring := render.Rect{swatch.x - 2 * s, swatch.y - 2 * s, swatch.width + 4 * s, swatch.height + 4 * s}
		color := theme.muted
		color.a *= light * 0.6
		draw_rect(list, {rect = ring, color = color, radius = radius + 2 * s, stroke = 2 * s})
	}
	x := tile.rect.x
	ink := row_index == token ? theme.text : theme.muted
	if modified {
		dot_y := swatch.y + swatch.height + SPACE_1 * s + (small.line_height - 5 * s) / 2
		dot := render.Rect{x, dot_y, 5 * s, 5 * s}
		draw_rect(list, {rect = dot, color = theme.accent, radius = pill_radius(dot)})
		x += 8 * s
	}
	width := tile.rect.x + tile.rect.width - x
	label := row.badge != "" ? row.badge : row.title
	first, rest := board_label_split(small, label, width)
	baseline := swatch.y + swatch.height + SPACE_1 * s + small.ascent
	if result := draw_fading_text(small, list, first, x, baseline, ink, width); result != .Ok {return result}
	if rest == "" {return .Ok}
	return draw_fading_text(small, list, rest, x, baseline + small.line_height, ink, width)
}

// A card button; Delete takes the danger style and, while it waits for its second press, names
// itself and fills with the danger color.
@(private)
board_button_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	rect: render.Rect,
	focused: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	s: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if row.action != .Theme_Delete {
		return text_button_draw(list, text, theme, rect, row.value, focused, s, pointer)
	}
	radius := RADIUS_CONTROL * s
	armed := p.delete_armed
	fill := theme.error
	if !armed {fill.a *= 0.14}
	draw_rect(list, {rect = rect, color = fill, radius = radius})
	if focused {focus_ring_draw(list, rect, theme, s)}
	if render.rect_contains(rect, pointer.x, pointer.y) {
		if hover_rim_draw(list, theme, rect, radius, 1, s, pointer, false) != .None {return .Ok}
	}
	// Armed, the button deletes on this press.
	label := armed ? "Delete" : row.value
	strong := text_styled(text, .Strong)
	inset := CONTROL_INSET * s
	width := min(text_width(&strong, label), max(0, rect.width - 2 * inset))
	return draw_text(
		&strong,
		list,
		label,
		rect.x + (rect.width - width) / 2,
		rect.y + (rect.height - strong.line_height) / 2 + strong.ascent,
		armed ? theme.pane : theme.error,
		max(1, rect.width - 2 * inset),
	)
}

@(private)
board_card_draw :: proc(
	p: ^Editor,
	b: ^Board_Inspector,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	clip: render.Rect,
	s: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	card := &p.board.card
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Detail)
	draw_rect(list, {rect = b.card, color = theme.border, radius = RADIUS_OVERLAY * s, stroke = s})
	pad := BOARD_PAD * s
	x := b.card.x + pad
	right := b.card.x + b.card.width - pad
	badge_width := text_width(&small, card.badge) + 2 * SPACE_2 * s
	title_baseline := b.title_y + (BOARD_GROUP_HEADING * s - strong.line_height) / 2 + strong.ascent
	title_room := max(1, right - x - badge_width - SPACE_2 * s)
	if r := draw_text(&strong, list, card.title, x, title_baseline, theme.text, title_room); r != .Ok {return r}
	if card.badge != "" {
		left := x + min(text_width(&strong, card.title), title_room) + SPACE_2 * s
		pill := render.Rect{left, b.title_y + s, badge_width, (BOARD_GROUP_HEADING - 2) * s}
		ink := card.custom ? theme.accent : theme.muted
		edge := card.custom ? theme.accent : theme.border
		draw_rect(list, {rect = pill, color = edge, radius = RADIUS_CONTROL * s, stroke = s})
		pill_baseline := pill.y + (pill.height - small.line_height) / 2 + small.ascent
		if r := draw_text(&small, list, card.badge, pill.x + SPACE_2 * s, pill_baseline, ink); r != .Ok {return r}
	}
	detail_baseline := b.detail_y + small.ascent
	if r := draw_text(&small, list, card.detail, x, detail_baseline, theme.faint, right - x); r != .Ok {return r}
	changed := 0
	for item, index in p.items {
		if board_tile_item(p, index) && board_modified(&p.rows[item.row]) {changed += 1}
	}
	if changed > 0 {
		buffer: [32]u8
		parts := [?]string{" · ", strconv.write_int(buffer[:], i64(changed), 10), " changed"}
		left := x + text_width(&small, card.detail)
		if _, r := board_text_run(&small, list, parts[:], left, detail_baseline, theme.accent); r != .Ok {return r}
	}
	if card.note != "" {
		if r := draw_text(&small, list, card.note, x, b.note_y + small.ascent, theme.muted, right - x); r != .Ok {
			return r
		}
	}
	for place in b.fields[:b.field_count] {
		row := &p.rows[p.items[place.item].row]
		selected := place.item == p.selected
		focused := selected && editor_editing(p)
		label_baseline := place.rect.y + (place.rect.height - small.line_height) / 2 + small.ascent
		label_room := (BOARD_FIELD_LABEL - SPACE_1) * s
		if r := draw_text(&small, list, row.title, x, label_baseline, theme.muted, label_room); r != .Ok {return r}
		box_draw(list, place.rect, theme, focused, s)
		if selected {
			box := field_box_standard(&p.value, text, place.rect, s)
			baseline := field_box_baseline(box)
			box.rect = board_clip(box.rect, clip)
			if r := field_box_draw(box, list, theme, baseline, focused, "Empty"); r != .Ok {return r}
		} else {
			body := text_styled(text, .Body)
			baseline := place.rect.y + (place.rect.height - body.line_height) / 2 + body.ascent
			shown := row.value != "" ? row.value : "Empty"
			ink := row.value != "" ? theme.text : theme.muted
			if r := draw_text(&body, list, shown, place.rect.x + CONTROL_INSET * s, baseline, ink,
				place.rect.width - 2 * CONTROL_INSET * s); r != .Ok {return r}
		}
	}
	for place in b.buttons[:b.button_count] {
		row := &p.rows[p.items[place.item].row]
		focused := place.item == p.selected && editor_editing(p)
		if r := board_button_draw(p, row, place.rect, focused, list, text, theme, s, pointer); r != .Ok {return r}
	}
	return .Ok
}

// Draws `parts` one after another from `x` on one baseline; returns where the last one ends.
@(private)
board_text_run :: proc(
	t: ^Text,
	list: ^render.Draw_List,
	parts: []string,
	x, baseline: f32,
	color: render.Color,
) -> (
	f32,
	render.Build_Status,
) {
	pen := x
	for part in parts {
		if r := draw_text(t, list, part, pen, baseline, color); r != .Ok {return pen, r}
		pen += text_width(t, part)
	}
	return pen, .Ok
}

@(private)
board_token_draw :: proc(
	p: ^Editor,
	b: ^Board_Inspector,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	clip: render.Rect,
	s: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if b.row < 0 {return .Ok}
	board := &p.board
	row := &p.rows[b.row]
	selected := p.selected == b.item
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Detail)
	draw_rect(list, {rect = b.token, color = theme.border, radius = RADIUS_OVERLAY * s, stroke = s})
	pad := BOARD_PAD * s
	x := b.token.x + pad
	right := b.token.x + b.token.width - pad
	title_baseline := b.token_y + (BOARD_GROUP_HEADING * s - strong.line_height) / 2 + strong.ascent
	if r := draw_text(&strong, list, row.title, x, title_baseline, theme.text, right - x); r != .Ok {return r}
	key_left := x + text_width(&strong, row.title) + SPACE_2 * s
	if key_left < right {
		if r := draw_fading_text(&small, list, row.key, key_left, title_baseline, theme.faint, right - key_left);
		   r != .Ok {return r}
	}
	first, rest := board_label_split(&small, row.description, right - x)
	line := b.token_y + BOARD_GROUP_HEADING * s + small.ascent
	if r := draw_fading_text(&small, list, first, x, line, theme.muted, right - x); r != .Ok {return r}
	if rest != "" {
		if r := draw_fading_text(&small, list, rest, x, line + BOARD_TEXT_LINE * s, theme.muted, right - x);
		   r != .Ok {return r}
	}
	optional := row.kind == .Optional_Color
	c := color_parts(b.picker, optional, s)
	hsv := board_hsv(p, b.row)
	if board.marker_shown && motion_active(board.marker) {
		point := board_marker_drawn(board)
		hue := math.to_degrees(math.atan2(point[1], point[0]))
		if hue < 0 {hue += 360}
		hsv = {hue, min(1, math.sqrt(point[0] * point[0] + point[1] * point[1])), point[2]}
	}
	value := selected ? field_string(&p.value) : row.value
	color_picker_draw(list, theme, c, hsv, value, s)
	brightness := c.ramp.y - SPACE_2 * s
	if r := draw_text(&small, list, "Brightness", c.ramp.x, brightness, theme.faint, c.ramp.width); r != .Ok {
		return r
	}
	hex_focused := board_hex_focused(p)
	box_draw(list, b.hex, theme, hex_focused, s)
	if selected {
		box := field_box_standard(&p.value, text, b.hex, s)
		placeholder := optional ? "None" : "Empty"
		baseline := field_box_baseline(box)
		box.rect = board_clip(box.rect, clip)
		if r := field_box_draw(box, list, theme, baseline, hex_focused, placeholder); r != .Ok {return r}
	} else {
		body := text_styled(text, .Body)
		baseline := b.hex.y + (b.hex.height - body.line_height) / 2 + body.ascent
		shown := row_preview(row, row.value)
		if r := draw_text(&body, list, shown, b.hex.x + CONTROL_INSET * s, baseline, theme.text,
			b.hex.width - 2 * CONTROL_INSET * s); r != .Ok {return r}
	}
	control_focused := selected && editor_focus(p) == .Control && !hex_focused
	if optional {
		box_draw(list, c.no_color, theme, control_focused && board.control == .No_Color, s)
		if board.hover_hit.target == .No_Color {
			if hover_rim_draw(list, theme, c.no_color, RADIUS_CONTROL * s, 1, s, pointer) != .None {return .Ok}
		}
		baseline := c.no_color.y + (c.no_color.height - text.line_height) / 2 + text.ascent
		if r := draw_text(text, list, "No color", c.no_color.x + CONTROL_INSET * s, baseline, theme.text,
			c.no_color.width - 2 * CONTROL_INSET * s); r != .Ok {return r}
	}
	// The value the color returns to, beside Reset.
	base_baseline := b.base.y + (b.base.height - small.line_height) / 2 + small.ascent
	label := board.card.base
	label_width := min(text_width(&small, label), b.reset.x - x - 90 * s)
	if r := draw_text(&small, list, label, x, base_baseline, theme.muted, max(1, label_width)); r != .Ok {
		return r
	}
	dot := render.Rect{x + label_width + SPACE_2 * s, b.base.y + (b.base.height - 12 * s) / 2, 12 * s, 12 * s}
	board_swatch_draw(list, theme, dot, clip, row.default_value, s)
	draw_rect(list, {rect = dot, color = theme.border, radius = RADIUS_CONTROL * s, stroke = s})
	base_text := row.default_value != "" ? row.default_value : "none"
	if r := draw_text(&small, list, base_text, dot.x + dot.width + SPACE_1 * s, base_baseline, theme.muted,
		max(1, b.reset.x - dot.x - dot.width - SPACE_2 * s)); r != .Ok {return r}
	modified := board_modified(row)
	reset_hovered := modified && board.hover_hit.target == .Reset
	if reset_hovered {
		draw_rect(list, {rect = b.reset, color = theme.hover, radius = RADIUS_CONTROL * s})
		if hover_rim_draw(list, theme, b.reset, RADIUS_CONTROL * s, 1, s, pointer) != .None {return .Ok}
	}
	if control_focused && board.control == .Reset {focus_ring_draw(list, b.reset, theme, s)}
	ink := modified ? (reset_hovered ? theme.text : theme.muted) : theme.faint
	if !modified {ink.a *= 0.5}
	icon := render.Rect{b.reset.x + SPACE_1 * s, b.reset.y, ICON_BUTTON * s, b.reset.height}
	icon_draw(list, .Undo, icon, ink, ICON_BUTTON, s)
	if r := draw_text(&small, list, "Reset", icon.x + icon.width + SPACE_1 * s, base_baseline, ink); r != .Ok {
		return r
	}
	// The colors that share this value, which change with it only when each is changed.
	same_baseline := b.same_y + small.ascent
	if b.same_count == 0 {
		if row.value == "" {return draw_text(&small, list, "No color set.", x, same_baseline, theme.faint)}
		parts := [?]string{"No other color uses ", row.value, "."}
		_, r := board_text_run(&small, list, parts[:], x, same_baseline, theme.faint)
		return r
	}
	if r := draw_text(&small, list, "Same color in", x, same_baseline, theme.faint, right - x); r != .Ok {
		return r
	}
	for place in b.chips[:b.chip_count] {
		chip_row := &p.rows[p.items[place.item].row]
		hovered := board.hover_hit.target == .Chip && board.hover_hit.item == place.item
		if hovered {draw_rect(list, {rect = place.rect, color = theme.hover, radius = RADIUS_CONTROL * s})}
		draw_rect(list, {rect = place.rect, color = theme.border, radius = RADIUS_CONTROL * s, stroke = s})
		mark := render.Rect {
			place.rect.x + SPACE_1 * s + s,
			place.rect.y + (place.rect.height - 10 * s) / 2,
			10 * s,
			10 * s,
		}
		if color, ok := swatch_color(chip_row.value); ok {
			draw_rect(list, {rect = mark, color = color, radius = pill_radius(mark)})
		}
		draw_rect(list, {rect = mark, color = theme.border, radius = pill_radius(mark), stroke = s})
		left := mark.x + mark.width + SPACE_1 * s + s
		chip_baseline := place.rect.y + (place.rect.height - small.line_height) / 2 + small.ascent
		chip_ink := hovered ? theme.text : theme.muted
		room := place.rect.x + place.rect.width - SPACE_1 * s - left
		if r := draw_fading_text(&small, list, chip_row.title, left, chip_baseline, chip_ink, room); r != .Ok {
			return r
		}
	}
	if b.same_count > b.chip_count {
		buffer: [32]u8
		parts := [?]string{"and ", strconv.write_int(buffer[:], i64(b.same_count - b.chip_count), 10), " more"}
		last := b.chips[b.chip_count - 1].rect
		baseline := last.y + last.height + SPACE_1 * s + small.ascent
		if _, r := board_text_run(&small, list, parts[:], x, baseline, theme.faint); r != .Ok {return r}
	}
	return .Ok
}

// Draws the board and its inspector in the list, and the page's scrollbar.
@(private)
color_board_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32,
) -> render.Build_Status {
	s := l.scale
	b := color_board_layout(p, l)
	if render.push_layer(list, l.list) != .None {return .Ok}
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Detail)
	buffer: [32]u8
	for side in b.sides[:b.side_count] {
		baseline := side.rect.y + side.rect.height - SPACE_6 * s
		if r := draw_text(&strong, list, side.title, side.rect.x, baseline, theme.text); r != .Ok {return r}
		count := strconv.write_int(buffer[:], i64(side.tiles), 10)
		left := side.rect.x + text_width(&strong, side.title) + SPACE_2 * s
		if r := draw_text(&small, list, count, left, baseline, theme.faint); r != .Ok {return r}
	}
	for heading in b.headings[:b.heading_count] {
		title := p.groups[p.items[heading.item].group].title
		baseline := heading.rect.y + small.ascent
		if r := draw_fading_text(&small, list, title, heading.rect.x, baseline, theme.muted,
			max(heading.rect.width, BOARD_TILE_WIDTH * 2 * s)); r != .Ok {return r}
	}
	token := b.inspector.row
	for tile in b.tiles[:b.tile_count] {
		if tile.rect.y > l.list.y + l.list.height || tile.rect.y + tile.rect.height < l.list.y {continue}
		if r := board_tile_draw(p, tile, token, list, &small, theme, l.list, s); r != .Ok {return r}
	}
	if ring := board_ring_rect(p, &b); ring.width > 0 {focus_ring_draw(list, ring, theme, s)}
	if r := board_card_draw(p, &b.inspector, list, text, theme, l.list, s, pointer); r != .Ok {return r}
	if r := board_token_draw(p, &b.inspector, list, text, theme, l.list, s, pointer); r != .Ok {return r}
	if bar, visible := editor_page_scrollbar(p, l); visible {
		scrollbar_draw(list, theme, bar, scrollbar_state(p.page_bar_hover, p.page_drag))
	}
	return .Ok
}
