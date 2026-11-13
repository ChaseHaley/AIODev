package ui

import "aio:colour"
import "aio:input"
import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:strings"
import "core:time"

// The Theme row as a filmstrip: every theme in one strip of fixed height that scrolls sideways. The
// applied theme is a wide card with a preview of the app in its own colours and a Customize button;
// every other theme is a narrow spine of its colours. The row owns STRIP_LINES page lines.

// One theme the page owner lists, in strip order. The strip copies the strings.
Theme_Card_Source :: struct {
	id, name, detail: string,
	custom:           bool,
	theme:            settings.Theme,
}

// `id`, `name` and `detail` are owned. `open` runs from 0, a spine, to 1, the wide card.
Theme_Card :: struct {
	id, name, detail: string,
	custom:           bool,
	theme:            settings.Theme,
	open:             Motion,
}

// Card indices are -1 for none. Only the applied card is wide; focus is the keyboard's card, which
// Enter applies. Scrolling is in DIPs. `anchor`, `reveal` and `wheel` are requests the next
// editor_animate turns into motion, since only it knows whether animations are on.
Theme_Strip :: struct {
	cards:                            [dynamic]Theme_Card,
	applied, focus, hover:            int,
	customize_focus, customize_hover: bool,
	scroll:                           Motion,
	// A card a press or Enter applied. The strip scrolls only as far as it must to show it whole.
	anchor:                           int,
	// A card to bring into view, and wheel travel still to scroll.
	reveal:                           int,
	wheel:                            f32,
	// Whether cards and scroll have their first place; until then nothing animates. `width` is the
	// band they were placed in, in DIPs.
	placed:                           bool,
	width:                            f32,
}

// What a rebuilt page keeps of its strip, by theme ID: each card's opening, the scroll and the
// pending requests. IDs are owned.
Theme_Strip_View :: struct {
	cards:                   [dynamic]Theme_Card_View,
	scroll:                  Motion,
	wheel, width:            f32,
	customize_focus, placed: bool,
}

Theme_Card_View :: struct {
	id:                                     string,
	open:                                   Motion,
	applied, focused, anchored, revealed:   bool,
}

@(private)
STRIP_LINES :: 3
@(private)
STRIP_HEADER :: f32(40)
@(private)
STRIP_CARD_HEIGHT :: f32(104)
@(private)
STRIP_SPINE :: f32(72)
@(private)
STRIP_WIDE :: f32(360)
@(private)
STRIP_GAP :: SPACE_2
// The Custom divider: its caption over a hairline.
@(private)
STRIP_DIVIDER :: f32(56)
// Room at each end of the strip for a focus ring.
@(private)
STRIP_PAD :: SPACE_1
// Wheel travel per page line; three lines, one notch, pass a spine and its gap.
@(private)
STRIP_WHEEL_STEP :: (STRIP_SPINE + STRIP_GAP) / 3
@(private)
STRIP_PREVIEW_WIDTH :: f32(164)
@(private)
STRIP_PREVIEW_HEIGHT :: f32(92)
@(private)
STRIP_BUTTON_WIDTH :: f32(88)
@(private)
STRIP_KEYS_HINT :: "← → choose · Enter applies · Tab reaches Customize"

// Cards open and close, and the strip scrolls, together over one duration and curve, so a card the
// strip keeps in place stays exactly still while its neighbours change width. A card changing size
// takes the pane resize time (Visual language, Motion) rather than the shorter reorder one.
THEME_STRIP_DURATION :: 160 * time.Millisecond

@(private)
theme_strip_destroy :: proc(strip: ^Theme_Strip) {
	for card in strip.cards {
		delete(card.id)
		delete(card.name)
		delete(card.detail)
	}
	delete(strip.cards)
	strip^ = {}
}

// Lists the page's themes on the row `key` names, which then draws as the strip and is found by any
// theme's name. `applied` is the active theme's ID.
@(require_results)
editor_theme_strip_load :: proc(
	p: ^Editor,
	key: string,
	sources: []Theme_Card_Source,
	applied: string,
) -> runtime.Allocator_Error {
	theme_strip_destroy(&p.strip)
	strip := &p.strip
	strip.applied, strip.hover, strip.anchor, strip.reveal = -1, -1, -1, -1
	names := make([]string, len(sources), context.temp_allocator)
	for source, i in sources {
		append(&strip.cards, Theme_Card{custom = source.custom, theme = source.theme}) or_return
		card := &strip.cards[len(strip.cards) - 1]
		card.id = strings.clone(source.id) or_return
		card.name = strings.clone(source.name) or_return
		card.detail = strings.clone(source.detail) or_return
		if source.id == applied {strip.applied = i}
		names[i] = source.name
	}
	strip.focus = max(strip.applied, 0)
	for &row in p.rows {
		if row.key != key {continue}
		detail := strings.join(names, " ") or_return
		delete(row.detail)
		row.kind, row.detail = .Theme_Strip, detail
	}
	return nil
}

