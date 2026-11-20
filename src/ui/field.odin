package ui

import "aio:input"
import "aio:render"
import "base:runtime"
import "core:unicode"
import "core:unicode/utf8"

// One line of editable text. The selection runs between anchor and cursor; they are equal when
// nothing is selected. Both are byte offsets on rune boundaries. `dragging` holds from a pointer press
// in the field until its owner calls field_release; `unit` is what that press selected, so a drag after
// a double click grows the selection by whole words from `word_from` to `word_to`. `caret` is how its
// caret last moved on screen. `clicks` is the field's run of pointer presses, which its owner counts.
Text_Field :: struct {
	bytes:              [dynamic]u8,
	cursor, anchor:     int,
	dragging:           bool,
	unit:               Field_Unit,
	word_from, word_to: int,
	caret:              Field_Caret,
	clicks:             Click_Mark,
}

// What a pointer press in a field selected, and so how its drag moves the selection.
Field_Unit :: enum u8 {
	Caret,
	Word,
	Field,
}

// Where and when the last press of a run of clicks landed, and how many the run has.
Click_Mark :: struct {
	x:       f32,
	time_ns: i64,
	count:   int,
}

Field_Change :: enum {
	None,
	Moved,
	Edited,
}

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

// Replaces the whole text. Without room for `value` the field keeps its text and reports the error.
field_set :: proc(f: ^Text_Field, value: string) -> runtime.Allocator_Error {
	if err := reserve(&f.bytes, len(value)); err != nil {return err}
	clear(&f.bytes)
	append(&f.bytes, ..transmute([]u8)value)
	f.cursor, f.anchor = len(f.bytes), len(f.bytes)
	field_release(f)
	return nil
}

field_select_all :: proc(f: ^Text_Field) {
	f.anchor, f.cursor = 0, len(f.bytes)
}

@(private)
field_delete_range :: proc(f: ^Text_Field, start, end: int) {
	copy(f.bytes[start:], f.bytes[end:])
	resize(&f.bytes, len(f.bytes) - (end - start))
	f.cursor, f.anchor = start, start
}

// Replaces the selection with the printable runes of `text`. Without room for all of them the field
// is left unchanged, so an edit is never applied in part.
field_text :: proc(f: ^Text_Field, text: string) -> Field_Change {
	if !utf8.valid_string(text) {return .None}
	start, end := field_selection(f)
	added := 0
	for r in text {
		if r >= ' ' && r != 0x7f {added += utf8.rune_size(r)}
	}
	if reserve(&f.bytes, len(f.bytes) - (end - start) + added) != nil {return .None}
	change := Field_Change.None
	if start != end {
		field_delete_range(f, start, end)
		change = .Edited
	}
	for r in text {
		if r < ' ' || r == 0x7f {continue}
		encoded, n := utf8.encode_rune(r)
		before := len(f.bytes)
		resize(&f.bytes, before + n)
		copy(f.bytes[f.cursor + n:], f.bytes[f.cursor:before])
		copy(f.bytes[f.cursor:], encoded[:n])
		f.cursor += n
		change = .Edited
	}
	f.anchor = f.cursor
	return change
}

@(private)
rune_left :: proc(f: ^Text_Field, at: int) -> int {
	if at <= 0 {return 0}
	_, n := utf8.decode_last_rune(f.bytes[:at])
	return at - n
}

@(private)
rune_right :: proc(f: ^Text_Field, at: int) -> int {
	if at >= len(f.bytes) {return len(f.bytes)}
	_, n := utf8.decode_rune(f.bytes[at:])
	return at + n
}

@(private)
field_word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
}

@(private)
Field_Word_Class :: enum u8 {
	None,
	Space,
	Word,
	Other,
}

@(private)
field_word_class :: proc(r: rune) -> Field_Word_Class {
	switch {
	case unicode.is_space(r): return .Space
	case field_word_rune(r): return .Word
	}
	return .Other
}

