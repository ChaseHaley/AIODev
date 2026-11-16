package ui

import "aio:font"
import "aio:render"
import "aio:syntax"
import tr "aio:turns"
import "core:math"

@(private)
CHANGES_TAB_COLUMNS :: 4

// Where a diff row's number, sign and text start. A unified row has two number columns, old and new; a
// side-by-side cell has one, and `new_x` is `old_x` there. One proc places them for painting, hit testing
// and the text selection, so a click lands on the character it is drawn over.
Code_Column :: struct {
	old_x, new_x, sign_x, text_x: f32,
	// The room for text, from `text_x` to the cell's right edge.
	width:                        f32,
}

// The column of a row or cell `cell` wide, whose number columns are `number_width` wide and whose digits
// advance `digit`.
code_column :: proc(cell: render.Rect, number_width, digit, scale: f32, two_numbers: bool) -> Code_Column {
	c: Code_Column
	c.old_x = cell.x + SPACE_2 * scale
	c.new_x = two_numbers ? c.old_x + number_width + SPACE_2 * scale : c.old_x
	c.sign_x = c.new_x + number_width + SPACE_2 * scale
	c.text_x = c.sign_x + digit + SPACE_1 * scale
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

// How wide a space is in `t`, which a tab spans CHANGES_TAB_COLUMNS times.
@(private)
code_space :: proc(t: ^Text) -> f32 {
	if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, ' '); found {
		return font.glyph_advance(t.fonts, g, t.size_px)
	}
	return 0
}

// How one rune of a code line lays out: a tab advances CHANGES_TAB_COLUMNS spaces from the pen and draws
// nothing, a rune without a glyph takes no room and draws nothing, and any other draws `glyph`. Painting,
// measuring and the hit test all read this, so they cannot disagree.
@(private)
code_rune :: proc(t: ^Text, r: rune, space: f32) -> (glyph: font.Glyph, advance: f32, drawn: bool) {
	if r == '\t' {return {}, CHANGES_TAB_COLUMNS * space, false}
	g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
	if !found {return {}, 0, false}
	return g, font.glyph_advance(t.fonts, g, t.size_px), true
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

// The byte offset of the boundary nearest `x`, measured from where the text starts, in a code line `s` drawn
// in `t` with `width` of room. It sees what the painter draws: the runes that start before `width`, so a
// point past them is the end of the visible text. `s` is what the row draws, `mono_prefix` of the line.
// A rune that joins the one before it is no boundary of its own.
code_offset_at :: proc(t: ^Text, s: string, width, x: f32) -> int {
	space := code_space(t)
	pen: f32
	for r, offset in s {
		if pen >= width {return offset}
		_, advance, _ := code_rune(t, r, space)
		if !code_joins(r) && x < pen + advance / 2 {return offset}
		pen += advance
	}
	return len(s)
}

// Where the boundary at byte `offset` of `s` is, measured from where the text starts: the inverse of
// code_offset_at, with the same visible text. An offset past it is the end of the visible text.
code_x_of :: proc(t: ^Text, s: string, width: f32, offset: int) -> f32 {
	space := code_space(t)
	pen: f32
	for r, at in s {
		if at >= offset || pen >= width {break}
		_, advance, _ := code_rune(t, r, space)
		pen += advance
	}
	return pen
}

// A byte range of a code line drawn apart from the rest: a tint behind it, a line under it and one through
// it, and the selected inks. A colour with no alpha draws nothing. Runs are sorted and do not overlap.
Code_Run :: struct {
	start, end:              int,
	tint, underline, strike: render.Color,
	selected:                bool,
}

// One line of code to draw. `spans` and `runs` are byte offsets into `text`, which starts where the line
// does; text outside the spans takes ink `plain`. `inks` colours the text, and runs marked `selected` take
// `selected_inks` instead (`inks` again when it is nil). The tints and lines fill the row `top` and
// `height` give, from `x` to the room's end.
Code_Line :: struct {
	text:                      string,
	spans:                     []syntax.Span,
	runs:                      []Code_Run,
	x, width:                  f32,
	top, height, baseline:     f32,
	scale:                     f32,
	inks, selected_inks:       ^[CHANGES_INKS]render.Color,
	plain:                     int,
}

// Draws the end of a run: its tint behind the glyphs, then the lines under and through them.
@(private = "file")
code_run_draw :: proc(list: ^render.Draw_List, line: Code_Line, run: Code_Run, x0, end: f32) {
	x1 := min(end, line.x + line.width)
	if x1 <= x0 {return}
	thickness := max(1, math.round(1.5 * line.scale))
	if run.tint.a > 0 {
		draw_rect(list, {rect = {x0, line.top, x1 - x0, line.height}, color = run.tint})
	}
	if run.underline.a > 0 {
		bar := render.Rect{x0, line.top + line.height - thickness, x1 - x0, thickness}
		draw_rect(list, {rect = bar, color = run.underline})
	}
	if run.strike.a > 0 {
		middle := math.round(line.top + (line.height - thickness) / 2)
		draw_rect(list, {rect = {x0, middle, x1 - x0, thickness}, color = run.strike})
	}
}

// Draws the start of a code line from `line.x`, fading out over the last fifth of `line.width` when it runs
// past it. Each rune is coloured by the span it is in. Spans come from the whole file, which a clean or
// smudge filter can make differ from the diff text, so they are only read at offsets inside the text: one
// reaching past the end colours what is inside, and an empty or out-of-order one is skipped.
code_line_draw :: proc(list: ^render.Draw_List, t: ^Text, line: Code_Line) -> render.Build_Status {
	if line.width <= 0 {return .Ok}
	palette := CHANGES_SYNTAX_PALETTE
	space := code_space(t)
	start := len(list.glyphs)
	pen := line.x
	next, run_at := 0, 0
	open: bool
	run_x: f32
	clipped := false
	for r, offset in line.text {
		if pen >= line.x + line.width {
			clipped = true
			break
		}
		for run_at < len(line.runs) && line.runs[run_at].end <= offset {
			if open {code_run_draw(list, line, line.runs[run_at], run_x, pen)}
			open = false
			run_at += 1
		}
		if !open && run_at < len(line.runs) && line.runs[run_at].start <= offset {
			open, run_x = true, pen
		}
		for next < len(line.spans) && int(line.spans[next].end) <= offset {next += 1}
		inks := line.inks
		if open && line.runs[run_at].selected && line.selected_inks != nil {inks = line.selected_inks}
		c := inks[line.plain]
		if next < len(line.spans) && int(line.spans[next].start) <= offset {
			index := palette[line.spans[next].kind]
			c = inks[index >= 0 ? index : CHANGES_INK_TEXT]
		}
		g, advance, drawn := code_rune(t, r, space)
		if drawn {
			if result := draw_glyph(t, list, g, pen, line.baseline, c); result != .Ok {return result}
		}
		pen += advance
	}
	if open {code_run_draw(list, line, line.runs[run_at], run_x, pen)}
	if clipped || pen > line.x + line.width {
		for &glyph in list.glyphs[start:] {
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = line.x + line.width * 0.8, line.x + line.width
		}
	}
	return .Ok
}