// The page lines a row owns: the strip's three, one for anything else.
@(private)
row_lines :: proc(row: Editor_Row) -> int {
	return row.kind == .Theme_Strip ? STRIP_LINES : 1
}

// How many page lines the row at line `index` owns from there.
@(private)
editor_item_span :: proc(p: ^Editor, index: int) -> int {
	if index < 0 || index >= len(p.items) || p.items[index].row < 0 {return 1}
	return row_lines(p.rows[p.items[index].row]) - p.items[index].part
}

// Fills `view` from the strip; on failure it holds what was copied, for theme_strip_view_destroy.
@(require_results)
theme_strip_view_take :: proc(view: ^Theme_Strip_View, strip: ^Theme_Strip) -> runtime.Allocator_Error {
	view.scroll, view.wheel, view.width = strip.scroll, strip.wheel, strip.width
	view.customize_focus, view.placed = strip.customize_focus, strip.placed
	for card, i in strip.cards {
		entry := Theme_Card_View {
			open     = card.open,
			applied  = i == strip.applied,
			focused  = i == strip.focus,
			anchored = i == strip.anchor,
			revealed = i == strip.reveal,
		}
		entry.id = strings.clone(card.id) or_return
		if _, append_error := append(&view.cards, entry); append_error != nil {
			delete(entry.id)
			return append_error
		}
	}
	return nil
}

theme_strip_view_destroy :: proc(view: ^Theme_Strip_View) {
	for card in view.cards {delete(card.id)}
	delete(view.cards)
	view^ = {}
}

// Gives the rebuilt page's cards the openings and scroll its strip had, matched by theme ID, so a
// change in progress goes on moving. A theme applied elsewhere, such as from the palette, opens where
// it is and the strip eases to it; a card new to the page starts as a spine.
@(private)
theme_strip_restore :: proc(strip: ^Theme_Strip, view: ^Theme_Strip_View) {
	if !view.placed {return}
	strip.placed = true
	strip.scroll, strip.wheel, strip.width = view.scroll, view.wheel, view.width
	strip.customize_focus = view.customize_focus
	was_applied := false
	for &card, i in strip.cards {
		for old in view.cards {
			if old.id != card.id {continue}
			card.open = old.open
			if old.focused {strip.focus = i}
			if old.anchored {strip.anchor = i}
			if old.revealed {strip.reveal = i}
			was_applied ||= old.applied && i == strip.applied
		}
	}
	if !was_applied && strip.anchor < 0 && strip.applied >= 0 {strip.reveal = strip.applied}
}

// The row's whole block: its first line's rect, three lines tall.
editor_strip_rect :: proc(p: ^Editor, l: Editor_Layout, index: int) -> render.Rect {
	r := editor_row_parts(p, l, index).row
	r.height = STRIP_LINES * l.row_height
	return r
}

// The band the cards scroll in, below the row's title.
@(private)
strip_view :: proc(block: render.Rect, s: f32) -> render.Rect {
	left := block.x + (ITEM_INSET - STRIP_PAD) * s
	width := max(0, block.x + block.width - SPACE_2 * s - left)
	return {left, block.y + STRIP_HEADER * s, width, STRIP_CARD_HEIGHT * s}
}

// How much of the strip the band shows, in DIPs; zero before the page has a layout.
@(private)
strip_view_width :: proc(l: Editor_Layout) -> f32 {
	if l.scale <= 0 {return 0}
	return max(0, strip_view({0, 0, l.list.width, 0}, l.scale).width / l.scale - 2 * STRIP_PAD)
}

// A card's width now, or once its motion lands.
@(private)
strip_card_width :: proc(card: Theme_Card, final: bool) -> f32 {
	open := final ? card.open.target : card.open.value
	return STRIP_SPINE + (STRIP_WIDE - STRIP_SPINE) * open
}

// The Custom divider stands before the first custom theme that follows a theme file.
@(private)
strip_divider_before :: proc(strip: ^Theme_Strip, index: int) -> bool {
	return index > 0 && strip.cards[index].custom && !strip.cards[index - 1].custom
}

// Where card `index` starts along the strip, in DIPs.
@(private)
strip_left :: proc(strip: ^Theme_Strip, index: int, final: bool) -> f32 {
	x: f32
	for i in 0 ..< index {x += strip_card_width(strip.cards[i], final) + STRIP_GAP}
	for i in 1 ..= min(index, len(strip.cards) - 1) {
		if strip_divider_before(strip, i) {x += STRIP_DIVIDER + STRIP_GAP}
	}
	return x
}

