package ui

import "aio:colour"
import "aio:markdown"
import "aio:render"
import "aio:syntax"
import "core:fmt"
import "core:math"
import "core:strings"

// The cards a note takes in the diff stream: the saved note card, and the editor card that replaces it
// while the note is written or edited (D-100). Both sit under the last line of their lines, starting at the
// code column. The geometry here is shared by measuring, hit testing and painting, so a card is painted at
// the height it was measured and a press lands on the control drawn there.

// The room a card keeps above it, for the notch that points at its lines, and below it.
@(private)
CHANGES_CARD_GAP_ABOVE :: f32(6)
@(private)
CHANGES_CARD_GAP_BELOW :: f32(8)
@(private = "file")
CHANGES_CARD_NOTCH :: f32(5)
// How far the notch's point is from the card's left edge.
@(private = "file")
CHANGES_CARD_NOTCH_AT :: f32(14)
// A card narrower than this moves left to the band's edge instead of starting at the code column.
@(private = "file")
CHANGES_CARD_MIN_WIDTH :: f32(200)
// Below this diff width a note card shows Edit and Remove all the time, for there is no hovering to a
// place the pointer cannot reach, and its text and header leave room for them.
@(private = "file")
CHANGES_CARD_NARROW :: f32(360)
@(private = "file")
CHANGES_CARD_ACTION :: f32(22)
@(private = "file")
CHANGES_CARD_ACTION_GAP :: f32(1)
@(private = "file")
CHANGES_CARD_ACTION_INSET :: f32(3)
// The tag and the excerpt chip on a card's first line.
@(private = "file")
CHANGES_CARD_TAG :: f32(18)
@(private = "file")
CHANGES_TAG_TINT :: f32(0.14)
@(private = "file")
CHANGES_TAG_PAD :: f32(6)
// How many characters of the selected text a card's excerpt and an editor's header show.
@(private = "file")
CHANGES_EXCERPT_NOTE :: 46
@(private = "file")
CHANGES_EXCERPT_EDITOR :: 40
// The editor's text area: from this many lines of text tall, and no taller than the other, past which it
// scrolls.
@(private = "file")
CHANGES_AREA_MIN_LINES :: 3
@(private = "file")
CHANGES_AREA_MAX_LINES :: 12
@(private = "file")
CHANGES_SUGGEST_WIDTH :: f32(124)
@(private = "file")
CHANGES_SAVE_WIDTH :: f32(80)
@(private = "file")
CHANGES_CANCEL_WIDTH :: f32(72)

// What the editor's header says about the lines: their numbers on the side they are counted on.
Changes_Span :: struct {
	first, last: int,
	old:         bool,
}

// A card's left edge from the diff area's, and its width.
@(private)
Card_Span :: struct {
	x, width: f32,
}

// Where a card in `file` sits: from the code column of the file's lines to the band's right edge less a
// margin, or from a fixed inset for a note whose lines are not in the diff (`file` < 0). A pane too narrow
// to leave `CHANGES_CARD_MIN_WIDTH` for the card starts it at the band's edge.
@(private)
card_span :: proc(rows: ^Changes_Rows, view: ^Changes_View, file: int) -> Card_Span {
	s := rows.scale
	pad := math.round(SPACE_2 * s)
	band := max(0, rows.width - 2 * pad)
	right := math.round(SPACE_3 * s)
	x := math.round(2 * SPACE_2 * s)
	if file >= 0 && file < len(view.files) {
		number := code_number_width(&view.files[file], rows.digit)
		x = pad + code_column({0, 0, band, 0}, number, rows.digit, s, !rows.pairs.side_by_side).text_x
		x = math.round(x)
		if rows.width - x - right < CHANGES_CARD_MIN_WIDTH * s {x = pad}
	}
	return {x, max(0, rows.width - x - right)}
}

// The padding inside a card.
@(private = "file")
card_pad :: proc(s: f32) -> f32 {return math.round(SPACE_2 * s)}

// The words a tag carries: a label's name, or "Delete".
@(private = "file")
tag_text :: proc(c: Changes_Comment_View) -> string {
	return c.kind == .Label ? c.label_name : "Delete"
}

