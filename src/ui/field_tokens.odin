package ui

import "cosmos:render"
import "core:math"
import "core:unicode/utf8"

// A field that shows saved filters in its text as tokens: each `@id` word is a pill, showing the filter's
// current name, that is one unit for
// the caret, the selection and Backspace (the field's atoms), dimmed while off. The pane parses the text
// into tokens after every edit and hands them to the draw and the hit tests here, which walk the text and
// the tokens in the same order so a press, the caret and the pixels agree.

Filter_Token_State :: enum u8 {
	// Refers to a saved filter whose pattern compiles.
	Known,
	// Refers to no saved filter; it hides nothing.
	Unknown,
	// Refers to a saved filter whose pattern does not compile.
	Invalid,
}

// A token of the filter text: its bytes `start` to `end` in the field (`@id` or `~@id`), the id it
// refers to as a slice of those bytes, the name the pill shows (the filter's name, or its pattern while it
// has none; the id itself when no filter has it), and whether it is off. The slices live until the next
// edit or settings change.
Filter_Token :: struct {
	start, end: int,
	id, name:   string,
	off:        bool,
	state:      Filter_Token_State,
}

// A saved filter offered by the `@` list: its id, its label (name, or pattern while it has no name), its
// pattern, and how many files it would hide on its own, as slices of the library the pane keeps.
Filter_Pick :: struct {
	id, label, pattern: string,
	hides:              int,
}

@(private = "file")
TOKEN_CLOSE :: f32(16)

// The @ icon of a pill or a list row, sized so its ink is as tall as the name's capitals.
TOKEN_AT_ICON :: f32(10)

@(private = "file")
TOKEN_LABEL_MAX :: f32(180)

@(private = "file")
token_label :: proc(token: Filter_Token) -> string {
	return clip_bytes(token.name, CHANGES_CLIP_BYTES)
}

@(private = "file")
token_width :: proc(text: ^Text, token: Filter_Token, s: f32) -> f32 {
	label := min(text_width(text, token_label(token)), TOKEN_LABEL_MAX * s)
	return math.ceil(text_width(text, "@") + label + (SPACE_2 + 2 * SPACE_1 + SPACE_1 + TOKEN_CLOSE) * s)
}

// Where byte `at` sits, in pixels from the left edge of the text before any scrolling.
@(private = "file")
token_x :: proc(f: ^Text_Field, tokens: []Filter_Token, text: ^Text, s: f32, at: int) -> f32 {
	value := field_string(f)
	pen, from := f32(0), 0
	for token in tokens {
		if at <= token.start {break}
		pen += text_width(text, value[from:token.start])
		width := token_width(text, token, s)
		if at <= token.end {return pen + width}
		pen += width
		from = token.end
	}
	return pen + text_width(text, value[from:at])
}

// How far the text scrolls left to keep the caret in `available` pixels.
@(private = "file")
token_scroll :: proc(f: ^Text_Field, tokens: []Filter_Token, text: ^Text, s, available: f32) -> f32 {
	return max(0, token_x(f, tokens, text, s, f.cursor) - available)
}

// The pill at `x` from the text's left edge, scroll included, and whether the point is on its ×.
@(private = "file")
token_hit :: proc(
	f: ^Text_Field, tokens: []Filter_Token, text: ^Text, s, x: f32,
) -> (
	index: int,
	close: bool,
) {
	value := field_string(f)
	pen, from := f32(0), 0
	for token, i in tokens {
		pen += text_width(text, value[from:token.start])
		width := token_width(text, token, s)
		if x >= pen && x < pen + width {return i, x >= pen + width - (SPACE_1 + TOKEN_CLOSE) * s}
		pen += width
		from = token.end
	}
	return -1, false
}

// The caret offset nearest to `x` from the text's left edge: inside a pill it is the nearer of its two edges.
@(private = "file")
token_offset :: proc(f: ^Text_Field, tokens: []Filter_Token, text: ^Text, s, x: f32) -> int {
	value := field_string(f)
	pen, from := f32(0), 0
	in_text :: proc(value: string, text: ^Text, from, to: int, pen, x: f32) -> int {
		at := pen
		for r, i in value[from:to] {
			advance := text_width(text, value[from + i:][:utf8.rune_size(r)])
			if x < at + advance / 2 {return from + i}
			at += advance
		}
		return to
	}
	for token in tokens {
		gap := text_width(text, value[from:token.start])
		if x < pen + gap {return in_text(value, text, from, token.start, pen, x)}
		pen += gap
		width := token_width(text, token, s)
		if x < pen + width {return x < pen + width / 2 ? token.start : token.end}
		pen += width
		from = token.end
	}
	return in_text(value, text, from, len(value), pen, x)
}