@(private)
strip_max_scroll :: proc(strip: ^Theme_Strip, view_width: f32, final: bool) -> f32 {
	last := len(strip.cards) - 1
	if last < 0 {return 0}
	return max(0, strip_left(strip, last, final) + strip_card_width(strip.cards[last], final) - view_width)
}

// The scroll nearest `scroll` that shows card `index` once it lands, with `margin` beside it when
// there is room.
@(private)
strip_into_view :: proc(strip: ^Theme_Strip, index: int, scroll, view_width, margin: f32) -> f32 {
	left := strip_left(strip, index, true)
	right := left + strip_card_width(strip.cards[index], true)
	room := min(margin, max(0, (view_width - (right - left)) / 2))
	if left - room < scroll {return left - room}
	if right + room > scroll + view_width {return right + room - view_width}
	return scroll
}

@(private)
strip_card_rect :: proc(strip: ^Theme_Strip, view: render.Rect, s: f32, index: int) -> render.Rect {
	x := view.x + (STRIP_PAD + strip_left(strip, index, false) - strip.scroll.value) * s
	return {x, view.y, strip_card_width(strip.cards[index], false) * s, view.height}
}

@(private)
strip_card_at :: proc(strip: ^Theme_Strip, view: render.Rect, s, x, y: f32) -> int {
	if !render.rect_contains(view, x, y) {return -1}
	for _, i in strip.cards {
		if render.rect_contains(strip_card_rect(strip, view, s, i), x, y) {return i}
	}
	return -1
}

// Customize sits at the wide card's lower right; it takes a press only on the applied card once that
// card is open enough to show it.
@(private)
strip_customize_rect :: proc(card: render.Rect, s: f32) -> render.Rect {
	return {
		card.x + (STRIP_WIDE - SPACE_2 - STRIP_BUTTON_WIDTH) * s,
		card.y + card.height - (SPACE_2 + HEIGHT_COMPACT) * s,
		STRIP_BUTTON_WIDTH * s,
		HEIGHT_COMPACT * s,
	}
}

@(private)
strip_customize_at :: proc(strip: ^Theme_Strip, view: render.Rect, s, x, y: f32) -> bool {
	if strip.applied < 0 || strip.cards[strip.applied].open.value < 0.5 {return false}
	card := strip_card_rect(strip, view, s, strip.applied)
	return render.rect_contains(view, x, y) && render.rect_contains(card, x, y) &&
		render.rect_contains(strip_customize_rect(card, s), x, y)
}

// The strip's band when the page line under `y` belongs to the strip row.
@(private)
strip_view_at :: proc(p: ^Editor, l: Editor_Layout, y: f32) -> (view: render.Rect, ok: bool) {
	if len(p.strip.cards) == 0 {return}
	index := p.scroll + int((y - l.list.y) / l.row_height)
	if y < l.list.y || index >= len(p.items) || p.items[index].row < 0 {return}
	if p.rows[p.items[index].row].kind != .Theme_Strip {return}
	return strip_view(editor_strip_rect(p, l, index - p.items[index].part), l.scale), true
}

// Applies card `index`, as choosing it in a list does: the owner saves the row's value.
@(private)
strip_apply :: proc(p: ^Editor, index: int) -> Editor_Outcome {
	strip := &p.strip
	strip.focus, strip.customize_focus = index, false
	if index == strip.applied {return .Changed}
	strip.anchor = index
	field_set(&p.value, strip.cards[index].id)
	return .Save
}

// Moves the keyboard's card and brings it into view.
@(private)
strip_focus_set :: proc(strip: ^Theme_Strip, index: int) {
	strip.focus = clamp(index, 0, len(strip.cards) - 1)
	strip.customize_focus = false
	strip.reveal = strip.focus
}

// Tab reaching the strip lands on the applied card, as on a checked radio button; Shift+Tab lands
// on Customize first.
@(private)
editor_strip_enter :: proc(p: ^Editor, back: bool) {
	strip := &p.strip
	if len(strip.cards) == 0 {return}
	strip_focus_set(strip, max(strip.applied, 0))
	strip.customize_focus = back && strip.applied >= 0
}

// Tab between the cards and Customize; true when it stayed inside the strip.
@(private)
editor_strip_tab :: proc(p: ^Editor, row: ^Editor_Row, focus: Editor_Focus, back: bool) -> bool {
	strip := &p.strip
	if row == nil || row.kind != .Theme_Strip || focus != .Control || strip.applied < 0 {return false}
	if back == strip.customize_focus {
		strip.customize_focus = !back
		if back {strip.reveal = strip.focus} else {strip.reveal = strip.applied}
		return true
	}
	return false
}