// The width of a tag in `detail` text: its padding, a deletion's icon, the words, and for an editor's tag the
// × that takes the tag off.
@(private = "file")
tag_width :: proc(detail: ^Text, c: Changes_Comment_View, removable: bool, s: f32) -> f32 {
	width := 2 * CHANGES_TAG_PAD * s + text_width(detail, tag_text(c))
	if c.kind == .Delete {width += (ICON_INDICATOR + SPACE_1) * s}
	if removable {width += (ICON_INDICATOR + SPACE_1) * s}
	return math.round(width)
}

// The new-side lines of flat lines `first` through `last` of `file`, which a suggestion replaces, in
// temporary memory.
@(private = "file")
note_original :: proc(view: ^Changes_View, file, first, last: int) -> []string {
	if file < 0 || file >= len(view.files) {return nil}
	out := make([dynamic]string, context.temp_allocator)
	flat := 0
	for &hunk in view.files[file].hunks {
		for &line, k in hunk.lines {
			at := flat + k
			if at < first || at > last || line.kind == .Removed || line.kind == .No_Newline {continue}
			append(&out, line.text)
		}
		flat += len(hunk.lines)
		if flat > last {break}
	}
	return out[:]
}

// The text a partial note covers, whitespace squeezed to single spaces and cut to `limit` characters with an
// ellipsis, in temporary memory. Empty for whole lines.
@(private = "file")
note_excerpt :: proc(view: ^Changes_View, file, first, last, from, to, limit: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	count := 0
	gap := false
	for line in first ..= last {
		text, found := line_text(view, file, line)
		if !found {continue}
		low := line == first ? clamp(from, 0, len(text)) : 0
		high := line == last ? clamp(to, low, len(text)) : len(text)
		for r in text[low:high] {
			if r == ' ' || r == '\t' || r == '\r' || r == '\n' {
				gap = count > 0
				continue
			}
			if count >= limit {
				strings.write_rune(&b, '…')
				return strings.to_string(b)
			}
			if gap {strings.write_byte(&b, ' ')}
			gap = false
			strings.write_rune(&b, r)
			count += 1
		}
		gap = count > 0
	}
	return strings.to_string(b)
}

// The excerpt a saved card shows, empty unless the note is partial.
@(private = "file")
card_excerpt :: proc(view: ^Changes_View, c: Changes_Comment_View, limit: int) -> string {
	if !c.partial || c.file < 0 {return ""}
	return note_excerpt(view, c.file, c.first, c.last, c.first_offset, c.last_offset, limit)
}

// A saved card's parts below the header, measured once at the width the card has.
@(private = "file")
Note_Plan :: struct {
	layout:                 Note_Layout,
	tagged, body:           bool,
	body_top, body_width:   f32,
	height:                 f32,
}

// The width Edit and Remove take at a card's top right, which the first line leaves free.
@(private = "file")
card_reserve :: proc(s: f32) -> f32 {
	return math.round((2 * CHANGES_CARD_ACTION + CHANGES_CARD_ACTION_GAP + CHANGES_CARD_ACTION_INSET) * s)
}

// How a saved note lays out in a card `width` wide: a first line when it has a tag or an excerpt, then its
// text through the note-body renderer. Without a first line the text leaves room for the buttons itself.
@(private = "file")
note_plan :: proc(
	view: ^Changes_View, c: Changes_Comment_View, text, mono: ^Text, width, s: f32,
) -> Note_Plan {
	pad := card_pad(s)
	inner := max(1, width - 2 * pad)
	p: Note_Plan
	p.tagged = c.kind != .Comment || c.partial
	p.body = strings.trim_space(c.text) != ""
	p.body_width = p.tagged ? inner : max(1, inner - card_reserve(s))
	top := pad
	if p.tagged {
		top += math.round(CHANGES_CARD_TAG * s)
		if p.body {top += math.round(SPACE_1 * s)}
	}
	p.body_top = top
	height := top
	if p.body {
		original := note_original(view, c.file, c.first, c.last)
		p.layout = note_body_layout(text, mono, c.text, original, p.body_width, s)
		height += math.round(p.layout.height)
	}
	p.height = max(height + pad, math.round((CHANGES_CARD_ACTION + 2 * CHANGES_CARD_ACTION_INSET) * s))
	return p
}

// The fixed parts of an editor card's height: the header, the tools row, a gap either side of the text area
// and the footer.
@(private = "file")
Editor_Metrics :: struct {
	header, tools, gap, footer, button, pad: f32,
}

