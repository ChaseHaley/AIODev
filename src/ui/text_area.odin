package ui

import "aio:font"
import "aio:markdown"
import "aio:render"
import "core:math"
import "core:strings"
import "core:unicode/utf8"

// A wrapped, multi-line plain-text editor for a short note such as a comment (D-100). The text and its
// caret, selection and undo live in a markdown.Edit_Buffer the host owns and edits with its keys; the
// area wraps that text, scrolls it inside the box, and answers where things are on screen.

// One visual line: the bytes from `start` to `end`. A line the text wraps keeps its trailing spaces and
// the next line starts where it ends; a line a '\n' (or "\r\n") ends stops before it.
Text_Area_Line :: struct {
	start, end: int,
}

// A text area's layout and scroll. Zero is an empty area; `text_area_reset` returns one to that when
// the host puts new text in the buffer, and `text_area_destroy` frees it.
Text_Area :: struct {
	lines:             [dynamic]Text_Area_Line,
	// What `lines` was wrapped for, so a frame with the same text, width and font wraps nothing.
	wrapped:           bool,
	wrapped_revision:  u64,
	wrapped_width:     f32,
	wrapped_size:      f32,
	wrapped_family:    font.Family,
	// How far the text is scrolled up inside the box, in pixels.
	scroll:            f32,
	// Where a run of Up and Down keeps the caret across shorter lines, from the text's left edge; it
	// holds only while the caret is where the last such move left it.
	goal_x:            f32,
	goal_caret:        int,
	goal_revision:     u64,
	goal_set:          bool,
	// The caret and box the scroll last made visible. Scrolling by hand sticks until one of them changes.
	revealed:          bool,
	revealed_caret:    int,
	revealed_revision: u64,
	revealed_height:   f32,
	revealed_width:    f32,
	// A pointer press in the box holds until the host calls `text_area_release`.
	dragging:          bool,
	caret:             Field_Caret,
}

// A text area, its buffer and the box they fill, as draw and hit tests read it. The box is `rect`, as
// tall as `text_area_height` says; `text` carries the window scale in its size, like Field_Box's.
Text_Area_Box :: struct {
	area:   ^Text_Area,
	buffer: ^markdown.Edit_Buffer,
	text:   ^Text,
	rect:   render.Rect,
	scale:  f32,
}

text_area_destroy :: proc(a: ^Text_Area) {
	delete(a.lines)
	a^ = {}
}

// Forgets the layout and the scroll, for when the buffer holds a different text. Keeps the allocation.
text_area_reset :: proc(a: ^Text_Area) {
	lines := a.lines
	clear(&lines)
	a^ = {lines = lines}
}

// The advance of one rune as the area sets it: a tab is CHANGES_TAB_COLUMNS spaces wide, as in the diff's
// code, and a rune with no glyph takes no room, as `draw_text` skips it. `space` is `code_space` of `t`.
@(private = "file")
area_advance :: proc(t: ^Text, r: rune, space: f32) -> f32 {
	_, advance, _ := code_rune(t, r, space)
	return advance
}

// The width of `s` as the area draws it: the text between tabs as the font sets it, and each tab as the
// columns it spans.
@(private = "file")
area_width :: proc(t: ^Text, s: string) -> f32 {
	width: f32
	rest := s
	for rest != "" {
		end := strings.index_byte(rest, '\t')
		if end < 0 {return width + text_width(t, rest)}
		width += text_width(t, rest[:end]) + CHANGES_TAB_COLUMNS * code_space(t)
		rest = rest[end + 1:]
	}
	return width
}

// Draws one row of the area's text from `x`, leaving the room of each tab it holds empty.
@(private = "file")
area_row_draw :: proc(
	t: ^Text, list: ^render.Draw_List, row: string, x, baseline: f32, color: render.Color,
) -> render.Build_Status {
	x, rest := x, row
	for rest != "" {
		end := strings.index_byte(rest, '\t')
		run := end < 0 ? rest : rest[:end]
		if run != "" {
			if result := draw_text(t, list, run, x, baseline, color); result != .Ok {return result}
			x += text_width(t, run)
		}
		if end < 0 {break}
		x += CHANGES_TAB_COLUMNS * code_space(t)
		rest = rest[end + 1:]
	}
	return .Ok
}