// The caret offset for a press or drag at screen `x` in a token field's box.
filter_field_offset :: proc(box: Field_Box, tokens: []Filter_Token, x: f32) -> int {
	if len(box.field.bytes) == 0 {return 0}
	text := text_styled(box.text, box.style)
	frame := field_box_text_rect(box)
	scroll := token_scroll(box.field, tokens, &text, box.scale, frame.width)
	return token_offset(box.field, tokens, &text, box.scale, x - frame.x + scroll)
}

// The token under screen `x` in the box and whether the point is on its ×; -1 when there is none.
filter_field_token_at :: proc(box: Field_Box, tokens: []Filter_Token, x: f32) -> (index: int, close: bool) {
	if len(tokens) == 0 {return -1, false}
	text := text_styled(box.text, box.style)
	frame := field_box_text_rect(box)
	scroll := token_scroll(box.field, tokens, &text, box.scale, frame.width)
	return token_hit(box.field, tokens, &text, box.scale, x - frame.x + scroll)
}

// Where token `index` is drawn in the box: its pill, as the draw places it.
filter_field_token_rect :: proc(box: Field_Box, tokens: []Filter_Token, index: int) -> render.Rect {
	if index < 0 || index >= len(tokens) {return {}}
	text := text_styled(box.text, box.style)
	frame := field_box_text_rect(box)
	s, token := box.scale, tokens[index]
	scroll := token_scroll(box.field, tokens, &text, s, frame.width)
	x := frame.x - scroll + token_x(box.field, tokens, &text, s, token.start)
	pill := math.round(HEIGHT_COMPACT * s)
	return {x, box.rect.y + (box.rect.height - pill) / 2, token_width(&text, token, s), pill}
}

// The boxes of a pill's @ and ×, each as tall as the pill so an icon centred in one is centred on the pill.
@(private = "file")
token_parts :: proc(text: ^Text, pill: render.Rect, s: f32) -> (at, close: render.Rect) {
	at = {pill.x + SPACE_2 * s, pill.y, text_width(text, "@"), pill.height}
	close = {pill.x + pill.width - (SPACE_1 + TOKEN_CLOSE) * s, pill.y, TOKEN_CLOSE * s, pill.height}
	return
}

// Where token `index` draws its @ and its ×, for the verification state.
filter_field_token_marks :: proc(
	box: Field_Box, tokens: []Filter_Token, index: int,
) -> (
	at, close: render.Rect,
) {
	pill := filter_field_token_rect(box, tokens, index)
	if pill.width <= 0 {return}
	text := text_styled(box.text, box.style)
	return token_parts(&text, pill, box.scale)
}

// One pill: a fill that dims while the token is off, its name (struck through while off) and the ×.
@(private = "file")
token_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	token: Filter_Token,
	rect: render.Rect,
	pointer: [2]f32,
	s: f32,
) -> render.Build_Status {
	radius := RADIUS_CONTROL * s
	draw_rect(list, {rect = rect, color = token.off ? theme.hover : theme.selection, radius = radius})
	ink := token.off ? theme.faint : theme.text
	if token.state != .Known {
		draw_rect(list, {rect = rect, color = theme.warning, radius = radius, stroke = s})
	}
	label := token_label(token)
	at_box, close := token_parts(text, rect, s)
	x := at_box.x
	mark := token.off ? theme.faint : theme.accent
	// The @ is the field's @ button icon, centred on the pill like the ×; the name's capitals share that line.
	icon_draw(list, .At, at_box, mark, TOKEN_AT_ICON, s)
	x += at_box.width + SPACE_1 * s
	room := max(1, close.x - x)
	line := baseline_caps(rect.y, rect.height, text)
	if result := draw_text(text, list, label, x, line, ink, room); result != .Ok {return result}
	if token.off {
		width := min(text_width(text, label), room)
		strike := render.Rect{x, line - text.ascent / 3, width, max(1, math.round(s))}
		draw_rect(list, {rect = strike, color = ink})
	}
	hover := f32(render.rect_contains(close, pointer.x, pointer.y) ? 1 : 0)
	err := icon_button_draw(list, theme, close, .Close, hover, 0, s, pointer, ICON_INDICATOR, RADIUS_CONTROL)
	if err != .None {return .Ok}
	return .Ok
}

