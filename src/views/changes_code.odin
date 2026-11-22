package views

import "cosmos:font"
import "cosmos:render"
import "aio:syntax"
import tr "aio:turns"
import "core:math"
import "core:unicode/utf8"
import "cosmos:ui"

// Where a diff row's number, sign and text start. A unified row has two number columns, old and new; a
// side-by-side cell has one, and `new_x` is `old_x` there. One proc places them for painting, hit testing
// and the text selection, so a click lands on the character it is drawn over.
Code_Column :: struct {
	old_x, new_x, sign_x, text_x: f32,
	// The room for text, from `text_x` to the cell's right edge.
	width:                        f32,
	// How far the file's text is scrolled left, in pixels: a multiple of a digit's advance. Only
	// changes_line_code sets it.
	scroll:                       f32,
}

// The column of a row or cell `cell` wide, whose number columns are `number_width` wide and whose digits
// advance `digit`.
code_column :: proc(cell: render.Rect, number_width, digit, scale: f32, two_numbers: bool) -> Code_Column {
	c: Code_Column
	c.old_x = cell.x + ui.SPACE_2 * scale
	c.new_x = two_numbers ? c.old_x + number_width + ui.SPACE_2 * scale : c.old_x
	c.sign_x = c.new_x + number_width + ui.SPACE_2 * scale
	c.text_x = c.sign_x + digit + ui.SPACE_1 * scale
	c.width = cell.x + cell.width - c.text_x
	return c
}

// The width of a file's number columns: room for its biggest line number.
@(private)
code_number_width :: proc(f: ^tr.Diff_File, digit: f32) -> f32 {
	biggest := 0
	if len(f.hunks) > 0 {
		last := f.hunks[len(f.hunks) - 1]
		biggest = int(max(last.old_start + last.old_count, last.new_start + last.new_count))
	}
	return f32(digit_count(biggest)) * digit
}

@(private)
digit_count :: proc(n: int) -> int {
	count := 1
	for v := n; v >= 10; v /= 10 {count += 1}
	return count
}

// What a code line's layout reads of the font, found once per paint or hit test. `cell` is how far a digit
// advances, the unit the text scrolls by; `mono` says every printable ASCII rune advances that far, which
// lets a walk count such runes by byte instead of looking each one up.
Code_Font :: struct {
	space, cell: f32,
	mono:        bool,
}

@(private = "file")
code_advance :: proc(t: ^ui.Text, r: rune) -> f32 {
	if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r); found {
		return font.glyph_advance(t.fonts, g, t.size_px)
	}
	return 0
}

code_font :: proc(t: ^ui.Text) -> Code_Font {
	f := Code_Font {
		space = ui.code_space(t),
		cell  = code_advance(t, '0'),
	}
	f.mono = f.cell > 0
	for r in ([?]rune{' ', 'W', 'i', '.', 'm', '~'}) {
		if code_advance(t, r) != f.cell {f.mono = false}
	}
	return f
}

// How close to a column's edge a rune's pen may be and still count as on it; float sums of advances drift
// by far less.
@(private)
CODE_EDGE :: f32(0.01)

// Where a code line's text first reaches `target` from its start: the byte offset of the first rune that
// starts at or past it, and the pen there. A line that ends first returns its length. Printable ASCII is
// counted by byte in a monospace font, so a line of any length costs a byte scan, not a lookup per rune.
@(private)
code_seek :: proc(t: ^ui.Text, f: Code_Font, s: string, target: f32) -> (offset: int, pen: f32) {
	cells: int
	extra: f32
	for offset < len(s) {
		pen = f32(cells) * f.cell + extra
		if pen >= target - CODE_EDGE {return}
		if b := s[offset]; f.mono && b >= 0x20 && b < 0x7F {
			cells += 1
			offset += 1
			continue
		}
		r, size := utf8.decode_rune_in_string(s[offset:])
		_, advance, _ := ui.code_rune(t, r, f.space)
		extra += advance
		offset += size
	}
	return len(s), f32(cells) * f.cell + extra
}

// How wide a code line's text is.
code_width :: proc(t: ^ui.Text, f: Code_Font, s: string) -> f32 {
	_, pen := code_seek(t, f, s, max(f32))
	return pen
}