@(private = "file")
editor_metrics :: proc(s: f32) -> Editor_Metrics {
	return {
		header = math.round(HEIGHT_STANDARD * s),
		tools  = math.round((SPACE_1 + HEIGHT_COMPACT) * s),
		gap    = math.round(SPACE_1 * s),
		footer = math.round(HEIGHT_STANDARD * s),
		button = math.round(HEIGHT_COMPACT * s),
		pad    = card_pad(s),
	}
}

// The tag and the location the editor's header shows for the note being written or edited.
@(private = "file")
editor_tag :: proc(view: ^Changes_View) -> Changes_Comment_View {
	tag := Changes_Comment_View {
		kind = view.draft,
	}
	if view.editing >= 0 && view.editing < len(view.comments) {
		tag.label_name = view.comments[view.editing].label_name
		tag.label_colour = view.comments[view.editing].label_colour
	}
	return tag
}

// The height of the editor card for a note in `file`, whose text area is as tall as its text; zero when
// there is no editor to measure.
@(private)
editor_height :: proc(rows: ^Changes_Rows, view: ^Changes_View, text: ^Text, file: int) -> int {
	if view.editor == nil || view.buffer == nil {return 0}
	s := rows.scale
	m := editor_metrics(s)
	width := card_span(rows, view, file).width - 2 * m.pad
	area := text_area_height(
		view.editor, view.buffer, text, width, s, CHANGES_AREA_MIN_LINES, CHANGES_AREA_MAX_LINES,
	)
	return int(m.header + m.tools + 2 * m.gap + math.round(area) + m.footer)
}

// The height of the card of a saved note.
@(private)
note_height :: proc(
	rows: ^Changes_Rows, view: ^Changes_View, c: Changes_Comment_View, text, mono: ^Text,
) -> int {
	span := card_span(rows, view, c.file)
	return int(math.round(note_plan(view, c, text, mono, span.width, rows.scale).height))
}

// The width the editor's tag takes in `text`, for the × at its end; zero when the editor has no tag.
@(private)
editor_tag_width :: proc(view: ^Changes_View, text: ^Text, s: f32) -> f32 {
	if view.draft == .Comment {return 0}
	detail := text_styled(text, .Detail)
	return tag_width(&detail, editor_tag(view), true, s)
}

// Where the editor card's parts are. `tag` is the width of the editor's tag, zero without one.
Changes_Editor :: struct {
	card, header, tools, area, footer:        render.Rect,
	tag, untag:                               render.Rect,
	bold, code, block, divider, suggest:      render.Rect,
	cancel, save:                             render.Rect,
}

changes_editor_parts :: proc(card: render.Rect, tag_width, scale: f32) -> Changes_Editor {
	m := editor_metrics(scale)
	e := Changes_Editor {
		card = card,
	}
	e.header = {card.x, card.y, card.width, m.header}
	tag := math.round(CHANGES_CARD_TAG * scale)
	if tag_width > 0 {
		e.tag = {card.x + m.pad, card.y + math.round((m.header - tag) / 2), tag_width, tag}
		wide := math.round((ICON_INDICATOR + SPACE_1 + CHANGES_TAG_PAD) * scale)
		e.untag = {e.tag.x + e.tag.width - wide, e.tag.y, wide, tag}
	}
	e.tools = {card.x, card.y + m.header, card.width, m.tools}
	button := m.button
	x, y := card.x + math.round(SPACE_1 * scale), e.tools.y + math.round(SPACE_1 * scale)
	e.bold = {x, y, button, button}
	e.code = {x + button, y, button, button}
	e.block = {x + 2 * button, y, button, button}
	rule := math.round(SPACE_2 * scale + scale)
	e.divider = {x + 3 * button, y, rule, button}
	e.suggest = {e.divider.x + rule, y, math.round(CHANGES_SUGGEST_WIDTH * scale), button}
	fixed := m.header + m.tools + 2 * m.gap + m.footer
	e.area = {card.x + m.pad, e.tools.y + e.tools.height + m.gap, card.width - 2 * m.pad, card.height - fixed}
	e.footer = {card.x, card.y + card.height - m.footer, card.width, m.footer}
	by := e.footer.y + math.round(2 * scale)
	e.save = {card.x + card.width - m.pad - math.round(CHANGES_SAVE_WIDTH * scale), by, 0, button}
	e.save.width = math.round(CHANGES_SAVE_WIDTH * scale)
	e.cancel = {e.save.x - m.gap - math.round(CHANGES_CANCEL_WIDTH * scale), by, 0, button}
	e.cancel.width = math.round(CHANGES_CANCEL_WIDTH * scale)
	return e
}