// Wraps the buffer's text to `width` pixels, unless that was already done for this text, width and font.
// Lines break at '\n', after the last space that lets the line fit, and inside a word wider than a line.
// Spaces hang past the width instead of breaking a line, so they stay at their line's end.
@(private = "file")
area_wrap :: proc(a: ^Text_Area, b: ^markdown.Edit_Buffer, t: ^Text, width: f32) {
	space := code_space(t)
	if a.wrapped && a.wrapped_revision == b.revision && a.wrapped_width == width &&
	   a.wrapped_size == t.size_px && a.wrapped_family == t.family {
		return
	}
	a.wrapped, a.wrapped_revision, a.wrapped_width = true, b.revision, width
	a.wrapped_size, a.wrapped_family = t.size_px, t.family
	clear(&a.lines)
	s := markdown.edit_string(b)
	start, last_break := 0, -1
	pen, pen_at_break: f32
	word := false
	for offset := 0; offset < len(s); {
		r, size := utf8.decode_rune_in_string(s[offset:])
		next := offset + size
		if r == '\n' || (r == '\r' && next < len(s) && s[next] == '\n') {
			if r == '\r' {next += 1}
			append(&a.lines, Text_Area_Line{start, offset})
			start, last_break, pen, word = next, -1, 0, false
			offset = next
			continue
		}
		advance := area_advance(t, r, space)
		if r == ' ' || r == '\t' {
			pen += advance
			// A space may break the line only after a word; a line of leading spaces stays whole.
			if word {last_break, pen_at_break = next, pen}
			offset = next
			continue
		}
		if pen + advance > width && offset > start {
			if last_break > start {
				append(&a.lines, Text_Area_Line{start, last_break})
				start = last_break
				pen -= pen_at_break
			} else {
				append(&a.lines, Text_Area_Line{start, offset})
				start, pen = offset, 0
			}
			last_break = -1
		}
		pen += advance
		word = true
		offset = next
	}
	append(&a.lines, Text_Area_Line{start, len(s)})
}

// The padding above and below the lines: what centres one line in a standard field, so a one-line area
// is as tall as a Text_Field.
@(private = "file")
area_pad :: proc(t: ^Text, scale: f32) -> f32 {
	return max(SPACE_1 * scale, (HEIGHT_STANDARD * scale - t.line_height) / 2)
}

// Where the text sits in the box, and the Body text it is drawn with.
@(private = "file")
area_frame :: proc(box: Text_Area_Box) -> (frame: render.Rect, t: Text) {
	t = text_styled(box.text, .Body)
	inset, pad := CONTROL_INSET * box.scale, area_pad(&t, box.scale)
	frame = {
		box.rect.x + inset,
		box.rect.y + pad,
		max(1, box.rect.width - 2 * inset),
		max(t.line_height, box.rect.height - 2 * pad),
	}
	return
}

// The box's lines wrapped for it, which the other queries read.
@(private = "file")
area_laid_out :: proc(box: Text_Area_Box) -> (frame: render.Rect, t: Text) {
	frame, t = area_frame(box)
	area_wrap(box.area, box.buffer, &t, frame.width)
	return
}

// The visual lines of a `width` pixels wide box, wrapped if the text or width changed since last asked.
@(require_results)
text_area_lines :: proc(
	a: ^Text_Area, b: ^markdown.Edit_Buffer, text: ^Text, width, scale: f32,
) -> []Text_Area_Line {
	t := text_styled(text, .Body)
	area_wrap(a, b, &t, max(1, width - 2 * CONTROL_INSET * scale))
	return a.lines[:]
}

// How tall the box is for `width` pixels of box: the text's lines, but no fewer than `min_lines` and no
// more than `max_lines`, past which the text scrolls inside the box.
@(require_results)
text_area_height :: proc(
	a: ^Text_Area, b: ^markdown.Edit_Buffer, text: ^Text, width, scale: f32, min_lines, max_lines: int,
) -> f32 {
	lines := text_area_lines(a, b, text, width, scale)
	t := text_styled(text, .Body)
	rows := clamp(len(lines), max(1, min_lines), max(1, min_lines, max_lines))
	return f32(rows) * t.line_height + 2 * area_pad(&t, scale)
}

// The row holding `offset`: the last line that starts at or before it, so the offset where a wrapped
// line ends is the start of the next line.
@(private = "file")
area_row :: proc(a: ^Text_Area, offset: int) -> int {
	low, high := 0, len(a.lines) - 1
	for low < high {
		mid := (low + high + 1) / 2
		if a.lines[mid].start <= offset {
			low = mid
		} else {
			high = mid - 1
		}
	}
	return low
}