// The byte length of the start of `s` that fits `room`, at least one rune: where a wrapped code line breaks.
// Printable ASCII is counted by byte in a monospace font, as code_seek does, so a long line is a byte scan.
code_fit :: proc(t: ^ui.Text, f: Code_Font, s: string, room: f32) -> int {
	limit := room + CODE_EDGE
	cells: int
	extra: f32
	for offset := 0; offset < len(s); {
		if b := s[offset]; f.mono && b >= 0x20 && b < 0x7F {
			if offset > 0 && f32(cells + 1) * f.cell + extra > limit {return offset}
			cells += 1
			offset += 1
			continue
		}
		r, size := utf8.decode_rune_in_string(s[offset:])
		_, advance, _ := ui.code_rune(t, r, f.space)
		if offset > 0 && f32(cells) * f.cell + extra + advance > limit {return offset}
		extra += advance
		offset += size
	}
	return len(s)
}

// Whether `r` joins the rune before it into one character: a combining mark, a variation selector or a zero
// width joiner. A press never lands between such a rune and its base.
@(private = "file")
code_joins :: proc(r: rune) -> bool {
	switch {
	case 0x300 <= r && r <= 0x36F,
	     0x1AB0 <= r && r <= 0x1AFF,
	     0x1DC0 <= r && r <= 0x1DFF,
	     0x20D0 <= r && r <= 0x20FF,
	     0xFE00 <= r && r <= 0xFE0F,
	     0xFE20 <= r && r <= 0xFE2F,
	     r == 0x200D:
		return true
	}
	return false
}

// The byte offset of the boundary nearest `x`, measured from where the visible text starts, in a code line
// `s` drawn in `t` with `width` of room, scrolled `scroll` pixels. It sees what the painter draws: the runes
// that start before `width`, so a point past them is the end of the visible text, and one before the first
// visible rune is that rune's start. A rune that joins the one before it is no boundary of its own.
code_offset_at :: proc(t: ^ui.Text, s: string, width, x: f32, scroll: f32 = 0) -> int {
	f := code_font(t)
	offset, pen := code_seek(t, f, s, scroll)
	for offset < len(s) {
		if pen - scroll >= width {return offset}
		r, size := utf8.decode_rune_in_string(s[offset:])
		_, advance, _ := ui.code_rune(t, r, f.space)
		if !code_joins(r) && x < pen - scroll + advance / 2 {return offset}
		pen += advance
		offset += size
	}
	return len(s)
}

// Where the boundary at byte `offset` of `s` is, measured from where the visible text starts: the inverse of
// code_offset_at, with the same visible text. An offset scrolled out of sight is at an edge of it.
code_x_of :: proc(t: ^ui.Text, s: string, width: f32, offset: int, scroll: f32 = 0) -> f32 {
	return clamp(code_width(t, code_font(t), s[:clamp(offset, 0, len(s))]) - scroll, 0, width)
}

// A byte range of a code line drawn apart from the rest: a tint behind it, a line under it and one through
// it, and the selected inks. A colour with no alpha draws nothing. Runs are sorted and do not overlap.
Code_Run :: struct {
	start, end:              int,
	tint, underline, strike: render.Color,
	selected, changed:       bool,
}

// One line of code to draw. `spans` and `runs` are byte offsets into the line, and `text` is the line from
// byte `base` on (a whole line has base 0; a row of a wrapped block starts mid-line); text outside the spans
// takes ink `plain`. Runs with their own background take `selected_inks` or `changed_inks` when set.
// The text starts at `x`, scrolled left by `scroll` pixels, and shows the
// runes that fit whole in `width`; the tints and lines fill the row `top` and `height` give, from `x` to the
// room's end.
Code_Line :: struct {
	text:                  string,
	base:                  int,
	spans:                 []syntax.Span,
	runs:                  []Code_Run,
	font:                  Code_Font,
	x, width, scroll:      f32,
	top, height, baseline: f32,
	scale:                 f32,
	inks, selected_inks, changed_inks: ^[CHANGES_INKS]render.Color,
	plain:                 int,
}