// Arrows, Home and End move between cards; Enter or Space applies the card or presses Customize.
@(private)
editor_strip_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	strip := &p.strip
	if row == nil || row.kind != .Theme_Strip || len(strip.cards) == 0 || editor_focus(p) != .Control {
		return .None, false
	}
	if e.modifiers & {.Control, .Alt, .Super} != {} {return .None, false}
	#partial switch e.key {
	case .Arrow_Left:
		strip_focus_set(strip, strip.focus - 1)
	case .Arrow_Right:
		strip_focus_set(strip, strip.focus + 1)
	case .Home:
		strip_focus_set(strip, 0)
	case .End:
		strip_focus_set(strip, len(strip.cards) - 1)
	case .Enter, .Numpad_Enter, .Space:
		if strip.customize_focus {return .Theme_Customize, true}
		return strip_apply(p, strip.focus), true
	case:
		return .None, false
	}
	return .Changed, true
}

@(private)
editor_strip_press :: proc(p: ^Editor, l: Editor_Layout, index: int, x, y: f32) -> Editor_Outcome {
	strip := &p.strip
	view := strip_view(editor_strip_rect(p, l, index), l.scale)
	if strip_customize_at(strip, view, l.scale, x, y) {
		strip.focus, strip.customize_focus = strip.applied, true
		return .Theme_Customize
	}
	if card := strip_card_at(strip, view, l.scale, x, y); card >= 0 {return strip_apply(p, card)}
	return .Changed
}

// Tracks the card and Customize under the pointer; true when that changed. `index` is the strip
// row's first line, or -1 when the pointer is elsewhere.
@(private)
editor_strip_hover :: proc(p: ^Editor, l: Editor_Layout, index: int, x, y: f32) -> bool {
	strip := &p.strip
	card, customize := -1, false
	if index >= 0 && len(strip.cards) > 0 {
		view := strip_view(editor_strip_rect(p, l, index), l.scale)
		customize = strip_customize_at(strip, view, l.scale, x, y)
		if !customize {card = strip_card_at(strip, view, l.scale, x, y)}
	}
	if card == strip.hover && customize == strip.customize_hover {return false}
	strip.hover, strip.customize_hover = card, customize
	return true
}

@(private)
editor_strip_hover_clear :: proc(p: ^Editor) -> bool {
	return editor_strip_hover(p, {}, -1, 0, 0)
}

@(private)
editor_strip_pointer :: proc(p: ^Editor, l: Editor_Layout, index: int, x, y: f32) -> bool {
	strip := &p.strip
	view := strip_view(editor_strip_rect(p, l, index), l.scale)
	if strip_customize_at(strip, view, l.scale, x, y) {return true}
	card := strip_card_at(strip, view, l.scale, x, y)
	return card >= 0 && card != strip.applied
}

// Wheel over a strip that can still move that way scrolls it sideways; at either end the page
// scrolls instead.
@(private)
editor_strip_wheel :: proc(p: ^Editor, l: Editor_Layout, x, y: f32, rows: int) -> bool {
	strip := &p.strip
	view, ok := strip_view_at(p, l, y)
	if !ok || !strip.placed || !render.rect_contains(view, x, y) {return false}
	limit := strip_max_scroll(strip, strip_view_width(l), true)
	target := strip.scroll.target + strip.wheel
	delta := -f32(rows) * STRIP_WHEEL_STEP
	if (delta < 0 && target <= 0) || (delta > 0 && target >= limit) {return false}
	strip.wheel = clamp(target + delta, 0, limit) - strip.scroll.target
	return true
}

// Places the strip the first time the page has a layout, and again whenever its band changes width,
// keeping the applied card in view; neither moves, as window resizes are not animated.
@(private)
editor_strip_fit :: proc(p: ^Editor, l: Editor_Layout) {
	strip := &p.strip
	width := strip_view_width(l)
	if len(strip.cards) == 0 || width <= 0 || (strip.placed && width == strip.width) {return}
	start: f32
	if strip.placed {
		start = strip.scroll.target
	} else {
		for &card, i in strip.cards {
			open: f32 = i == strip.applied ? 1 : 0
			card.open = {value = open, target = open}
		}
		strip.anchor, strip.reveal = -1, -1
	}
	if strip.applied >= 0 {start = strip_into_view(strip, strip.applied, start, width, STRIP_SPINE / 2)}
	start = clamp(start, 0, strip_max_scroll(strip, width, true))
	strip.scroll = {value = start, target = start}
	strip.wheel = 0
	strip.placed, strip.width = true, width
}