// The Edit and Remove buttons at a saved card's top right.
changes_note_actions :: proc(card: render.Rect, scale: f32) -> (edit, remove: render.Rect) {
	size, inset := math.round(CHANGES_CARD_ACTION * scale), math.round(CHANGES_CARD_ACTION_INSET * scale)
	gap := math.round(CHANGES_CARD_ACTION_GAP * scale)
	remove = {card.x + card.width - inset - size, card.y + inset, size, size}
	edit = {remove.x - gap - size, remove.y, size, size}
	return
}

// The editor card's parts, and where the editor card is; false when no editor is open or it is off the
// stream.
changes_editor_of :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State,
) -> (
	editor: Changes_Editor,
	shown: bool,
) {
	if view.editing < 0 || view.editor == nil || view.buffer == nil {return}
	card := changes_card_rect(g, view, state, view.editing) or_return
	return changes_editor_parts(card, state.rows.tag_width, g.scale), true
}

// The editor's text area, for the caret, the pointer and the vertical keys; false when no editor shows.
changes_editor_box :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, text: ^Text,
) -> (
	box: Text_Area_Box,
	shown: bool,
) {
	parts := changes_editor_of(g, view, state) or_return
	return {area = view.editor, buffer = view.buffer, text = text, rect = parts.area, scale = g.scale}, true
}

// Whether the pane is narrow enough that every note card keeps its Edit and Remove buttons shown.
@(private = "file")
cards_narrow :: proc(rows: ^Changes_Rows) -> bool {
	return rows.width < CHANGES_CARD_NARROW * rows.scale
}

// What lies at the point on card `card` at `rect`: the editor's tools, text area and buttons, a saved
// card's Edit and Remove, or the card itself.
@(private)
card_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, card: int, rect: render.Rect, x, y: f32,
) -> Changes_Hit {
	if card == view.editing {
		e := changes_editor_parts(rect, state.rows.tag_width, g.scale)
		buttons := [?]struct {
			rect: render.Rect,
			part: Changes_Part,
		}{
			{e.untag, .Editor_Untag},
			{e.bold, .Editor_Bold},
			{e.code, .Editor_Code},
			{e.block, .Editor_Block},
			{e.suggest, .Editor_Suggest},
			{e.cancel, .Editor_Cancel},
			{e.save, .Editor_Save},
		}
		for button in buttons {
			if render.rect_contains(button.rect, x, y) {return {button.part, card, 0}}
		}
		if render.rect_contains(e.area, x, y) {return {.Comment_Editor, card, 0}}
		return {.Comment_Card, card, 0}
	}
	edit, remove := changes_note_actions(rect, g.scale)
	if render.rect_contains(edit, x, y) {return {.Comment_Edit, card, 0}}
	if render.rect_contains(remove, x, y) {return {.Comment_Remove, card, 0}}
	return {.Comment_Card, card, 0}
}

// `a` and `b` mixed, `amount` of `b`.
@(private = "file")
colour_mix :: proc(a, b: render.Color, amount: f32) -> render.Color {
	return {
		math.lerp(a.r, b.r, amount),
		math.lerp(a.g, b.g, amount),
		math.lerp(a.b, b.b, amount),
		math.lerp(a.a, b.a, amount),
	}
}

// How far a hovered card's border takes its note's colour.
@(private = "file")
CHANGES_CARD_HOT :: f32(0.55)

// The ink of a tag's words on `background`: the label's colour, or the error colour for a deletion, raised to
// the diff's minimum contrast.
@(private = "file")
tag_ink :: proc(theme: Theme, c: Changes_Comment_View, background: render.Color, ratio: f32) -> render.Color {
	if c.kind == .Label {return quick_label_ink(theme, c.label_colour, background, ratio)}
	return render.Color(colour.minimum_contrast(colour.RGBA(theme.error), colour.RGBA(background), ratio))
}