// Draws the end of a run: its tint behind the glyphs, then the lines under and through them.
@(private = "file")
code_run_draw :: proc(list: ^render.Draw_List, line: Code_Line, run: Code_Run, x0, end: f32) {
	x1 := min(end, line.x + line.width)
	if x1 <= x0 {return}
	thickness := max(1, math.round(1.5 * line.scale))
	if run.tint.a > 0 {
		ui.draw_rect(list, {rect = {x0, line.top, x1 - x0, line.height}, color = run.tint})
	}
	if run.underline.a > 0 {
		bar := render.Rect{x0, line.top + line.height - thickness, x1 - x0, thickness}
		ui.draw_rect(list, {rect = bar, color = run.underline})
	}
	if run.strike.a > 0 {
		middle := math.round(line.top + (line.height - thickness) / 2)
		ui.draw_rect(list, {rect = {x0, middle, x1 - x0, thickness}, color = run.strike})
	}
}

// Draws a code line from `line.x`: the runes from the one `line.scroll` reaches that fit whole before the
// room ends, each coloured by the span it is in. Spans come from the whole file, which a clean or smudge
// filter can make differ from the diff text, so they are only read at offsets inside the text: one reaching
// past the end colours what is inside, and an empty or out-of-order one is skipped. A run that goes on past
// the room fills what is left of it.
code_line_draw :: proc(list: ^render.Draw_List, t: ^ui.Text, line: Code_Line) -> render.Build_Status {
	if line.width <= 0 {return .Ok}
	palette := CHANGES_SYNTAX_PALETTE
	f := line.font
	right := line.x + line.width
	offset, pen := code_seek(t, f, line.text, line.scroll)
	x := line.x + pen - line.scroll
	next, run_at := 0, 0
	open: bool
	run_x: f32
	for offset < len(line.text) {
		r, size := utf8.decode_rune_in_string(line.text[offset:])
		g, advance, drawn := ui.code_rune(t, r, f.space)
		at := line.base + offset
		for run_at < len(line.runs) && line.runs[run_at].end <= at {
			if open {code_run_draw(list, line, line.runs[run_at], run_x, x)}
			open = false
			run_at += 1
		}
		if x + advance > right + CODE_EDGE {
			if !open && run_at < len(line.runs) && line.runs[run_at].start <= at {open, run_x = true, x}
			if open {x = right}
			break
		}
		if !open && run_at < len(line.runs) && line.runs[run_at].start <= at {
			open, run_x = true, x
		}
		for next < len(line.spans) && int(line.spans[next].end) <= at {next += 1}
		inks := line.inks
		if open {
			if line.runs[run_at].selected && line.selected_inks != nil {
				inks = line.selected_inks
			} else if line.runs[run_at].changed && line.changed_inks != nil {
				inks = line.changed_inks
			}
		}
		c := inks[line.plain]
		if next < len(line.spans) && int(line.spans[next].start) <= at {
			index := palette[line.spans[next].kind]
			c = inks[index >= 0 ? index : CHANGES_INK_TEXT]
		}
		if drawn {
			if result := ui.draw_glyph(t, list, g, x, line.baseline, c); result != .Ok {return result}
		}
		x += advance
		offset += size
	}
	if open {code_run_draw(list, line, line.runs[run_at], run_x, x)}
	return .Ok
}

// Draws `s` in one colour with its start at `origin`, showing the runes that fit whole between `left` and
// `right`. A line of plain code text that scrolls: a hunk's header and the "no newline" marker.
code_text_draw :: proc(
	list: ^render.Draw_List, t: ^ui.Text, f: Code_Font, s: string, origin, left, right, baseline: f32,
	color: render.Color,
) -> render.Build_Status {
	offset, pen := code_seek(t, f, s, left - origin)
	x := origin + pen
	for offset < len(s) {
		r, size := utf8.decode_rune_in_string(s[offset:])
		g, advance, drawn := ui.code_rune(t, r, f.space)
		if x + advance > right + CODE_EDGE {break}
		if drawn {
			if result := ui.draw_glyph(t, list, g, x, baseline, color); result != .Ok {return result}
		}
		x += advance
		offset += size
	}
	return .Ok
}