// Turns the strip's requests into motion and advances it; true when it must draw again. The applied
// card opens by the width the previous one closes, over the same curve, so the strip keeps its length
// and cards outside the pair keep their places. The strip scrolls a card the user applied only as far
// as it must to show it whole: a card before the closing one grows from its left edge and a card
// after it from its right edge, so it stays under the pointer that chose it. A revealed card eases
// into view.
@(private)
editor_strip_animate :: proc(p: ^Editor, enabled: bool, frame: Frame_Time) -> bool {
	strip := &p.strip
	if len(strip.cards) == 0 {return false}
	width := strip_view_width(p.fit_layout)
	if !strip.placed || width <= 0 {
		strip.anchor, strip.reveal, strip.wheel = -1, -1, 0
		return false
	}
	// A change that lands at once, with animations off, still needs one more frame.
	changed := strip.anchor >= 0 || strip.reveal >= 0 || strip.wheel != 0
	for &card, i in strip.cards {
		open: f32 = i == strip.applied ? 1 : 0
		changed ||= card.open.target != open
		motion_target(&card.open, open, THEME_STRIP_DURATION, .Decelerate, enabled)
	}
	target := strip.scroll.target
	if strip.anchor >= 0 && strip.anchor == strip.applied {
		target = strip_into_view(strip, strip.anchor, target, width, 0)
	}
	if strip.reveal >= 0 {target = strip_into_view(strip, strip.reveal, target, width, STRIP_SPINE / 2)}
	target = clamp(target + strip.wheel, 0, strip_max_scroll(strip, width, true))
	strip.anchor, strip.reveal, strip.wheel = -1, -1, 0
	motion_target(&strip.scroll, target, THEME_STRIP_DURATION, .Decelerate, enabled)
	for &card in strip.cards {changed = motion_update(&card.open, frame) || changed}
	return motion_update(&strip.scroll, frame) || changed
}

// Whether a card is opening or closing, the strip scrolling, or a request waits for editor_animate.
editor_strip_animating :: proc(p: ^Editor) -> bool {
	strip := &p.strip
	if strip.anchor >= 0 || strip.reveal >= 0 || strip.wheel != 0 {return strip.placed}
	for card in strip.cards {if motion_active(card.open) {return true}}
	return motion_active(strip.scroll)
}

// Card `card` as drawn in the strip row whose first line is `index`, for the verification state.
editor_strip_card_rect :: proc(p: ^Editor, l: Editor_Layout, index, card: int) -> render.Rect {
	view := strip_view(editor_strip_rect(p, l, index), l.scale)
	return strip_card_rect(&p.strip, view, l.scale, card)
}

editor_strip_customize_rect :: proc(p: ^Editor, l: Editor_Layout, index: int) -> render.Rect {
	if p.strip.applied < 0 {return {}}
	return strip_customize_rect(editor_strip_card_rect(p, l, index, p.strip.applied), l.scale)
}

// A card's ID, or "" for none.
editor_strip_card_id :: proc(p: ^Editor, card: int) -> string {
	return card >= 0 && card < len(p.strip.cards) ? p.strip.cards[card].id : ""
}

@(private)
strip_color :: proc(t: settings.Theme, token: settings.Theme_Token) -> render.Color {
	value := t.colors[token]
	return colour.rgba(value.rgb, f32(value.a) / 255)
}

@(private)
strip_fade :: proc(c: render.Color, opacity: f32) -> render.Color {
	faded := c
	faded.a *= opacity
	return faded
}

@(private)
strip_intersect :: proc(a, b: render.Rect) -> render.Rect {
	left, top := max(a.x, b.x), max(a.y, b.y)
	right, bottom := min(a.x + a.width, b.x + b.width), min(a.y + a.height, b.y + b.height)
	return {left, top, max(0, right - left), max(0, bottom - top)}
}

@(private)
strip_smooth :: proc(from, to, x: f32) -> f32 {
	t := clamp((x - from) / (to - from), 0, 1)
	return t * t * (3 - 2 * t)
}

// A rect of the preview at DIP offsets inside `area`.
@(private)
strip_bar :: proc(
	list: ^render.Draw_List,
	area: render.Rect,
	s, x, y, width, height: f32,
	color: render.Color,
) {
	draw_rect(list, {rect = {area.x + x * s, area.y + y * s, width * s, height * s}, color = color})
}

