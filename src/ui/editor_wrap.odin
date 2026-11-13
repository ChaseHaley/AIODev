package ui

import "aio:render"
import "core:math"

// Settings descriptions wrap to the width left of their row's control, so a row is as tall as its
// description needs. The page keeps measuring in lines of ROW_HEIGHT: a row of one description line
// is one line, and each further description line adds a fraction of one. `scroll` and
// `scroll_fraction` still name a page line and how far into it the page is, so a position survives
// re-wrapping; `tops` turns positions into offsets for drawing, hit testing and the scrollbar.

// The most lines a description wraps to; the last one ends in an ellipsis past that.
@(private)
DESCRIPTION_LINES :: 12
// Narrower than this, in DIPs, a description stays on one line ending in an ellipsis rather than
// stacking a few letters per line.
@(private)
DESCRIPTION_MIN_WIDTH :: 80

// Where a row's description breaks, for the width and type size it was last wrapped at, and whether
// it is `cut`: past the line cap, or on one line too narrow to wrap and still too wide. Wrapping
// happens when the width or type size changes; drawing and the hover tooltip read what is stored.
Description_Wrap :: struct {
	width, size: f32,
	count:       int,
	cut:         bool,
	lines:       [DESCRIPTION_LINES][2]i32,
}

// Re-wraps `s` to `width` when the width or type size changed; true when its line count changed.
@(private)
description_wrap :: proc(w: ^Description_Wrap, small: ^Text, s: string, width: f32) -> bool {
	if w.width == width && w.size == small.size_px {return false}
	count := w.count
	w.width, w.size, w.count, w.cut = width, small.size_px, 0, false
	lines := Wrap_Lines{text = small, s = s, width = width, last_space = -1}
	for start, end in wrap_next(&lines) {
		if w.count == DESCRIPTION_LINES {
			w.lines[w.count - 1][1] = i32(len(s))
			w.cut = true
			break
		}
		w.lines[w.count] = {i32(start), i32(end)}
		w.count += 1
	}
	return w.count != count
}

// Measures a description that stays on one line at `width`; true when it had been wrapped before.
@(private)
description_one_line :: proc(w: ^Description_Wrap, small: ^Text, s: string, width: f32) -> bool {
	if w.width == width && w.size == small.size_px && w.count == 0 {return false}
	wrapped := w.count > 0
	w^ = {width = width, size = small.size_px, cut = text_width(small, s) > width}
	return wrapped
}

// Draws a description on the lines it was wrapped to, the first on `baseline`. One that was never
// wrapped draws on one line, ending in an ellipsis when it is too wide.
@(private)
description_draw :: proc(
	small: ^Text, list: ^render.Draw_List, row: ^Editor_Row, x, baseline, width: f32, color: render.Color,
) -> render.Build_Status {
	s, w := row.description, &row.wrap
	if w.count <= 1 {return draw_text(small, list, s, x, baseline, color, width)}
	for line, i in w.lines[:w.count] {
		start, end := min(int(line[0]), len(s)), min(int(line[1]), len(s))
		if result := draw_text(small, list, s[start:end], x, baseline + f32(i) * small.line_height, color, width);
		   result != .Ok {return result}
	}
	return .Ok
}

// The top ROW_HEIGHT of a row: its title, first description line and control, wherever the
// rest of its description wraps to.
@(private)
row_band :: proc(r: render.Rect, s: f32) -> render.Rect {
	return {r.x, r.y, r.width, min(r.height, ROW_HEIGHT * s)}
}

// Where a row's title and description start: settings sit one step in from their group heading, a
// profile's or link program's fields one more, and a Motion field one more per context level.
@(private)
row_text_x :: proc(row: ^Editor_Row, r: render.Rect, s: f32) -> f32 {
	x := r.x + ITEM_INSET * s
	if row.profile != "" || row.opener != "" {x += SPACE_6 * s}
	if row.motion_part in MOTION_FIELD_PARTS {x += f32(motion_depth(row.motion_context) + 1) * SPACE_6 * s}
	return x
}

// The width a row's description runs to under its title, and whether it wraps there. `under` is
// false for a row whose description has a column of its own: tables, headers and the theme strip
// keep it on one line. A row left too narrow keeps it on one ellipsized line. A shortcut row leaves
// room for the key-position switch it shows while selected, so selecting it keeps its height.
@(private)
row_description_width :: proc(p: ^Editor, l: Editor_Layout, index: int) -> (width: f32, under, wraps: bool) {
	row := &p.rows[p.items[index].row]
	if row.description == "" || row.process_field != .None {return}
	#partial switch row.kind {
	case .Opener, .Profile, .Profile_Add, .Theme_Strip, .Motion_Context, .Process_Group:
		return
	}
	parts := row_parts_at(p, l, index, true)
	width = max(1, parts.text_right - row_text_x(row, parts.row, l.scale))
	return width, true, width >= DESCRIPTION_MIN_WIDTH * l.scale
}

// Wraps the shown rows' descriptions for this layout and type size, then measures the page again
// when any row's height changed. Rows already wrapped at their width cost a comparison; the page
// is walked only after a rebuild, a new width or a new type size.
@(private)
editor_wrap_fit :: proc(p: ^Editor, l: Editor_Layout, text: ^Text) {
	if text == nil || l.row_height <= 0 || editor_chained(p) || color_board_shown(p) {return}
	small := text_styled(text, .Detail)
	unit := small.line_height / l.row_height
	key := [3]f32{l.list.width, small.size_px, unit}
	if !p.wrap_stale && key == p.wrap_key {return}
	changed := p.wrap_stale || unit != p.wrap_key[2]
	p.wrap_key, p.wrap_stale = key, false
	for item, index in p.items {
		if item.row < 0 || item.part > 0 {continue}
		row := &p.rows[item.row]
		width, under, wraps := row_description_width(p, l, index)
		if wraps {
			changed = description_wrap(&row.wrap, &small, row.description, width) || changed
		} else if under {
			changed = description_one_line(&row.wrap, &small, row.description, width) || changed
		}
	}
	if changed {editor_tops_build(p)}
}

