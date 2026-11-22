package ui

import "cosmos:render"
import "core:fmt"
import "core:math"
import "core:strings"

// Structured rows for a Dropdown: a status badge, a primary text that stays whole while the row has room
// for it, a secondary text (a folder) shortened from its start, small marks, and counts in columns at the
// right. A list gives `Dropdown_Choices.rows` to draw its options this way instead of as one label; the
// search, keys, scrolling and fitting are the dropdown's own.

// The semantic colours a row's badge, marks and counts take from the theme.
Dropdown_Tint :: enum u8 {
	None,
	Success,
	Warning,
	Error,
	Info,
}

dropdown_tint_color :: proc(theme: Theme, tint: Dropdown_Tint) -> render.Color {
	switch tint {
	case .None:
		return theme.muted
	case .Success:
		return theme.success
	case .Warning:
		return theme.warning
	case .Error:
		return theme.error
	case .Info:
		return theme.info
	}
	return theme.muted
}

// A small icon before the counts.
Dropdown_Mark :: struct {
	icon: Icon,
	tint: Dropdown_Tint,
}

// One option. `badge` is a letter or two in a square tinted by `badge_tint`, or a solid square of
// `swatch` when `swatched`; `primary` is the name, `secondary` the folder; `added` and `removed` are
// the counts, shown as +A and −R unless both are zero.
Dropdown_Row :: struct {
	badge:             string,
	badge_tint:        Dropdown_Tint,
	swatch:            render.Color,
	swatched:          bool,
	primary:           string,
	secondary:         string,
	marks:             [2]Dropdown_Mark,
	added, removed:    int,
}

// What the rows need to lay out, measured from every row so the columns and the list's width stay put
// while a search narrows the list. Kept between frames, and measured again when the rows, the type size
// or the scale change.
Dropdown_Metrics :: struct {
	valid:                          bool,
	serial, count:                  int,
	size_px, scale:                 f32,
	// The room the widest row wants, in pixels, and the column widths of the counts and the marks.
	content, plus, minus, marks:    f32,
}

DROPDOWN_BADGE_SIZE :: f32(16)
DROPDOWN_ROW_INSET :: f32(8)
DROPDOWN_ROW_GAP :: f32(8)
// The tint of a badge's square: the status colour at this alpha.
DROPDOWN_BADGE_ALPHA :: f32(0.18)
@(private = "file")
DROPDOWN_FOLDER_LEAD :: "…/"
@(private = "file")
DROPDOWN_ROW_SLACK :: f32(16)

@(private = "file")
dropdown_plus_text :: proc(buf: []u8, row: Dropdown_Row) -> string {
	return fmt.bprintf(buf, "+%d", row.added)
}

@(private = "file")
dropdown_minus_text :: proc(buf: []u8, row: Dropdown_Row) -> string {
	return fmt.bprintf(buf, "\u2212%d", row.removed)
}

@(private = "file")
dropdown_row_marks :: proc(row: Dropdown_Row) -> int {
	count := 0
	for mark in row.marks {
		if mark.icon != .None {count += 1}
	}
	return count
}

// Measures every row for the lists that give `rows`. `serial` says when the rows changed.
dropdown_measure :: proc(d: ^Dropdown, c: Dropdown_Choices, text: ^Text, scale: f32) {
	m := &d.metrics
	if len(c.rows) == 0 {
		m^ = {}
		return
	}
	if m.valid && m.serial == c.rows_serial && m.count == len(c.rows) && m.size_px == text.size_px &&
	   m.scale == scale {
		return
	}
	body := text_styled(text, .Body)
	detail := text_styled(text, .Detail)
	m^ = {valid = true, serial = c.rows_serial, count = len(c.rows), size_px = text.size_px, scale = scale}
	line, most_marks := f32(0), 0
	for row in c.rows {
		width := math.ceil(text_width(&body, row.primary))
		if row.secondary != "" {width += DROPDOWN_ROW_GAP * scale + math.ceil(text_width(&detail, row.secondary))}
		line = max(line, width)
		if row.added > 0 || row.removed > 0 {
			plus_buf, minus_buf: [24]u8
			m.plus = max(m.plus, math.ceil(text_width(&detail, dropdown_plus_text(plus_buf[:], row))))
			m.minus = max(m.minus, math.ceil(text_width(&detail, dropdown_minus_text(minus_buf[:], row))))
		}
		most_marks = max(most_marks, dropdown_row_marks(row))
	}
	m.marks = f32(most_marks) * (ICON_INDICATOR + SPACE_1) * scale
	counts := m.plus > 0 ? m.plus + SPACE_1 * scale + m.minus : 0
	m.content = (2 * DROPDOWN_ROW_INSET + DROPDOWN_BADGE_SIZE + DROPDOWN_ROW_GAP) * scale + line + counts +
	            m.marks + (SPACE_3 + 2 * OVERLAY_PADDING) * scale + DROPDOWN_ROW_SLACK * scale
}