// The word at `at`, as Ctrl+Left and Ctrl+Right take words, and as a Markdown editor's double click does:
// a run of word characters, or on spaces or other marks (a URL's `/ . : ? & = # -`) the run of those. A
// caret between two kinds takes the word it touches, so the end of a word selects the word, not the mark
// after it. An empty field selects nothing.
@(private)
field_word_at :: proc(f: ^Text_Field, offset: int) -> (from, to: int) {
	at := clamp(offset, 0, len(f.bytes))
	before, after: Field_Word_Class
	if at > 0 {
		r, _ := utf8.decode_last_rune(f.bytes[:at])
		before = field_word_class(r)
	}
	if at < len(f.bytes) {
		r, _ := utf8.decode_rune(f.bytes[at:])
		after = field_word_class(r)
	}
	class: Field_Word_Class
	switch {
	case after == .Word || before == .Word: class = .Word
	case after == .Other || before == .Other: class = .Other
	case after == .Space || before == .Space: class = .Space
	case: return at, at
	}
	from, to = at, at
	for from > 0 {
		r, size := utf8.decode_last_rune(f.bytes[:from])
		if field_word_class(r) != class {break}
		from -= size
	}
	for to < len(f.bytes) {
		r, size := utf8.decode_rune(f.bytes[to:])
		if field_word_class(r) != class {break}
		to += size
	}
	return from, to
}

// Back over spaces, then over a word or a run of punctuation, matching markdown edit_word_left.
@(private)
word_left :: proc(f: ^Text_Field, at: int) -> int {
	i := at
	for i > 0 {
		r, _ := utf8.decode_last_rune(f.bytes[:i])
		if !unicode.is_space(r) {break}
		i = rune_left(f, i)
	}
	if i <= 0 {return 0}
	r, _ := utf8.decode_last_rune(f.bytes[:i])
	word := field_word_rune(r)
	for i > 0 {
		previous, _ := utf8.decode_last_rune(f.bytes[:i])
		if unicode.is_space(previous) || field_word_rune(previous) != word {break}
		i = rune_left(f, i)
	}
	return i
}

// Forward over a word or a run of punctuation, then the spaces after it, matching markdown edit_word_right.
@(private)
word_right :: proc(f: ^Text_Field, at: int) -> int {
	i := at
	if i < len(f.bytes) {
		r, _ := utf8.decode_rune(f.bytes[i:])
		if !unicode.is_space(r) {
			word := field_word_rune(r)
			for i < len(f.bytes) {
				next, _ := utf8.decode_rune(f.bytes[i:])
				if unicode.is_space(next) || field_word_rune(next) != word {break}
				i = rune_right(f, i)
			}
		}
	}
	for i < len(f.bytes) {
		next, _ := utf8.decode_rune(f.bytes[i:])
		if !unicode.is_space(next) {break}
		i = rune_right(f, i)
	}
	return i
}

@(private)
field_move :: proc(f: ^Text_Field, to: int, extend: bool) -> Field_Change {
	if extend {
		if to == f.cursor {return .None}
		f.cursor = to
		return .Moved
	}
	if to == f.cursor && f.anchor == f.cursor {return .None}
	f.cursor, f.anchor = to, to
	return .Moved
}

// Handles editing and caret keys. Clipboard chords belong to the caller, which owns the clipboard.
field_key :: proc(f: ^Text_Field, e: input.Key_Event) -> Field_Change {
	if !e.pressed {return .None}
	control := .Control in e.modifiers
	shift := .Shift in e.modifiers
	start, end := field_selection(f)
	#partial switch e.key {
	case .A:
		if control && .Alt not_in e.modifiers {
			if start == 0 && end == len(f.bytes) {return .None}
			field_select_all(f)
			return .Moved
		}
	case .Home:
		return field_move(f, 0, shift)
	case .End:
		return field_move(f, len(f.bytes), shift)
	case .Arrow_Left:
		if !shift && start != end {return field_move(f, start, false)}
		return field_move(f, control ? word_left(f, f.cursor) : rune_left(f, f.cursor), shift)
	case .Arrow_Right:
		if !shift && start != end {return field_move(f, end, false)}
		return field_move(f, control ? word_right(f, f.cursor) : rune_right(f, f.cursor), shift)
	case .Backspace, .Delete:
		if start == end {
			if e.key == .Backspace {
				start = control ? word_left(f, f.cursor) : rune_left(f, f.cursor)
			} else {
				end = control ? word_right(f, f.cursor) : rune_right(f, f.cursor)
			}
		}
		if start == end {return .None}
		field_delete_range(f, start, end)
		return .Edited
	}
	if !control || .Alt in e.modifiers {return field_text(f, e.text)}
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
		advance := text_width(text, value[start + offset:][:utf8.rune_size(r)])
		if x < pen + advance / 2 {return start + offset}
		pen += advance
	}
	return len(value)
}