// A tag: its tint, its words with a deletion's icon, and when it can be taken off, a × at its end.
@(private = "file")
tag_draw :: proc(
	p: ^Diff_Paint, rect: render.Rect, c: Changes_Comment_View, untag: render.Rect, card: int,
) -> render.Build_Status {
	t, s := p.theme, p.scale
	fill := colour_alpha(changes_note_color(t, c), CHANGES_TAG_TINT)
	draw_rect(p.list, {rect = rect, color = fill, radius = RADIUS_CONTROL * s})
	ink := tag_ink(t, c, colour_over(fill, t.surface), p.view.minimum_contrast)
	x := rect.x + CHANGES_TAG_PAD * s
	if c.kind == .Delete {
		icon_draw(
			p.list, .Strikethrough, {x, rect.y, ICON_INDICATOR * s, rect.height}, ink, ICON_INDICATOR, s,
		)
		x += (ICON_INDICATOR + SPACE_1) * s
	}
	name := tag_text(c)
	if r := draw_text(p.small, p.list, name, x, baseline_in(rect.y, rect.height, p.small), ink); r != .Ok {
		return r
	}
	if untag.width <= 0 {return .Ok}
	hover, _ := changes_lit(p.state, {.Editor_Untag, card, 0})
	cross := ink
	cross.a *= math.lerp(f32(0.7), 1, hover)
	size := ICON_INDICATOR * s
	icon := render.Rect{untag.x + untag.width - CHANGES_TAG_PAD * s - size, rect.y, size, rect.height}
	icon_draw(p.list, .Close, icon, cross, ICON_INDICATOR, s)
	return .Ok
}

// The excerpt chip: the selected text in the diff's font on a muted fill, from `x`, no wider than `room`.
// Returns where it ends.
@(private = "file")
excerpt_draw :: proc(
	p: ^Diff_Paint, text: string, x, y, room: f32,
) -> (
	end: f32,
	status: render.Build_Status,
) {
	s := p.scale
	if text == "" || room <= 2 * SPACE_1 * s {return x, .Ok}
	height := math.round(CHANGES_CARD_TAG * s)
	width := min(text_width(p.mono, text) + 2 * SPACE_1 * s + s, room)
	chip := render.Rect{x, y, width, height}
	draw_rect(p.list, {rect = chip, color = p.theme.hover, radius = RADIUS_CONTROL * s})
	status = draw_fading_text(
		p.mono, p.list, text, x + SPACE_1 * s + s / 2, baseline_in(y, height, p.mono), p.theme.muted,
		width - 2 * SPACE_1 * s,
	)
	return x + width, status
}

// Notch on a card's top edge pointing at its lines: two lines meeting at a point, filled with the card's own
// surface so the edge between them seems to open into it.
@(private = "file")
notch_draw :: proc(list: ^render.Draw_List, rect: render.Rect, fill, border: render.Color, s: f32) {
	size := math.round(CHANGES_CARD_NOTCH * s)
	stroke := max(1, math.round(s))
	apex := rect.x + math.round(CHANGES_CARD_NOTCH_AT * s)
	_ = render.push_segment(list, {apex - size, rect.y}, {apex, rect.y - size}, stroke, border)
	_ = render.push_segment(list, {apex, rect.y - size}, {apex + size, rect.y}, stroke, border)
	for row in 0 ..< int(size) {
		half := size - f32(row) - stroke
		if half <= 0 {continue}
		y := row == 0 ? rect.y : rect.y - f32(row)
		draw_rect(list, {rect = {apex - half, y, 2 * half, row == 0 ? stroke : 1}, color = fill})
	}
}