// Where each part of a row goes in its option, and the folder as it shows.
Dropdown_Row_Layout :: struct {
	badge:                       render.Rect,
	name_x, name_room:           f32,
	// The folder as shown, in the caller's buffer or the row's own text; "" when it is hidden or there is
	// none. `cut` is set when the folder is shortened or hidden, so the full path is worth a tooltip.
	folder:                      string,
	folder_x:                    f32,
	cut:                         bool,
	plus_right, minus_right:     f32,
	marks_left:                  f32,
}

// Lays a row out in `option`: the badge, the name whole while it fits, the folder after it shortened from
// its start with a leading "…/" to the room that is left, the marks and the counts' columns at the right.
// The name only fades when it alone does not fit. `buf` holds a shortened folder.
dropdown_row_layout :: proc(
	row: Dropdown_Row, option: render.Rect, m: Dropdown_Metrics, body, detail: ^Text, scale: f32, buf: []u8,
) -> (
	l: Dropdown_Row_Layout,
) {
	s := scale
	x := option.x + DROPDOWN_ROW_INSET * s
	size := DROPDOWN_BADGE_SIZE * s
	l.badge = {x, option.y + math.round((option.height - size) / 2), size, size}
	l.name_x = x + size + DROPDOWN_ROW_GAP * s
	right := option.x + option.width - DROPDOWN_ROW_INSET * s
	l.minus_right = right
	l.plus_right = right - (m.minus > 0 ? m.minus + SPACE_1 * s : 0)
	left := m.plus > 0 ? l.plus_right - m.plus : right
	l.marks_left = left
	if marks := dropdown_row_marks(row); marks > 0 {
		l.marks_left = left - f32(marks) * (ICON_INDICATOR + SPACE_1) * s - SPACE_1 * s
	}
	room := l.marks_left - SPACE_3 * s - l.name_x
	l.name_room = room
	name := math.ceil(text_width(body, row.primary))
	if name >= room || row.secondary == "" {
		l.cut = row.secondary != ""
		return
	}
	l.name_room = name
	remaining := room - name - DROPDOWN_ROW_GAP * s
	l.folder_x = l.name_x + name + DROPDOWN_ROW_GAP * s
	if text_width(detail, row.secondary) <= remaining {
		l.folder = row.secondary
		return
	}
	l.cut = true
	// Drop whole folders from the start until "…/" and what is left fit; the part nearest the file stays.
	rest := row.secondary
	for {
		at := strings.index_byte(rest, '/')
		if at < 0 {return}
		rest = rest[at + 1:]
		lead := DROPDOWN_FOLDER_LEAD
		if len(lead) + len(rest) > len(buf) {continue}
		n := copy(buf, lead)
		n += copy(buf[n:], rest)
		shown := string(buf[:n])
		if text_width(detail, shown) <= remaining {
			l.folder = shown
			return
		}
	}
}