// Pointer press or drag at offset `at`; a press starts a new selection unless `extend` is held. A press
// that is the second click of a run selects the word there and a third the whole field; the drag after
// a double click grows the selection by whole words toward the pointer, and after a triple click keeps
// the whole field. `clicks` is the press's count in its run, which the caller keeps; a drag needs none.
field_pointer :: proc(f: ^Text_Field, at: int, pressed, extend: bool, clicks := 1) -> Field_Change {
	before_anchor, before_cursor := f.anchor, f.cursor
	switch {
	case pressed && clicks > 1 && !extend:
		f.dragging = true
		if clicks == 2 {
			f.unit = .Word
			f.word_from, f.word_to = field_word_at(f, at)
			f.anchor, f.cursor = f.word_from, f.word_to
		} else {
			f.unit = .Field
			field_select_all(f)
		}
	case pressed:
		f.dragging, f.unit = true, .Caret
		return field_move(f, at, extend)
	case !f.dragging:
		return .None
	case f.unit == .Word:
		from, to := field_word_at(f, at)
		if from < f.word_from {
			f.anchor, f.cursor = f.word_to, from
		} else {
			f.anchor, f.cursor = f.word_from, max(to, f.word_to)
		}
	case f.unit == .Field:
	case:
		return field_move(f, at, true)
	}
	return f.anchor != before_anchor || f.cursor != before_cursor ? .Moved : .None
}

// Ends a pointer drag in the field, returning whether one was under way.
field_release :: proc(f: ^Text_Field) -> bool {
	dragging := f.dragging
	f.dragging, f.unit = false, .Caret
	return dragging
}

// The cell the caret occupies at `at`: the character under it, or a space past the end, one line tall.
@(private)
field_caret_cell :: proc(
	f: ^Text_Field, text: ^Text, value: string, at, baseline, right: f32,
) -> render.Rect {
	width := text_width(text, " ")
	if f.cursor < len(value) {width = text_width(text, value[f.cursor:rune_right(f, f.cursor)])}
	return {at, baseline - text.ascent, max(1, min(width, right - at)), text.line_height}
}

field_draw :: proc(
	f: ^Text_Field,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	x, baseline, available: f32,
	focused: bool,
	placeholder: string,
	color: render.Color,
) -> render.Build_Status {
	value := field_string(f)
	start := field_view_start(f, text, available)
	selection: render.Rect
	if focused && value != "" {
		low, high := field_selection(f)
		if low != high {
			left := x + text_width(text, value[start:max(start, low)])
			right := x + text_width(text, value[start:max(start, high)])
			left, right = min(left, x + available), min(right, x + available)
			selection = {left, baseline - text.ascent, right - left, text.line_height}
			draw_rect(list, {rect = selection, color = theme.text_selection})
		}
	}
	head: render.Rect
	shown := false
	if focused {
		at := x + min(available, text_width(text, value[start:f.cursor]))
		cell := field_caret_cell(f, text, value, at, baseline, x + available)
		drawn: bool
		head, drawn = field_caret_pose(&f.caret, text.carets, {x, baseline}, cell, theme)
		shown = drawn && caret_shown(text.carets, f.caret.motion.active)
		if drawn {field_caret_body(&f.caret, list, theme)}
	}
	if value == "" {
		if result := draw_text(text, list, placeholder, x, baseline, theme.muted, available);
		   result != .Ok {
			return result
		}
	} else if result := draw_text(text, list, value[start:], x, baseline, color, available);
	   result != .Ok {
		return result
	}
	// Selected text takes the theme's selection text colour, as a terminal's does, when it sets one.
	if ink, recolour := theme.text_selection_text.?; recolour && selection.width > 0 {
		scope, opened := clip_scope_open(list, selection)
		if opened {
			draw_rect(list, {rect = selection, color = theme.text_selection})
			result := draw_text(text, list, value[start:], x, baseline, ink, available)
			clip_scope_close(list, scope)
			if result != .Ok {return result}
		}
	}
	if !shown {return .Ok}
	scope, block := field_caret_head(list, &f.caret, theme, head)
	if !block {return .Ok}
	defer clip_scope_close(list, scope)
	// The block covers what is under it, which draws again over it in the cursor text colour.
	under := value == "" ? placeholder : value[start:]
	return draw_text(text, list, under, x, baseline, theme.caret_text, available)
}