// A saved note: its first line (the tag and the excerpt), its text, and Edit and Remove while the pointer
// is on it or the pane is narrow.
@(private)
paint_note_card :: proc(p: ^Diff_Paint, rect: render.Rect, card: int) -> render.Build_Status {
	t, s, view, state := p.theme, p.scale, p.view, p.state
	c := view.comments[card]
	radius := RADIUS_CONTROL * s
	colour := changes_note_color(t, c)
	hot := hot_note(state) == card
	border := hot ? colour_mix(t.border, colour, CHANGES_CARD_HOT) : t.border
	draw_rect(p.list, {rect = rect, color = t.surface, radius = radius})
	draw_rect(p.list, {rect = rect, color = border, radius = radius, stroke = s})
	if comment_attached(view, card) {notch_draw(p.list, rect, t.surface, border, s)}
	pad := card_pad(s)
	plan := note_plan(view, c, p.body, p.mono, rect.width, s)
	first := math.round(CHANGES_CARD_TAG * s)
	if plan.tagged {
		x, y := rect.x + pad, rect.y + pad
		room := rect.width - 2 * pad - card_reserve(s)
		if c.kind != .Comment {
			tag := render.Rect{x, y, tag_width(p.small, c, false, s), first}
			if r := tag_draw(p, tag, c, {}, card); r != .Ok {return r}
			x += tag.width + SPACE_2 * s
			room -= tag.width + SPACE_2 * s
		}
		excerpt := card_excerpt(view, c, CHANGES_EXCERPT_NOTE)
		if _, r := excerpt_draw(p, excerpt, x, y, room); r != .Ok {return r}
	}
	if plan.body {
		language: syntax.Language
		if c.file >= 0 && c.file < len(view.files) {
			language = syntax.language_for_path(view.files[c.file].new_path)
		}
		origin := [2]f32{rect.x + pad, rect.y + plan.body_top}
		layout := plan.layout
		if r := note_body_draw(
			p.list, p.body, p.mono, t, &state.inks, &layout, origin, language, s, p.top, p.bottom,
		); r != .Ok {
			return r
		}
	}
	if !hot && !cards_narrow(&state.rows) {return .Ok}
	edit, remove := changes_note_actions(rect, s)
	both := render.Rect{edit.x, edit.y, remove.x + remove.width - edit.x, edit.height}
	draw_rect(p.list, {rect = both, color = t.surface, radius = radius})
	hover, press := changes_lit(state, {.Comment_Edit, card, 0})
	if icon_button_draw(
		p.list, t, edit, .Pencil, hover, press, s, p.pointer, ICON_INDICATOR, RADIUS_CONTROL,
	) != .None {return .Ok}
	hover, press = changes_lit(state, {.Comment_Remove, card, 0})
	_ = icon_button_draw(
		p.list, t, remove, .Trash, hover, press, s, p.pointer, ICON_INDICATOR, RADIUS_CONTROL,
	)
	return .Ok
}

// The file the editor's note is in, -1 for none.
@(private = "file")
editor_file :: proc(view: ^Changes_View) -> int {
	if view.editing >= 0 && view.editing < len(view.comments) {return view.comments[view.editing].file}
	return view.selection.active ? view.selection.file : -1
}

// The text a partial note covers, as the editor's header shows it.
@(private = "file")
editor_excerpt :: proc(view: ^Changes_View) -> string {
	if view.editing >= 0 && view.editing < len(view.comments) {
		return card_excerpt(view, view.comments[view.editing], CHANGES_EXCERPT_EDITOR)
	}
	s := view.selection
	if !s.active || !s.partial {return ""}
	return note_excerpt(view, s.file, s.first, s.last, s.first_offset, s.last_offset, CHANGES_EXCERPT_EDITOR)
}

// What the empty text area says: what the note will be.
changes_editor_placeholder :: proc(kind: Changes_Note_Kind) -> string {
	switch kind {
	case .Label:
		return "Add to the label (optional)"
	case .Delete:
		return "Why delete it? (optional)"
	case .Comment:
		return "Leave a comment"
	}
	return ""
}

// Whether Save can save: a plain comment needs words, a label or a deletion does not.
changes_editor_can_save :: proc(view: ^Changes_View) -> bool {
	if view.draft != .Comment {return true}
	return view.buffer != nil && strings.trim_space(markdown.edit_string(view.buffer)) != ""
}

// A flat button of the editor's tools; false when the face could not be drawn.
@(private = "file")
tool_button :: proc(
	p: ^Diff_Paint, rect: render.Rect, part: Changes_Part, card: int, disabled: bool,
) -> (
	face: render.Rect,
	ink: render.Color,
	ok: bool,
) {
	hover, press := changes_lit(p.state, {part, card, 0})
	b := Button {
		rect     = rect,
		hover    = hover,
		press    = press,
		radius   = RADIUS_CONTROL,
		surface  = .Flat,
		disabled = disabled,
	}
	err: render.Error
	face, ink, err = button_draw(p.list, p.theme, b, p.scale, p.pointer)
	return face, ink, err == .None
}

