package ui

import "aio:render"
import tr "aio:turns"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

@(private = "file")
CHANGES_TAB_COLUMNS :: 4
@(private = "file")
CHANGES_STATUS_WIDTH :: f32(16)

@(private)
file_body_height :: proc(rows: ^Changes_Rows, f: ^tr.Diff_File) -> int {
	if f.binary || len(f.hunks) == 0 {return rows.note}
	h := 0
	for &hunk in f.hunks {h += rows.hunk + len(hunk.lines) * rows.line}
	return h
}

// The file that contains row `y` of the stream: its index, the file count past the last one, or -1 for
// a negative `y` and for no files.
@(private)
changes_file_at :: proc(rows: ^Changes_Rows, y: int) -> int {
	files := len(rows.tops) - 1
	if files <= 0 || y < 0 {return -1}
	if y >= rows.tops[files] {return files}
	low, high := 0, files - 1
	for low < high {
		mid := (low + high + 1) / 2
		if rows.tops[mid] <= y {low = mid} else {high = mid - 1}
	}
	return low
}

// "+N −M" in the added and removed colours, ending at `right`. Returns where it starts, which is
// `right` when there is nothing to show.
@(private)
stats_draw :: proc(
	list: ^render.Draw_List,
	t: ^Text,
	theme: Theme,
	right, baseline: f32,
	added, removed: int,
	scale: f32,
) -> (
	left: f32,
	status: render.Build_Status,
) {
	if added == 0 && removed == 0 {return right, .Ok}
	plus_buf, minus_buf: [24]u8
	plus := fmt.bprintf(plus_buf[:], "+%d", added)
	minus := fmt.bprintf(minus_buf[:], "−%d", removed)
	minus_x := right - text_width(t, minus)
	plus_x := minus_x - SPACE_1 * scale - text_width(t, plus)
	if status = draw_text(t, list, plus, plus_x, baseline, theme.success); status != .Ok {return}
	status = draw_text(t, list, minus, minus_x, baseline, theme.error)
	return plus_x, status
}

@(private = "file")
tab_expand :: proc(buf: []u8, s: string) -> string {
	if strings.index_byte(s, '\t') < 0 {return s}
	n := 0
	for r in s {
		if r == '\t' {
			if n + CHANGES_TAB_COLUMNS > len(buf) {break}
			for _ in 0 ..< CHANGES_TAB_COLUMNS {
				buf[n] = ' '
				n += 1
			}
			continue
		}
		encoded, size := utf8.encode_rune(r)
		if n + size > len(buf) {break}
		copy(buf[n:], encoded[:size])
		n += size
	}
	return string(buf[:n])
}

@(private)
CHANGES_CLIP_BYTES :: 512

// The start of `s` of at most `limit` bytes, cut on a rune boundary. Long titles and paths only ever show
// their start, so drawing never measures the rest.
clip_bytes :: proc(s: string, limit: int) -> string {
	if len(s) <= limit {return s}
	end := limit
	for end > 0 && (s[end] & 0xC0) == 0x80 {end -= 1}
	return s[:end]
}

// The leading runes of `s` that can reach `width` in a monospace font whose glyphs advance `advance`, plus
// two, so the fade still sees the overflow. A minified line is therefore never walked whole.
mono_prefix :: proc(s: string, width, advance: f32) -> string {
	if advance <= 0 {return clip_bytes(s, CHANGES_CLIP_BYTES)}
	limit := int(max(0, width) / advance) + 2
	count := 0
	for _, offset in s {
		if count == limit {return s[:offset]}
		count += 1
	}
	return s
}

// The text of a file header: the path, or old and new for a rename or copy.
@(private = "file")
file_label :: proc(buf: []u8, f: ^tr.Diff_File) -> string {
	if (f.status == .Renamed || f.status == .Copied) && f.old_path != f.new_path && f.old_path != "" {
		return fmt.bprintf(buf, "%s → %s", f.old_path, f.new_path)
	}
	if f.status == .Deleted || f.new_path == "" {return clip_bytes(f.old_path, len(buf))}
	return clip_bytes(f.new_path, len(buf))
}

@(private = "file")
status_mark :: proc(status: tr.File_Status, theme: Theme) -> (mark: string, color: render.Color) {
	switch status {
	case .Modified:
		return "M", theme.warning
	case .Added:
		return "A", theme.success
	case .Deleted:
		return "D", theme.error
	case .Renamed:
		return "R", theme.info
	case .Copied:
		return "C", theme.info
	}
	return "M", theme.warning
}

@(private = "file")
Diff_Paint :: struct {
	list:                 ^render.Draw_List,
	mono, small, strong, body: ^Text,
	theme:                Theme,
	scale:                f32,
	// The file card's horizontal extent; rows fill it.
	card_x, card_width:   f32,
	// The visible part of the diff area, to skip rows outside it.
	top, bottom:          f32,
	digit:                f32,
	// Where the line numbers, the sign and the text start in the current file.
	old_x, new_x, sign_x, text_x, column: f32,
}

