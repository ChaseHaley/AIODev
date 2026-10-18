package ui

import "core:unicode/utf8"
import "aio:glyphs"
import "aio:platform"
import "aio:render"

// One line of editable text. The selection runs between anchor and cursor; they are equal when
// nothing is selected. Both are byte offsets on rune boundaries.
Text_Field :: struct {
	bytes: [dynamic]u8,
	cursor, anchor: int,
	dragging: bool,
}

Field_Change :: enum { None, Moved, Edited }

field_string :: proc(f: ^Text_Field) -> string {
	return string(f.bytes[:])
}

field_selection :: proc(f: ^Text_Field) -> (start, end: int) {
	return min(f.anchor, f.cursor), max(f.anchor, f.cursor)
}

field_selected_text :: proc(f: ^Text_Field) -> string {
	start, end := field_selection(f)
	return string(f.bytes[start:end])
}

field_set :: proc(f: ^Text_Field, value: string) {
	clear(&f.bytes)
	append(&f.bytes, ..transmute([]u8)value)
	f.cursor, f.anchor, f.dragging = len(f.bytes), len(f.bytes), false
}

field_select_all :: proc(f: ^Text_Field) {
	f.anchor, f.cursor = 0, len(f.bytes)
}

@(private)
field_delete_range :: proc(f: ^Text_Field, start, end: int) {
	copy(f.bytes[start:], f.bytes[end:])
	resize(&f.bytes, len(f.bytes)-(end-start))
	f.cursor, f.anchor = start, start
}

// Replaces the selection with the printable runes of `text`.
field_text :: proc(f: ^Text_Field, text: string) -> Field_Change {
	if !utf8.valid_string(text) { return .None }
	start, end := field_selection(f)
	change := Field_Change.None
	if start != end {
		field_delete_range(f, start, end)
		change = .Edited
	}
	for r in text {
		if r < ' ' || r == 0x7f { continue }
		encoded, n := utf8.encode_rune(r)
		before := len(f.bytes)
		if resize(&f.bytes, before+n) != nil { break }
		copy(f.bytes[f.cursor+n:], f.bytes[f.cursor:before])
		copy(f.bytes[f.cursor:], encoded[:n])
		f.cursor += n
		change = .Edited
	}
	f.anchor = f.cursor
	return change
}

@(private)
rune_left :: proc(f: ^Text_Field, at: int) -> int {
	if at <= 0 { return 0 }
	_, n := utf8.decode_last_rune(f.bytes[:at])
	return at-n
}

@(private)
rune_right :: proc(f: ^Text_Field, at: int) -> int {
	if at >= len(f.bytes) { return len(f.bytes) }
	_, n := utf8.decode_rune(f.bytes[at:])
	return at+n
}

// Word motion skips spaces, then the run of nonspace text beyond them.
@(private)
word_left :: proc(f: ^Text_Field, at: int) -> int {
	i := at
	for i > 0 && f.bytes[i-1] == ' ' { i -= 1 }
	for i > 0 && f.bytes[i-1] != ' ' { i = rune_left(f, i) }
	return i
}

@(private)
word_right :: proc(f: ^Text_Field, at: int) -> int {
	i := at
	for i < len(f.bytes) && f.bytes[i] == ' ' { i += 1 }
	for i < len(f.bytes) && f.bytes[i] != ' ' { i = rune_right(f, i) }
	return i
}

@(private)
field_move :: proc(f: ^Text_Field, to: int, extend: bool) -> Field_Change {
	if extend {
		if to == f.cursor { return .None }
		f.cursor = to
		return .Moved
	}
	if to == f.cursor && f.anchor == f.cursor { return .None }
	f.cursor, f.anchor = to, to
	return .Moved
}

// Handles editing and caret keys. Clipboard chords belong to the caller, which owns the clipboard.
field_key :: proc(f: ^Text_Field, e: platform.Key_Event) -> Field_Change {
	if !e.pressed { return .None }
	control := .Control in e.modifiers
	shift := .Shift in e.modifiers
	start, end := field_selection(f)
	#partial switch e.key {
	case .A:
		if control && .Alt not_in e.modifiers {
			if start == 0 && end == len(f.bytes) { return .None }
			field_select_all(f)
			return .Moved
		}
	case .Home: return field_move(f, 0, shift)
	case .End: return field_move(f, len(f.bytes), shift)
	case .Arrow_Left:
		if !shift && start != end { return field_move(f, start, false) }
		return field_move(f, control ? word_left(f, f.cursor) : rune_left(f, f.cursor), shift)
	case .Arrow_Right:
		if !shift && start != end { return field_move(f, end, false) }
		return field_move(f, control ? word_right(f, f.cursor) : rune_right(f, f.cursor), shift)
	case .Backspace, .Delete:
		if start == end {
			if e.key == .Backspace {
				start = control ? word_left(f, f.cursor) : rune_left(f, f.cursor)
			} else {
				end = control ? word_right(f, f.cursor) : rune_right(f, f.cursor)
			}
		}
		if start == end { return .None }
		field_delete_range(f, start, end)
		return .Edited
	}
	if !control || .Alt in e.modifiers { return field_text(f, e.text) }
	return .None
}

// The first byte shown when the caret must stay inside `available` pixels.
field_view_start :: proc(f: ^Text_Field, text: ^Text, available: f32) -> int {
	value := field_string(f)
	start := 0
	for start < f.cursor && text_width(text, value[start:f.cursor]) > available {
		start = rune_right(f, start)
	}
	return start
}

// The caret offset nearest to `x` for text drawn from `origin` starting at byte `start`.
field_offset_at :: proc(f: ^Text_Field, text: ^Text, start: int, origin, x: f32) -> int {
	value := field_string(f)
	pen := origin
	for r, offset in value[start:] {
		advance := text_width(text, value[start+offset:][:utf8.rune_size(r)])
		if x < pen+advance/2 { return start+offset }
		pen += advance
	}
	return len(value)
}

// Pointer press or drag at offset `at`; a press starts a new selection unless `extend` is held.
field_pointer :: proc(f: ^Text_Field, at: int, pressed, extend: bool) -> Field_Change {
	if pressed {
		f.dragging = true
		return field_move(f, at, extend)
	}
	if !f.dragging { return .None }
	return field_move(f, at, true)
}

field_draw :: proc(f: ^Text_Field, list: ^render.Draw_List, text: ^Text, theme: Theme,
	x, baseline, available: f32, focused: bool, placeholder: string, color: render.Color,
	caret_width: f32) -> glyphs.Result {
	value := field_string(f)
	if value == "" {
		if result := draw_text(text, list, placeholder, x, baseline, theme.muted, available); result != .Ok {
			return result
		}
	} else {
		start := field_view_start(f, text, available)
		low, high := field_selection(f)
		if focused && low != high {
			left := x+text_width(text, value[start:max(start, low)])
			right := x+text_width(text, value[start:max(start, high)])
			left, right = min(left, x+available), min(right, x+available)
			draw_rect(list, {rect = {left, baseline-text.ascent, right-left, text.line_height},
				color = theme.focus})
		}
		if result := draw_text(text, list, value[start:], x, baseline, color, available); result != .Ok {
			return result
		}
	}
	if focused {
		start := field_view_start(f, text, available)
		caret := x+min(available, text_width(text, value[start:f.cursor]))
		draw_rect(list, {rect = {caret, baseline-text.ascent, caret_width, text.line_height},
			color = theme.accent})
	}
	return .Ok
}