// An icon centred in a button's face.
@(private = "file")
tool_icon :: proc(p: ^Diff_Paint, face: render.Rect, icon: Icon, ink: render.Color) {
	size := ICON_BUTTON * p.scale
	area := render.Rect{face.x + (face.width - size) / 2, face.y, size, face.height}
	icon_draw(p.list, icon, area, ink, ICON_BUTTON, p.scale)
}

// `label` centred in `face`, clipped to it.
@(private = "file")
label_draw :: proc(
	p: ^Diff_Paint, t: ^Text, face: render.Rect, label: string, ink: render.Color,
) -> render.Build_Status {
	width := min(text_width(t, label), face.width)
	baseline := baseline_in(face.y, face.height, t)
	return draw_text(t, p.list, label, face.x + (face.width - width) / 2, baseline, ink, face.width)
}

// The lines the editor's header names: "Line 3" or "Lines 3–5", with "(before)" for the old side.
@(private = "file")
editor_location :: proc(buf: []u8, span: Changes_Span) -> string {
	loc: string
	if span.first == span.last {
		loc = fmt.bprintf(buf, "Line %d", span.first)
	} else {
		loc = fmt.bprintf(buf, "Lines %d–%d", span.first, span.last)
	}
	if span.old {loc = fmt.bprintf(buf[len(loc):], "%s (before)", loc)}
	return loc
}

// The editor's header: the tag and its ×, the lines, the file and the excerpt of a text selection.
@(private = "file")
editor_header_draw :: proc(
	p: ^Diff_Paint, e: Changes_Editor, m: Editor_Metrics, card: int,
) -> render.Build_Status {
	t, s, view := p.theme, p.scale, p.view
	head := e.header
	rule := max(1, math.round(s))
	draw_rect(p.list, {rect = {head.x, head.y + head.height - rule, head.width, rule}, color = t.border})
	x := head.x + m.pad
	if e.tag.width > 0 {
		if r := tag_draw(p, e.tag, editor_tag(view), e.untag, card); r != .Ok {return r}
		x = e.tag.x + e.tag.width + SPACE_2 * s
	}
	right := head.x + head.width - m.pad
	buf: [64]u8
	loc := editor_location(buf[:], view.span)
	if x + text_width(p.strong, loc) > right {return .Ok}
	baseline := baseline_in(head.y, head.height, p.strong)
	if r := draw_text(p.strong, p.list, loc, x, baseline, t.text); r != .Ok {return r}
	x += text_width(p.strong, loc) + SPACE_2 * s
	if file := editor_file(view); file >= 0 && file < len(view.files) {
		path := view.files[file].new_path
		name := path[strings.last_index_any(path, "/\\") + 1:]
		width := min(text_width(p.body, name), max(0, right - x))
		name_baseline := baseline_in(head.y, head.height, p.body)
		if r := draw_fading_text(p.body, p.list, name, x, name_baseline, t.muted, width); r != .Ok {return r}
		x += width + SPACE_2 * s
	}
	y := head.y + math.round((head.height - CHANGES_CARD_TAG * s) / 2)
	_, status := excerpt_draw(p, editor_excerpt(view), x, y, right - x)
	return status
}

// The key hint at the footer's left, as far as it fits before Cancel: Ctrl+Enter saves and Esc cancels.
@(private = "file")
editor_hint_draw :: proc(p: ^Diff_Paint, e: Changes_Editor, m: Editor_Metrics) -> render.Build_Status {
	t, s := p.theme, p.scale
	keys := [?]string{"Ctrl+Enter", "save", "Esc", "cancel"}
	x := e.footer.x + m.pad
	hint: f32
	for word, i in keys {
		if i % 2 == 0 {
			hint += keycap_width(p.small, word, s) + SPACE_1 * s
		} else {
			hint += text_width(p.small, word) + SPACE_2 * s
		}
	}
	if x + hint - SPACE_2 * s > e.cancel.x - SPACE_2 * s {return .Ok}
	baseline := baseline_in(e.footer.y, e.footer.height, p.small)
	for word, i in keys {
		if i % 2 == 0 {
			if r := keycap_draw(p.list, p.small, t, word, x, e.footer.y, e.footer.height, s); r != .Ok {
				return r
			}
			x += keycap_width(p.small, word, s) + SPACE_1 * s
		} else {
			if r := draw_text(p.small, p.list, word, x, baseline, t.faint); r != .Ok {return r}
			x += text_width(p.small, word) + SPACE_2 * s
		}
	}
	return .Ok
}