// The offset in `row` nearest to `x` pixels from the text's left edge.
@(private = "file")
area_offset_in_row :: proc(a: ^Text_Area, b: ^markdown.Edit_Buffer, t: ^Text, row: int, x: f32) -> int {
	line := a.lines[row]
	s := markdown.edit_string(b)
	space := code_space(t)
	pen: f32
	for r, i in s[line.start:line.end] {
		advance := area_advance(t, r, space)
		if x < pen + advance / 2 {return line.start + i}
		pen += advance
	}
	// The end of a wrapped line is the start of the next one, so the caret stays before its last rune.
	if row + 1 < len(a.lines) && a.lines[row + 1].start == line.end && line.end > line.start {
		_, size := utf8.decode_last_rune_in_string(s[line.start:line.end])
		return line.end - size
	}
	return line.end
}

// How far `offset` is from the text's left edge on its row.
@(private = "file")
area_x_of :: proc(a: ^Text_Area, b: ^markdown.Edit_Buffer, t: ^Text, row, offset: int) -> f32 {
	return area_width(t, string(b.text[a.lines[row].start:offset]))
}

@(private = "file")
area_max_scroll :: proc(a: ^Text_Area, frame: render.Rect, t: ^Text) -> f32 {
	return max(0, f32(len(a.lines)) * t.line_height - frame.height)
}

// The offset nearest to a point inside the box.
@(require_results)
text_area_offset_at :: proc(box: Text_Area_Box, x, y: f32) -> int {
	frame, t := area_laid_out(box)
	a := box.area
	row := clamp(int(math.floor((y - frame.y + a.scroll) / t.line_height)), 0, len(a.lines) - 1)
	return area_offset_in_row(a, box.buffer, &t, row, x - frame.x)
}

// Where the caret draws for `offset`, in the window.
@(require_results)
text_area_caret_rect :: proc(box: Text_Area_Box, offset: int) -> render.Rect {
	frame, t := area_laid_out(box)
	a := box.area
	at := clamp(offset, 0, len(box.buffer.text))
	row := area_row(a, at)
	return {
		frame.x + area_x_of(a, box.buffer, &t, row, at),
		frame.y + f32(row) * t.line_height - a.scroll,
		max(1, box.scale),
		t.line_height,
	}
}

// Scrolls the text so the caret is in the box, once for each place the caret and the box have been in;
// the scroll then stays wherever the wheel leaves it.
text_area_reveal :: proc(box: Text_Area_Box) {
	frame, t := area_laid_out(box)
	a, b := box.area, box.buffer
	if !(a.revealed && a.revealed_caret == b.caret && a.revealed_revision == b.revision &&
		   a.revealed_height == frame.height && a.revealed_width == a.wrapped_width) {
		top := f32(area_row(a, b.caret)) * t.line_height
		if top < a.scroll {
			a.scroll = top
		} else if top + t.line_height > a.scroll + frame.height {
			a.scroll = top + t.line_height - frame.height
		}
		a.revealed, a.revealed_caret, a.revealed_revision = true, b.caret, b.revision
		a.revealed_height, a.revealed_width = frame.height, a.wrapped_width
	}
	a.scroll = clamp(a.scroll, 0, area_max_scroll(a, frame, &t))
}

// Scrolls by `delta` pixels down, as far as the text goes. False when nothing moved.
text_area_scroll :: proc(box: Text_Area_Box, delta: f32) -> bool {
	frame, t := area_laid_out(box)
	a := box.area
	was := a.scroll
	a.scroll = clamp(a.scroll + delta, 0, area_max_scroll(a, frame, &t))
	return a.scroll != was
}

// Up, Down, Page Up and Page Down: moves the caret `lines` lines (or `pages` boxes of lines) away,
// keeping its column across shorter lines. Past the first or last line it goes to the text's start or end.
text_area_vertical :: proc(box: Text_Area_Box, lines, pages: int, extend: bool) {
	frame, t := area_laid_out(box)
	a, b := box.area, box.buffer
	row := area_row(a, b.caret)
	x: f32
	if a.goal_set && a.goal_caret == b.caret && a.goal_revision == b.revision {
		x = a.goal_x
	} else {
		x = area_x_of(a, b, &t, row, b.caret)
	}
	page := max(1, int(math.round(frame.height / t.line_height)) - 1)
	target_row := row + lines + pages * page
	target: int
	switch {
	case target_row < 0:
		target = b.floor
	case target_row >= len(a.lines):
		target = len(b.text)
	case:
		target = area_offset_in_row(a, b, &t, target_row, x)
	}
	markdown.edit_move(b, target, extend)
	a.goal_x, a.goal_caret, a.goal_revision, a.goal_set = x, b.caret, b.revision, true
	text_area_reveal(box)
}