// The text between the tokens, and the pills when `pills`, from `origin`; `ink` colours the text.
@(private = "file")
token_content :: proc(
	box: Field_Box,
	tokens: []Filter_Token,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	origin, baseline: f32,
	pointer: [2]f32,
	ink: render.Color,
	pills: bool,
) -> render.Build_Status {
	s, value := box.scale, field_string(box.field)
	frame := field_box_text_rect(box)
	limit := frame.x + frame.width
	pen, from := origin, 0
	pill := math.round(HEIGHT_COMPACT * s)
	top := box.rect.y + (box.rect.height - pill) / 2
	for token in tokens {
		gap := value[from:token.start]
		if status := draw_text(text, list, gap, pen, baseline, ink, max(1, limit - pen)); status != .Ok {
			return status
		}
		pen += text_width(text, gap)
		width := token_width(text, token, s)
		if pills && pen < limit && pen + width > frame.x {
			rect := render.Rect{pen, top, width, pill}
			if status := token_draw(list, text, theme, token, rect, pointer, s); status != .Ok {
				return status
			}
		}
		pen += width
		from = token.end
	}
	return draw_text(text, list, value[from:], pen, baseline, ink, max(1, limit - pen))
}

// Draws the field's text with each token as a pill, clipped to the box, with the selection and the caret.
filter_field_draw :: proc(
	box: Field_Box,
	tokens: []Filter_Token,
	list: ^render.Draw_List,
	theme: Theme,
	baseline: f32,
	focused: bool,
	placeholder: string,
	pointer: [2]f32,
) -> render.Build_Status {
	f, s := box.field, box.scale
	text := text_styled(box.text, box.style)
	frame := field_box_text_rect(box)
	scope, opened := clip_scope_open(list, box.rect, box.radius * s)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	value := field_string(f)
	origin := frame.x - token_scroll(f, tokens, &text, s, frame.width)
	limit := frame.x + frame.width
	if focused && value != "" {
		low, high := field_selection(f)
		if low != high {
			left := max(origin + token_x(f, tokens, &text, s, low), frame.x)
			right := min(origin + token_x(f, tokens, &text, s, high), limit)
			if right > left {
				fill := render.Rect{left, baseline - text.ascent, right - left, text.line_height}
				draw_rect(list, {rect = fill, color = theme.text_selection})
			}
		}
	}
	head: render.Rect
	shown := false
	if focused {
		at := origin + token_x(f, tokens, &text, s, f.cursor)
		width := text_width(&text, " ")
		if f.cursor < len(value) && len(tokens) == 0 {
			width = text_width(&text, value[f.cursor:rune_right(f, f.cursor)])
		}
		cell := render.Rect{at, baseline - text.ascent, max(1, min(width, limit - at)), text.line_height}
		drawn: bool
		head, drawn = field_caret_pose(&f.caret, text.carets, {frame.x, baseline}, cell, theme)
		shown = drawn && caret_shown(text.carets, f.caret.motion.active)
		if drawn {field_caret_body(&f.caret, list, theme)}
	}
	if value == "" {
		status := draw_text(&text, list, placeholder, frame.x, baseline, theme.muted, frame.width)
		if status != .Ok {return status}
	} else {
		ink := theme.text
		if status := token_content(box, tokens, list, &text, theme, origin, baseline, pointer, ink, true);
		   status != .Ok {
			return status
		}
	}
	if !shown {return .Ok}
	caret_scope, block := field_caret_head(list, &f.caret, theme, head)
	if !block {return .Ok}
	defer clip_scope_close(list, caret_scope)
	return token_content(box, tokens, list, &text, theme, origin, baseline, pointer, theme.caret_text, false)
}