// The editor's footer: the keys, Cancel and Save.
@(private = "file")
editor_footer_draw :: proc(
	p: ^Diff_Paint, e: Changes_Editor, m: Editor_Metrics, card: int,
) -> render.Build_Status {
	t, s, view := p.theme, p.scale, p.view
	if r := editor_hint_draw(p, e, m); r != .Ok {return r}
	if face, ink, ok := tool_button(p, e.cancel, .Editor_Cancel, card, false); ok {
		if r := label_draw(p, p.body, face, "Cancel", ink); r != .Ok {return r}
	}
	label := view.editing < len(view.comments) ? "Save" : "Add note"
	if changes_editor_can_save(view) {
		hover, press := changes_lit(p.state, {.Editor_Save, card, 0})
		return primary_button_draw(p.list, p.body, t, e.save, label, hover, press, false, s, p.pointer)
	}
	// Like Send while it cannot send: the primary button at a lower opacity.
	fill, ink := t.accent, t.accent_text
	fill.a *= DISABLED_ALPHA
	ink.a *= DISABLED_ALPHA
	draw_rect(p.list, {rect = e.save, color = fill, radius = RADIUS_CONTROL * s})
	strong := text_styled(p.body, .Strong)
	return label_draw(p, &strong, e.save, label, ink)
}

// The editor's tools: Bold, Inline code, Code block, a divider and Suggest change.
@(private = "file")
editor_tools_draw :: proc(p: ^Diff_Paint, e: Changes_Editor, card: int) -> render.Build_Status {
	t, s, view := p.theme, p.scale, p.view
	if face, ink, ok := tool_button(p, e.bold, .Editor_Bold, card, false); ok {
		if r := label_draw(p, p.strong, face, "B", ink); r != .Ok {return r}
	}
	if face, ink, ok := tool_button(p, e.code, .Editor_Code, card, false); ok {tool_icon(p, face, .Code, ink)}
	if face, ink, ok := tool_button(p, e.block, .Editor_Block, card, false); ok {
		tool_icon(p, face, .Code_Block, ink)
	}
	rule, size := max(1, math.round(s)), math.round(ICON_BUTTON * s)
	mark := render.Rect {
		math.round(e.divider.x + (e.divider.width - rule) / 2),
		e.divider.y + (e.divider.height - size) / 2,
		rule,
		size,
	}
	draw_rect(p.list, {rect = mark, color = t.border})
	face, ink, ok := tool_button(p, e.suggest, .Editor_Suggest, card, view.span.old)
	if !ok {return .Ok}
	word := "Suggest change"
	icon := ICON_INDICATOR * s
	x := face.x + max(0, (face.width - (icon + SPACE_1 * s + text_width(p.small, word))) / 2)
	icon_draw(p.list, .Pencil, {x, face.y, icon, face.height}, ink, ICON_INDICATOR, s)
	baseline := baseline_in(face.y, face.height, p.small)
	return draw_text(p.small, p.list, word, x + icon + SPACE_1 * s, baseline, ink)
}

// The editor card: header, tools, the text area and the footer, in the focus ring.
@(private)
paint_editor_card :: proc(p: ^Diff_Paint, rect: render.Rect, card: int) -> render.Build_Status {
	t, s, view := p.theme, p.scale, p.view
	if view.editor == nil || view.buffer == nil {return .Ok}
	radius := RADIUS_CONTROL * s
	draw_rect(p.list, {rect = rect, color = t.surface, radius = radius})
	draw_rect(p.list, {rect = rect, color = t.border, radius = radius, stroke = s})
	focus_ring_draw(p.list, rect, t, s)
	e := changes_editor_parts(rect, p.state.rows.tag_width, s)
	m := editor_metrics(s)
	if r := editor_header_draw(p, e, m, card); r != .Ok {return r}
	if r := editor_tools_draw(p, e, card); r != .Ok {return r}
	box := Text_Area_Box {
		area   = view.editor,
		buffer = view.buffer,
		text   = p.body,
		rect   = e.area,
		scale  = s,
	}
	if r := text_area_draw(box, p.list, t, true, changes_editor_placeholder(view.draft)); r != .Ok {return r}
	return editor_footer_draw(p, e, m, card)
}