// The app in miniature, in the theme's own colours: the tab bar, a terminal pane with a few lines of
// shell output and a settings pane with a switch and a button. Text is drawn as bars.
@(private)
strip_preview_draw :: proc(
	list: ^render.Draw_List,
	t: settings.Theme,
	m: render.Rect,
	border: render.Color,
	s: f32,
) {
	c :: strip_color
	radius := RADIUS_CONTROL * s
	draw_rect(list, {rect = m, color = c(t, .Window), radius = radius})
	bar_top := render.Rect{m.x, m.y, m.width, 14 * s}
	draw_rect(list, {rect = bar_top, color = c(t, .Tab_Bar), radius = radius})
	strip_bar(list, m, s, 0, 7, STRIP_PREVIEW_WIDTH, 7, c(t, .Tab_Bar))
	chip := render.Rect{m.x + 5 * s, m.y + 4 * s, 10 * s, 6 * s}
	draw_rect(list, {rect = chip, color = c(t, .Pane), radius = pill_radius(chip)})
	strip_bar(list, m, s, 20, 3, 30, 11, c(t, .Tab_Active))
	strip_bar(list, m, s, 22, 12, 26, 1.5, c(t, .Tab_Indicator))
	strip_bar(list, m, s, 25, 6.5, 18, 2, c(t, .Tab_Active_Text))
	strip_bar(list, m, s, 56, 6.5, 20, 2, c(t, .Tab_Text))
	terminal := render.Rect{m.x + 3 * s, m.y + 17 * s, 92 * s, 72 * s}
	draw_rect(list, {rect = terminal, color = c(t, .Background), radius = radius})
	draw_rect(list, {rect = terminal, color = c(t, .Pane_Focus), radius = radius, stroke = s})
	Run :: struct {
		token: settings.Theme_Token,
		width: f32,
	}
	@(static, rodata)
	lines := [?][4]Run {
		{{.Palette_2, 6}, {.Palette_4, 22}, {.Palette_5, 12}, {.Foreground, 18}},
		{{.Palette_1, 6}, {.Foreground, 36}, {}, {}},
		{{.Palette_3, 6}, {.Foreground, 12}, {.Selection_Background, 22}, {.Foreground, 8}},
		{{.Palette_1, 10}, {.Palette_8, 26}, {.Palette_2, 14}, {}},
		{{.Palette_2, 6}, {.Palette_4, 22}, {.Cursor, 4}, {}},
	}
	for line, i in lines {
		x, y := f32(7), 23 + f32(i) * 9
		for run in line {
			if run.width == 0 {break}
			// The selection is a highlight behind text; the cursor a block the height of a line.
			height: f32 = run.token == .Selection_Background || run.token == .Cursor ? 6 : 2.5
			top := y - (height - 2.5) / 2
			strip_bar(list, m, s, x, top, run.width, height, c(t, run.token))
			if run.token == .Selection_Background {strip_bar(list, m, s, x + 3, y, 14, 2.5, c(t, .Foreground))}
			x += run.width + 2
		}
	}
	side := render.Rect{m.x + 98 * s, m.y + 17 * s, 63 * s, 72 * s}
	draw_rect(list, {rect = side, color = c(t, .Pane), radius = radius})
	draw_rect(list, {rect = side, color = c(t, .Pane_Border), radius = radius, stroke = s})
	strip_bar(list, m, s, 104, 23, 28, 3, c(t, .Text))
	strip_bar(list, m, s, 104, 31, 40, 2, c(t, .Faint))
	strip_bar(list, m, s, 104, 42, 22, 2.5, c(t, .Muted))
	toggle := render.Rect{m.x + 139 * s, m.y + 39.5 * s, 16 * s, 8 * s}
	draw_rect(list, {rect = toggle, color = c(t, .Accent), radius = pill_radius(toggle)})
	knob := render.Rect{toggle.x + 9.5 * s, toggle.y + 1.5 * s, 5 * s, 5 * s}
	draw_rect(list, {rect = knob, color = c(t, .Accent_Text), radius = pill_radius(knob)})
	selected := render.Rect{m.x + 101 * s, m.y + 51 * s, 57 * s, 9 * s}
	draw_rect(list, {rect = selected, color = c(t, .Selection), radius = radius})
	strip_bar(list, m, s, 104, 54.5, 26, 2.5, c(t, .Text))
	button := render.Rect{m.x + 104 * s, m.y + 68 * s, 24 * s, 10 * s}
	draw_rect(list, {rect = button, color = c(t, .Accent), radius = radius})
	strip_bar(list, m, s, 108, 72, 16, 2, c(t, .Accent_Text))
	draw_rect(list, {rect = m, color = border, radius = radius, stroke = s})
}