@(private = "file")
digit_count :: proc(n: int) -> int {
	count := 1
	for v := n; v >= 10; v /= 10 {count += 1}
	return count
}

@(private = "file")
paint_gutter :: proc(p: ^Diff_Paint, f: ^tr.Diff_File) {
	biggest := 0
	if len(f.hunks) > 0 {
		last := f.hunks[len(f.hunks) - 1]
		biggest = int(max(last.old_start + last.old_count, last.new_start + last.new_count))
	}
	s := p.scale
	p.column = f32(digit_count(biggest)) * p.digit
	p.old_x = p.card_x + SPACE_2 * s
	p.new_x = p.old_x + p.column + SPACE_2 * s
	p.sign_x = p.new_x + p.column + SPACE_2 * s
	p.text_x = p.sign_x + p.digit + SPACE_1 * s
}

@(private = "file")
number_draw :: proc(p: ^Diff_Paint, n: i32, x, baseline: f32) -> render.Build_Status {
	if n <= 0 {return .Ok}
	buf: [16]u8
	label := strconv.write_int(buf[:], i64(n), 10)
	return draw_text(p.mono, p.list, label, x + p.column - f32(len(label)) * p.digit, baseline, p.theme.faint)
}

@(private = "file")
paint_line :: proc(p: ^Diff_Paint, line: ^tr.Diff_Line, y, height: f32) -> render.Build_Status {
	t := p.theme
	baseline := baseline_in(y, height, p.mono)
	row := render.Rect{p.card_x, y, p.card_width, height}
	switch line.kind {
	case .Added:
		draw_rect(p.list, {rect = row, color = t.diff_added})
	case .Removed:
		draw_rect(p.list, {rect = row, color = t.diff_removed})
	case .Context, .No_Newline:
	}
	if line.kind == .No_Newline {
		return draw_fading_text(
			p.mono, p.list, "No newline at end of file", p.text_x, baseline, t.faint,
			p.card_x + p.card_width - p.text_x,
		)
	}
	if line.kind != .Added {
		if r := number_draw(p, line.old_line, p.old_x, baseline); r != .Ok {return r}
	}
	if line.kind != .Removed {
		if r := number_draw(p, line.new_line, p.new_x, baseline); r != .Ok {return r}
	}
	ink := t.muted
	switch line.kind {
	case .Added:
		ink = t.success
		if r := draw_text(p.mono, p.list, "+", p.sign_x, baseline, ink); r != .Ok {return r}
		ink = t.text
	case .Removed:
		ink = t.error
		if r := draw_text(p.mono, p.list, "-", p.sign_x, baseline, ink); r != .Ok {return r}
		ink = t.text
	case .Context, .No_Newline:
	}
	buf: [1024]u8
	width := p.card_x + p.card_width - p.text_x
	text := tab_expand(buf[:], mono_prefix(line.text, width, p.digit))
	return draw_fading_text(p.mono, p.list, text, p.text_x, baseline, ink, width)
}

@(private = "file")
paint_hunk :: proc(p: ^Diff_Paint, rows: ^Changes_Rows, h: ^tr.Hunk, y: f32) -> render.Build_Status {
	t := p.theme
	header := render.Rect{p.card_x, y, p.card_width, f32(rows.hunk)}
	draw_rect(p.list, {rect = header, color = t.code_background})
	buf: [64]u8
	label := fmt.bprintf(buf[:], "@@ -%d,%d +%d,%d @@", h.old_start, h.old_count, h.new_start, h.new_count)
	baseline := baseline_in(y, f32(rows.hunk), p.mono)
	room := p.card_width - 2 * SPACE_2 * p.scale
	x := p.card_x + SPACE_2 * p.scale
	if r := draw_fading_text(p.mono, p.list, label, x, baseline, t.muted, room); r != .Ok {return r}
	if h.section != "" {
		after := text_width(p.mono, label) + SPACE_2 * p.scale
		section := mono_prefix(h.section, room - after, p.digit)
		if r := draw_fading_text(p.mono, p.list, section, x + after, baseline, t.faint, room - after);
		   r != .Ok {return r}
	}
	top := y + f32(rows.hunk)
	height := f32(rows.line)
	count := len(h.lines)
	first := max(0, int(math.floor((p.top - top) / height)))
	last := min(count - 1, int(math.floor((p.bottom - top) / height)))
	for i in first ..= last {
		if r := paint_line(p, &h.lines[i], top + f32(i) * height, height); r != .Ok {return r}
	}
	return .Ok
}