// Measures where every page line starts from the rows' wrapped descriptions. A conflict chain
// lists its rows one line each.
@(private)
editor_tops_build :: proc(p: ^Editor) {
	// Without room for them every line counts as one, as on a page never wrapped.
	if resize(&p.tops, len(p.items) + 1) != nil {clear(&p.tops); return}
	chained := editor_chained(p)
	top: f32
	for item, index in p.items {
		p.tops[index] = top
		top += 1
		if chained || item.row < 0 || item.part > 0 {continue}
		if count := p.rows[item.row].wrap.count; count > 1 {top += f32(count - 1) * p.wrap_key[2]}
	}
	p.tops[len(p.items)] = top
}

// The page offset, in lines, where page line `index` starts. Lines past the last count one each,
// and so does every line of the Colors board, which is measured in lines of its own.
@(private)
editor_item_top :: proc(p: ^Editor, index: int) -> f32 {
	n := len(p.items)
	if len(p.tops) != n + 1 || color_board_shown(p) || index <= 0 {return f32(index)}
	return index >= n ? p.tops[n] + f32(index - n) : p.tops[index]
}

// How many lines page line `index` takes up.
@(private)
editor_item_lines :: proc(p: ^Editor, index: int) -> f32 {
	return editor_item_top(p, index + 1) - editor_item_top(p, index)
}

// A page position, page line plus the fraction of it scrolled past, as an offset in lines.
@(private)
editor_position_offset :: proc(p: ^Editor, position: f32) -> f32 {
	index := int(math.floor(position))
	top := editor_item_top(p, index)
	return top + (position - f32(index)) * (editor_item_top(p, index + 1) - top)
}

// The page position at an offset in lines: the inverse of editor_position_offset.
@(private)
editor_offset_position :: proc(p: ^Editor, offset: f32) -> f32 {
	n := len(p.items)
	if len(p.tops) != n + 1 || color_board_shown(p) || offset <= 0 {return offset}
	if offset >= p.tops[n] {return f32(n) + offset - p.tops[n]}
	low, high := 0, n - 1
	for low < high {
		middle := (low + high + 1) / 2
		if p.tops[middle] <= offset {low = middle} else {high = middle - 1}
	}
	return f32(low) + (offset - p.tops[low]) / (p.tops[low + 1] - p.tops[low])
}

// How far the page is scrolled, as an offset in lines.
@(private)
editor_scroll_offset :: proc(p: ^Editor) -> f32 {
	return editor_position_offset(p, editor_scroll_lines(p))
}

// Where the row at page line `index` draws its description, and whether that cuts it short: past
// the line cap, ellipsized on one line, or faded out at the end of a table column. A row showing a
// note or an error in its place shows no description.
@(private)
editor_description_box :: proc(
	p: ^Editor, l: Editor_Layout, index: int, text: ^Text,
) -> (box: render.Rect, cut: bool) {
	row := &p.rows[p.items[index].row]
	if row.description == "" || row.process_field != .None {return}
	s := l.scale
	small := text_styled(text, .Detail)
	parts := editor_row_parts(p, l, index)
	r := parts.row
	x, baseline, width: f32
	lines := 1
	#partial switch row.kind {
	case .Profile_Add, .Process_Group:
		return
	case .Profile:
		column := profile_row_parts(.Profile, r, s).command
		x, width = column.x, max(1, column.width)
		baseline = r.y + r.height / 2 - small.line_height / 2 + small.ascent
	case .Opener:
		line := opener_line(row, r, &small, s)
		x, width = line.x, line.width
		_, baseline = stacked_baselines(r, text, &small, s)
	case .Motion_Context:
		buffer: [128]u8
		h := motion_header_layout(p, p.items[index].row, r, &small, s, buffer[:])
		x, width = h.x, h.limit
		_, baseline = stacked_baselines(r, text, &small, s)
	case .Theme_Strip:
		keyboard := index == p.selected && editor_focus(p) == .Control
		header, _, header_width := strip_header(editor_strip_rect(p, l, index), &small, keyboard, s)
		x, width = header.x + ITEM_INSET * s, header_width
		_, baseline = stacked_baselines(header, text, &small, s)
	case:
		if row.note != "" || (p.error_key == row.key && p.error_text != "") {return}
		x = row_text_x(row, r, s)
		width = max(1, parts.text_right - x)
		_, baseline = stacked_baselines(row_band(r, s), text, &small, s)
		if row.wrap.count > 1 {
			lines = row.wrap.count
			return {x, baseline - small.ascent, width, f32(lines) * small.line_height}, row.wrap.cut
		}
		if !row.wrap.cut {return}
	}
	shown := text_width(&small, row.description)
	// A column narrower than the ellipsis still draws the ellipsis.
	drawn := max(min(shown, width), text_width(&small, ELLIPSIS))
	return {x, baseline - small.ascent, drawn, small.line_height}, shown > width
}

// The full description of the row the pointer rests on while that row shows it cut short, for the
// window's tooltip; "" otherwise.
editor_description_tooltip :: proc(p: ^Editor) -> string {
	if p.hover_description < 0 || p.hover_description >= len(p.items) {return ""}
	item := p.items[p.hover_description]
	return item.row >= 0 ? p.rows[item.row].description : ""
}