// A spine: the theme's terminal background with its text, accent and dim colours as bars and eight
// ANSI colours as dots, over its name on up to two lines.
@(private)
strip_spine_draw :: proc(
	list: ^render.Draw_List,
	small: ^Text,
	card: Theme_Card,
	r: render.Rect,
	theme: Theme,
	name_color: render.Color,
	s: f32,
) -> render.Build_Status {
	t := card.theme
	inner := STRIP_SPINE - 2 * SPACE_1
	swatch := render.Rect{r.x + SPACE_1 * s, r.y + SPACE_1 * s, inner * s, 60 * s}
	radius := RADIUS_CONTROL * s
	draw_rect(list, {rect = swatch, color = strip_color(t, .Background), radius = radius})
	edge := card.custom ? theme.accent : theme.border
	draw_rect(list, {rect = swatch, color = edge, radius = radius, stroke = s})
	bars := [3]struct {
		token: settings.Theme_Token,
		share: f32,
	}{{.Foreground, 0.7}, {.Accent, 0.45}, {.Palette_8, 0.58}}
	for bar, i in bars {
		strip_bar(list, swatch, s, 6, 8 + f32(i) * 7, (inner - 12) * bar.share, 3, strip_color(t, bar.token))
	}
	@(static, rodata)
	dots := [8]settings.Theme_Token {
		.Palette_1, .Palette_2, .Palette_3, .Palette_4, .Palette_5, .Palette_6, .Palette_9, .Palette_11,
	}
	row_width := 4 * 8 + 3 * 3
	for token, i in dots {
		x := (inner - f32(row_width)) / 2 + f32(i % 4) * 11
		y := 60 - 6 - 6 - f32(1 - i / 4) * 9
		dot := render.Rect{swatch.x + x * s, swatch.y + y * s, 8 * s, 6 * s}
		draw_rect(list, {rect = dot, color = strip_color(t, token), radius = pill_radius(dot)})
	}
	first, rest := strip_name_split(small, card.name, inner * s)
	baseline := swatch.y + swatch.height + SPACE_1 * s + small.ascent
	for line, i in ([2]string{first, rest}) {
		if line == "" {continue}
		width := min(text_width(small, line), inner * s)
		y := baseline + f32(i) * small.line_height
		if result := draw_text(small, list, line, r.x + (r.width - width) / 2, y, name_color, inner * s);
		   result != .Ok {return result}
	}
	return .Ok
}

// A name on one line when it fits, else broken at the last space that lets the first line fit.
@(private)
strip_name_split :: proc(t: ^Text, name: string, width: f32) -> (first, rest: string) {
	if text_width(t, name) <= width {return name, ""}
	cut := -1
	for r, offset in name {
		if r == ' ' && text_width(t, name[:offset]) <= width {cut = offset}
	}
	if cut <= 0 {return name, ""}
	return name[:cut], name[cut + 1:]
}

// The wide card's own content, laid out for its full width: the preview, the name and kind, the
// sixteen ANSI colours, the applied mark and Customize.
@(private)
strip_wide_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	card: Theme_Card,
	r: render.Rect,
	applied, customize_focused: bool,
	theme: Theme,
	pointer: [2]f32,
	s: f32,
) -> render.Build_Status {
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Detail)
	preview := render.Rect{r.x + 6 * s, r.y + 6 * s, STRIP_PREVIEW_WIDTH * s, STRIP_PREVIEW_HEIGHT * s}
	strip_preview_draw(list, card.theme, preview, theme.border, s)
	x := preview.x + preview.width + 10 * s
	width := r.x + (STRIP_WIDE - SPACE_2) * s - x
	top := r.y + SPACE_2 * s
	if result := draw_text(&strong, list, card.name, x, top + strong.ascent, theme.text, width);
	   result != .Ok {return result}
	top += strong.line_height + 2 * s
	if result := draw_text(&small, list, card.detail, x, top + small.ascent, theme.muted, width);
	   result != .Ok {return result}
	top += small.line_height + 6 * s
	for i in 0 ..< 16 {
		token := settings.Theme_Token(int(settings.Theme_Token.Palette_0) + i)
		cell := render.Rect{x + f32(i % 8) * 18 * s, top + f32(i / 8) * 10 * s, 16 * s, 8 * s}
		draw_rect(list, {rect = cell, color = strip_color(card.theme, token), radius = pill_radius(cell)})
	}
	button := strip_customize_rect(r, s)
	if applied {
		mark := render.Rect{x, button.y + (button.height - ICON_INDICATOR * s) / 2, ICON_INDICATOR * s,
			ICON_INDICATOR * s}
		icon_draw(list, .Check, mark, theme.accent, ICON_INDICATOR, s)
		baseline := button.y + (button.height - small.line_height) / 2 + small.ascent
		if result := draw_text(&small, list, "Applied", mark.x + mark.width + SPACE_1 * s, baseline,
			theme.accent); result != .Ok {return result}
	}
	return text_button_draw(list, text, theme, button, "Customize", customize_focused, s, pointer)
}