@(private = "file")
paint_file :: proc(
	p: ^Diff_Paint,
	rows: ^Changes_Rows,
	view: ^Changes_View,
	state: ^Changes_State,
	i: int,
	y: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	t, s := p.theme, p.scale
	f := &view.files[i]
	head := render.Rect{p.card_x, y, p.card_width, f32(rows.header)}
	collapsed := changes_collapsed(view, i)
	hover, press := changes_lit(state, {.File_Header, i})
	draw_rect(p.list, {rect = head, color = t.surface, radius = RADIUS_CONTROL * s})
	face, ink, err := button_draw(
		p.list,
		t,
		{rect = head, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat},
		s,
		pointer,
	)
	if err != .None {return .Ok}
	x := face.x + CONTROL_INSET * s
	icon := render.Rect{x, face.y, ICON_INDICATOR * s, face.height}
	icon_draw(p.list, collapsed ? .Chevron_Right : .Chevron_Down, icon, ink, ICON_INDICATOR, s)
	x += ICON_INDICATOR * s + SPACE_1 * s
	mark, color := status_mark(f.status, t)
	slot := CHANGES_STATUS_WIDTH * s
	letter := x + (slot - text_width(p.strong, mark)) / 2
	if r := draw_text(p.strong, p.list, mark, letter, baseline_in(face.y, face.height, p.strong), color);
	   r != .Ok {return r}
	x += slot + SPACE_1 * s

	small_baseline := baseline_in(face.y, face.height, p.small)
	right := face.x + face.width - CONTROL_INSET * s
	if !f.binary {
		left, r := stats_draw(p.list, p.small, t, right, small_baseline, f.added, f.removed, s)
		if r != .Ok {return r}
		right = left - SPACE_2 * s
	}
	forms := changes_badge_forms(view, i, p.small, right - x, s)
	labels := CHANGES_BADGE_LABELS
	icons := [Changes_Badge]Icon {
		.Marked    = .Warning,
		.Ambiguous = .Info,
	}
	for badge in Changes_Badge {
		switch forms[badge] {
		case .Hidden:
		case .Text:
			width := text_width(p.small, labels[badge])
			if r := draw_text(p.small, p.list, labels[badge], right - width, small_baseline, t.warning); r != .Ok {
				return r
			}
			right -= width + SPACE_2 * s
		case .Icon:
			size := ICON_INDICATOR * s
			icon_draw(p.list, icons[badge], {right - size, face.y, size, face.height}, t.warning, ICON_INDICATOR, s)
			right -= size + SPACE_2 * s
		}
	}
	label_buf: [512]u8
	body := p.body
	if r := draw_fading_text(
		body, p.list, file_label(label_buf[:], f), x, baseline_in(face.y, face.height, body), t.text,
		right - x,
	); r != .Ok {return r}
	if collapsed {return .Ok}

	top := y + f32(rows.header)
	if f.binary || len(f.hunks) == 0 {
		note := f.binary ? "Binary file" : "No content changes"
		return draw_text(
			p.small, p.list, note, p.card_x + CONTROL_INSET * s, baseline_in(top, f32(rows.note), p.small),
			t.muted,
		)
	}
	paint_gutter(p, f)
	for &hunk in f.hunks {
		height := f32(rows.hunk + len(hunk.lines) * rows.line)
		if top + height > p.top {
			if top >= p.bottom {break}
			if r := paint_hunk(p, rows, &hunk, top); r != .Ok {return r}
		}
		top += height
	}
	return .Ok
}

@(private)
diff_draw :: proc(
	list: ^render.Draw_List,
	text, mono: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	rows := &state.rows
	if !rows.valid || len(rows.tops) != len(view.files) + 1 || g.diff.width <= 0 {return .Ok}
	scope, opened := clip_scope_open(list, g.diff)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := g.scale
	small := text_styled(text, .Detail)
	strong := text_styled(text, .Strong)
	pad := SPACE_2 * s
	p := Diff_Paint {
		list       = list,
		mono       = mono,
		small      = &small,
		strong     = &strong,
		body       = text,
		theme      = theme,
		scale      = s,
		card_x     = g.diff.x + pad,
		card_width = max(0, g.diff.width - 2 * pad),
		top        = g.diff.y,
		bottom     = g.diff.y + g.diff.height,
		digit      = text_width(mono, "0"),
	}
	scroll := state.diff_scroll
	origin := g.diff.y - f32(scroll)
	files := len(view.files)
	first := max(0, changes_file_at(rows, scroll))
	for i := first; i < files && f32(rows.tops[i]) + origin < p.bottom; i += 1 {
		if r := paint_file(&p, rows, view, state, i, origin + f32(rows.tops[i]), pointer); r != .Ok {return r}
	}
	if view.omitted > 0 {
		y := origin + f32(rows.tops[files])
		if y < p.bottom && y + f32(rows.footer) > p.top {
			buf: [64]u8
			noun := view.omitted == 1 ? "file" : "files"
			label := fmt.bprintf(buf[:], "%d untracked %s not shown", view.omitted, noun)
			return draw_text(
				&small, list, label, p.card_x + CONTROL_INSET * s, baseline_in(y, f32(rows.footer), &small),
				theme.muted,
			)
		}
	}
	return .Ok
}