// Draws one row's contents in `option`; `faded` rows are drawn at the disabled alpha but stay pickable.
dropdown_row_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	row: Dropdown_Row,
	l: Dropdown_Row_Layout,
	m: Dropdown_Metrics,
	option: render.Rect,
	faded: bool,
	scale: f32,
) -> render.Build_Status {
	s := scale
	body := text_styled(text, .Body)
	detail := text_styled(text, .Detail)
	badge_text := text_styled(text, .Detail)
	badge_text.family = text.strong_family
	alpha := faded ? DISABLED_ALPHA : 1
	text_ink := with_alpha(theme.text, alpha)
	tint := dropdown_tint_color(theme, row.badge_tint)
	fill := tint
	fill.a *= DROPDOWN_BADGE_ALPHA * alpha
	if row.swatched {
		radius := RADIUS_CONTROL * s
		draw_rect(list, {rect = l.badge, color = with_alpha(row.swatch, alpha), radius = radius})
		draw_rect(list, {rect = l.badge, color = with_alpha(theme.border, alpha), radius = radius, stroke = s})
	} else {
		draw_rect(list, {rect = l.badge, color = fill, radius = RADIUS_CONTROL * s})
	}
	if row.badge != "" {
		ink := with_alpha(tint, alpha)
		x := l.badge.x + (l.badge.width - text_width(&badge_text, row.badge)) / 2
		at := baseline_caps(l.badge.y, l.badge.height, &badge_text)
		if r := draw_text(&badge_text, list, row.badge, x, at, ink); r != .Ok {return r}
	}
	baseline := baseline_caps(option.y, option.height, &body)
	if r := draw_fading_text(&body, list, row.primary, l.name_x, baseline, text_ink, l.name_room); r != .Ok {
		return r
	}
	if l.folder != "" {
		muted := with_alpha(theme.muted, alpha)
		if r := draw_text(&detail, list, l.folder, l.folder_x, baseline, muted); r != .Ok {return r}
	}
	x := l.marks_left
	for mark in row.marks {
		if mark.icon == .None {continue}
		size := ICON_INDICATOR * s
		icon_draw(
			list, mark.icon, {x, option.y, size, option.height},
			with_alpha(dropdown_tint_color(theme, mark.tint), alpha), ICON_INDICATOR, s,
		)
		x += size + SPACE_1 * s
	}
	if row.added > 0 || row.removed > 0 {
		plus_buf, minus_buf: [24]u8
		plus := dropdown_plus_text(plus_buf[:], row)
		minus := dropdown_minus_text(minus_buf[:], row)
		if r := draw_text(
			&detail, list, plus, l.plus_right - text_width(&detail, plus), baseline,
			with_alpha(theme.success, alpha),
		); r != .Ok {return r}
		if r := draw_text(
			&detail, list, minus, l.minus_right - text_width(&detail, minus), baseline,
			with_alpha(theme.error, alpha),
		); r != .Ok {return r}
	}
	return .Ok
}

@(private = "file")
with_alpha :: proc(color: render.Color, alpha: f32) -> render.Color {
	c := color
	c.a *= alpha
	return c
}

// The row under (`x`, `y`) as an index into the choices, and whether its folder is shortened or hidden, so
// its full path is worth a tooltip. -1 outside the options.
dropdown_row_cut :: proc(
	d: ^Dropdown, c: Dropdown_Choices, a: Dropdown_Anchor, text: ^Text, x, y, scale: f32,
) -> (
	source: int,
	cut: bool,
) {
	source = -1
	if len(c.rows) == 0 {return}
	position := dropdown_option_at(d, c, a, x, y, scale)
	if position < 0 {return}
	popup := dropdown_rect(d, c, a, scale)
	top := popup.y + dropdown_header(c, scale) + OVERLAY_PADDING * scale
	option := render.Rect {
		popup.x + OVERLAY_PADDING * scale,
		top + f32(position - d.list.scroll) * CHOICE_HEIGHT * scale,
		dropdown_option_right(d, c, a, popup, scale) - popup.x - OVERLAY_PADDING * scale,
		CHOICE_HEIGHT * scale,
	}
	source = dropdown_source(d, c, position)
	if source >= len(c.rows) {return -1, false}
	dropdown_measure(d, c, text, scale)
	body := text_styled(text, .Body)
	detail := text_styled(text, .Detail)
	buf: [CLIP_BYTES + 8]u8
	l := dropdown_row_layout(c.rows[source], option, d.metrics, &body, &detail, scale, buf[:])
	return source, l.cut
}