// The strip row: its title and description over the band of cards. Every card is drawn at its
// current width; a card between spine and wide card fades its spine out and its wide content in, the
// wide content clipped to the card so it is uncovered as the card opens, never squeezed.
@(private)
editor_strip_draw :: proc(
	p: ^Editor,
	l: Editor_Layout,
	index: int,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	focused: bool,
	pointer: [2]f32,
) -> render.Build_Status {
	s := l.scale
	strip := &p.strip
	row := &p.rows[p.items[index].row]
	block := editor_strip_rect(p, l, index)
	selected := index == p.selected
	keyboard := focused && selected && editor_focus(p) == .Control
	if selected {draw_rect(list, {rect = block, color = theme.selection, radius = RADIUS_CONTROL * s})}
	small := text_styled(text, .Detail)
	header := render.Rect{block.x, block.y, block.width, STRIP_HEADER * s}
	inset := ITEM_INSET * s
	hint_width: f32
	if keyboard {hint_width = text_width(&small, STRIP_KEYS_HINT) + SPACE_3 * s}
	title_width := max(1, header.width - 2 * inset - hint_width)
	baseline, detail_baseline := stacked_baselines(header, text, &small, s)
	if result := draw_text(text, list, row.title, header.x + inset, baseline, theme.text, title_width);
	   result != .Ok {return result}
	if result := draw_text(&small, list, row.description, header.x + inset, detail_baseline, theme.muted,
		title_width); result != .Ok {return result}
	if keyboard && hint_width < header.width / 2 {
		hint_x := header.x + header.width - SPACE_3 * s - text_width(&small, STRIP_KEYS_HINT)
		if result := draw_text(&small, list, STRIP_KEYS_HINT, hint_x, detail_baseline, theme.faint);
		   result != .Ok {return result}
	}
	if len(strip.cards) == 0 {return .Ok}
	view := strip_view(block, s)
	// Focus rings reach SPACE_1 above the cards and the scroll thumb sits below them.
	band := render.Rect{view.x, view.y - SPACE_1 * s, view.width, view.height + (SPACE_1 + SPACE_2) * s}
	clip := strip_intersect(band, l.list)
	scope, clipped := clip_scope_open(list, clip)
	if !clipped {return .Ok}
	defer clip_scope_close(list, scope)
	x := view.x + (STRIP_PAD - strip.scroll.value) * s
	for &card, i in strip.cards {
		if strip_divider_before(strip, i) {
			divider := render.Rect{x, view.y, STRIP_DIVIDER * s, view.height}
			label := "Custom"
			label_x := divider.x + (divider.width - text_width(&small, label)) / 2
			if result := draw_text(&small, list, label, label_x, divider.y + small.ascent, theme.muted);
			   result != .Ok {return result}
			line_top := divider.y + small.line_height + SPACE_1 * s
			line := render.Rect{divider.x + divider.width / 2, line_top, s, divider.y + divider.height - line_top}
			draw_rect(list, {rect = line, color = theme.border})
			x += (STRIP_DIVIDER + STRIP_GAP) * s
		}
		r := render.Rect{x, view.y, strip_card_width(card, false) * s, view.height}
		x += r.width + STRIP_GAP * s
		if r.x + r.width < clip.x || r.x > clip.x + clip.width {continue}
		open := card.open.value
		radius := RADIUS_OVERLAY * s
		if open > 0 {
			draw_rect(list, {rect = r, color = strip_fade(theme.surface, open), radius = radius})
			draw_rect(list, {rect = r, color = strip_fade(theme.border, open), radius = radius, stroke = s})
		}
		hovered := i == strip.hover && i != strip.applied
		if hovered {draw_rect(list, {rect = r, color = strip_fade(theme.hover, 1 - open), radius = radius})}
		ring := keyboard && i == strip.focus && !strip.customize_focus
		if spine := 1 - strip_smooth(0, 0.6, open); spine > 0 {
			mark := render.draw_mark(list)
			name_color := ring || hovered ? theme.text : theme.muted
			if result := strip_spine_draw(list, &small, card, r, theme, name_color, s); result != .Ok {
				return result
			}
			fade_draw(list, mark, {opacity = spine})
		}
		if wide := strip_smooth(0.4, 1, open); wide > 0 {
			inner, inner_shown := clip_scope_open(list, strip_intersect(r, clip))
			if !inner_shown {return .Ok}
			mark := render.draw_mark(list)
			customize := keyboard && i == strip.applied && strip.customize_focus
			result := strip_wide_draw(list, text, card, r, i == strip.applied, customize, theme, pointer, s)
			fade_draw(list, mark, {opacity = wide})
			clip_scope_close(list, inner)
			if result != .Ok {return result}
		}
		if ring {focus_ring_draw(list, r, theme, s)}
	}
	width := strip_view_width(l)
	extent := strip_max_scroll(strip, 0, false)
	if extent > width && extent > 0 {
		track := view.width - 2 * STRIP_PAD * s
		thumb := render.Rect {
			view.x + STRIP_PAD * s + track * strip.scroll.value / extent,
			view.y + view.height + SPACE_1 * s,
			max(SPACE_6 * s, track * width / extent),
			3 * s,
		}
		draw_rect(list, {rect = thumb, color = theme.scrollbar, radius = pill_radius(thumb)})
	}
	return .Ok
}