// A pointer press or drag at a point of the window moves the caret there, or extends the selection to
// it; a press starts a new selection unless `extend` is held. False for a move with no press before it.
text_area_pointer :: proc(box: Text_Area_Box, x, y: f32, pressed, extend: bool) -> bool {
	a := box.area
	if !pressed && !a.dragging {return false}
	markdown.edit_move(box.buffer, text_area_offset_at(box, x, y), pressed ? extend : true)
	if pressed {a.dragging = true}
	text_area_reveal(box)
	return true
}

// Ends a pointer drag in the box, returning whether one was under way.
text_area_release :: proc(a: ^Text_Area) -> bool {
	dragging := a.dragging
	a.dragging = false
	return dragging
}

// Draws the box: its field look, the selection, the text or the placeholder, and the caret.
text_area_draw :: proc(
	box: Text_Area_Box, list: ^render.Draw_List, theme: Theme, focused: bool, placeholder: string,
) -> render.Build_Status {
	text_area_reveal(box)
	frame, t := area_laid_out(box)
	a, b := box.area, box.buffer
	box_draw(list, box.rect, theme, focused, box.scale)
	scope, opened := clip_scope_open(list, box.rect, RADIUS_CONTROL * box.scale)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := markdown.edit_string(b)
	lh := t.line_height
	first := max(0, int(math.floor(a.scroll / lh)))
	last := min(len(a.lines) - 1, int(math.ceil((a.scroll + frame.height) / lh)) - 1)
	low, high := markdown.edit_selection(b)
	space := focused && low != high ? area_advance(&t, ' ', code_space(&t)) : 0
	for row in first ..= last {
		line := a.lines[row]
		top := frame.y + f32(row) * lh - a.scroll
		next := row + 1 < len(a.lines) ? a.lines[row + 1].start : line.end
		hard := next > line.end
		if focused && low != high && high > line.start && low < (hard ? next : line.end) {
			left := frame.x + area_width(&t, s[line.start:clamp(low, line.start, line.end)])
			right := frame.x + area_width(&t, s[line.start:clamp(high, line.start, line.end)])
			if hard && high >= next {right += space}
			right = min(right, frame.x + frame.width)
			draw_rect(list, {rect = {left, top, right - left, lh}, color = theme.focus})
		}
	}
	head: render.Rect
	if focused {
		target := text_area_caret_rect(box, b.caret)
		head = field_caret_pose(&a.caret, t.carets, {frame.x, frame.y - a.scroll}, target)
		field_caret_body(&a.caret, list, theme.accent)
	}
	if len(s) == 0 {
		if result := draw_text(&t, list, placeholder, frame.x, frame.y + t.ascent, theme.muted, frame.width);
		   result != .Ok {
			return result
		}
	} else {
		for row in first ..= last {
			line := a.lines[row]
			baseline := frame.y + f32(row) * lh - a.scroll + t.ascent
			if result := area_row_draw(&t, list, s[line.start:line.end], frame.x, baseline, theme.text);
			   result != .Ok {
				return result
			}
		}
	}
	if focused {draw_rect(list, {rect = head, color = theme.accent})}
	return .Ok
}

// Wraps the selection in `before` and `after`, as a formatting button does; with nothing selected it
// wraps `placeholder`. The text between them ends up selected, so the next press or typing replaces it.
// One undo step. False when the buffer has no room, leaving it unchanged.
@(require_results)
text_area_wrap_selection :: proc(b: ^markdown.Edit_Buffer, before, after, placeholder: string) -> bool {
	from, to := markdown.edit_selection(b)
	inner := to > from ? string(b.text[from:to]) : placeholder
	joined, err := strings.concatenate({before, inner, after}, context.temp_allocator)
	if err != nil || !markdown.edit_replace(b, from, to, joined) {return false}
	b.anchor = from + len(before)
	b.caret = b.anchor + len(inner)
	return true
}

// Puts a fenced block, ```lang, `body` and the closing fence, at the caret on lines of its own, in place
// of the selection, and selects the body. One undo step. False when the buffer has no room.
@(require_results)
text_area_insert_block :: proc(b: ^markdown.Edit_Buffer, lang, body: string) -> bool {
	from, to := markdown.edit_selection(b)
	lead := from > b.floor && b.text[from - 1] != '\n' ? b.newline : ""
	head, head_error := strings.concatenate({lead, "```", lang, b.newline}, context.temp_allocator)
	block, block_error := strings.concatenate({head, body, b.newline, "```", b.newline}, context.temp_allocator)
	if head_error != nil || block_error != nil || !markdown.edit_replace(b, from, to, block) {return false}
	b.anchor = from + len(head)
	b.caret = b.anchor + len(body)
	return true
}
