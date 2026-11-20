package markdown

import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// A Markdown file as an editor holds it: its bytes as they are on disk, byte order mark and line endings
// included, a caret and selection, and undo history (WORK-441).
Edit_Buffer :: struct {
	text:          [dynamic]u8,
	// The selection runs from anchor to caret, byte offsets into text; equal when nothing is selected.
	caret, anchor: int,
	// No caret goes before the byte order mark.
	floor:         int,
	// What Enter inserts: the file's own line ending.
	newline:       string,
	undo, redo:    [dynamic]Edit,
	// Counts changes to the text, so what shows it knows to rebuild.
	revision:      u64,
}

// One change, which undo reverses. Both strings are owned.
Edit :: struct {
	at:                          int,
	removed, inserted:           string,
	caret_before, anchor_before: int,
	// Typing and deleting a run of characters join one edit, which undo reverses whole.
	run:                         Edit_Run,
}

Edit_Run :: enum u8 {
	None,
	Typing,
	Deleting,
}

// Edits the history keeps; the oldest go first.
@(private)
UNDO_LIMIT :: 1000

@(require_results)
edit_buffer_init :: proc(b: ^Edit_Buffer, text: string) -> bool {
	b^ = {}
	if _, err := append(&b.text, text); err != nil {return false}
	edit_text_adopted(b)
	return true
}

edit_buffer_destroy :: proc(b: ^Edit_Buffer) {
	delete(b.text)
	edit_history_clear(b)
	delete(b.undo)
	delete(b.redo)
	b^ = {}
}

// Takes the file's text as it now is on disk, keeping the caret near where it was. The history
// described the old text, so it goes.
@(require_results)
edit_buffer_reset :: proc(b: ^Edit_Buffer, text: string) -> bool {
	clear(&b.text)
	if _, err := append(&b.text, text); err != nil {return false}
	edit_history_clear(b)
	edit_text_adopted(b)
	b.caret = edit_clamp(b, b.caret)
	b.anchor = edit_clamp(b, b.anchor)
	return true
}

@(private)
edit_text_adopted :: proc(b: ^Edit_Buffer) {
	text := string(b.text[:])
	b.floor = strings.has_prefix(text, BOM) ? len(BOM) : 0
	b.newline = "\n"
	line_end := strings.index_byte(text, '\n')
	if line_end > 0 && text[line_end - 1] == '\r' {b.newline = "\r\n"}
	b.revision += 1
}

@(private)
edit_history_clear :: proc(b: ^Edit_Buffer) {
	for edit in b.undo {edit_free(edit)}
	for edit in b.redo {edit_free(edit)}
	clear(&b.undo)
	clear(&b.redo)
}

@(private)
edit_free :: proc(edit: Edit) {
	delete(edit.removed)
	delete(edit.inserted)
}

@(require_results)
edit_string :: proc(b: ^Edit_Buffer) -> string {
	return string(b.text[:])
}

@(require_results)
edit_selection :: proc(b: ^Edit_Buffer) -> (from, to: int) {
	return min(b.anchor, b.caret), max(b.anchor, b.caret)
}

@(require_results)
edit_selected_text :: proc(b: ^Edit_Buffer) -> string {
	from, to := edit_selection(b)
	return string(b.text[from:to])
}

// An offset moved onto the text and off the middle of a character or a CRLF pair.
@(require_results)
edit_clamp :: proc(b: ^Edit_Buffer, offset: int) -> int {
	at := clamp(offset, b.floor, len(b.text))
	for at > b.floor && at < len(b.text) && !utf8.rune_start(b.text[at]) {at -= 1}
	if at > b.floor && at < len(b.text) && b.text[at] == '\n' && b.text[at - 1] == '\r' {at -= 1}
	return at
}

// Moves the caret; without `extend` the selection collapses onto it.
edit_move :: proc(b: ^Edit_Buffer, at: int, extend := false) {
	b.caret = edit_clamp(b, at)
	if !extend {b.anchor = b.caret}
}

edit_select_all :: proc(b: ^Edit_Buffer) {
	b.anchor, b.caret = b.floor, len(b.text)
}

// The start of the character before `at`; a CRLF pair is one character.
@(require_results)
edit_left :: proc(b: ^Edit_Buffer, at: int) -> int {
	if at <= b.floor {return b.floor}
	if at >= 2 && b.text[at - 1] == '\n' && b.text[at - 2] == '\r' {return at - 2}
	_, size := utf8.decode_last_rune(b.text[b.floor:at])
	return at - max(size, 1)
}

// The end of the character from `at`.
@(require_results)
edit_right :: proc(b: ^Edit_Buffer, at: int) -> int {
	if at >= len(b.text) {return len(b.text)}
	if b.text[at] == '\r' && at + 1 < len(b.text) && b.text[at + 1] == '\n' {return at + 2}
	_, size := utf8.decode_rune(b.text[at:])
	return at + max(size, 1)
}

@(private)
word_rune :: proc(r: rune) -> bool {
	return unicode.is_letter(r) || unicode.is_digit(r) || r == '_'
}

// Back over spaces, then over a word or a run of other marks, as Ctrl+Left goes.
@(require_results)
edit_word_left :: proc(b: ^Edit_Buffer, at: int) -> int {
	at := at
	for at > b.floor {
		r, _ := utf8.decode_last_rune(b.text[b.floor:at])
		if !unicode.is_space(r) {break}
		at = edit_left(b, at)
	}
	if at <= b.floor {return b.floor}
	r, _ := utf8.decode_last_rune(b.text[b.floor:at])
	word := word_rune(r)
	for at > b.floor {
		previous, _ := utf8.decode_last_rune(b.text[b.floor:at])
		if unicode.is_space(previous) || word_rune(previous) != word {break}
		at = edit_left(b, at)
	}
	return at
}

// Over a word or a run of other marks, then the spaces after it, as Ctrl+Right goes.
@(require_results)
edit_word_right :: proc(b: ^Edit_Buffer, at: int) -> int {
	at := at
	if at < len(b.text) {
		r, _ := utf8.decode_rune(b.text[at:])
		if !unicode.is_space(r) {
			word := word_rune(r)
			for at < len(b.text) {
				next, _ := utf8.decode_rune(b.text[at:])
				if unicode.is_space(next) || word_rune(next) != word {break}
				at = edit_right(b, at)
			}
		}
	}
	for at < len(b.text) {
		next, _ := utf8.decode_rune(b.text[at:])
		if !unicode.is_space(next) || next == '\n' || next == '\r' {break}
		at = edit_right(b, at)
	}
	return at
}

// The start of the line holding `at`.
@(require_results)
edit_line_start :: proc(b: ^Edit_Buffer, at: int) -> int {
	start := strings.last_index_byte(string(b.text[:at]), '\n') + 1
	return max(start, b.floor)
}

// The end of the line holding `at`, before its line ending.
@(require_results)
edit_line_end :: proc(b: ^Edit_Buffer, at: int) -> int {
	end := strings.index_byte(string(b.text[at:]), '\n')
	end = end < 0 ? len(b.text) : at + end
	if end > at && b.text[end - 1] == '\r' {end -= 1}
	return end
}

// What a double click selects and a drag after it grows by: the word under the pointer, or the whole line.
Edit_Unit :: enum u8 {
	Word,
	Line,
}

@(private)
Edit_Class :: enum u8 {
	None,
	Space,
	Word,
	Other,
}

@(private)
edit_class :: proc(r: rune) -> Edit_Class {
	switch {
	case unicode.is_space(r): return .Space
	case word_rune(r): return .Word
	}
	return .Other
}

// The word at `at`, as Ctrl+Left and Ctrl+Right take words: a run of word characters, or on spaces or
// other marks the run of those. A caret between two kinds takes the word it touches, so the end of a
// word selects the word, not the space after it. Never crosses a line break; an empty line selects nothing.
@(require_results)
edit_word_at :: proc(b: ^Edit_Buffer, offset: int) -> (from, to: int) {
	at := edit_clamp(b, offset)
	start, end := edit_line_start(b, at), edit_line_end(b, at)
	before, after: Edit_Class
	if at > start {
		r, _ := utf8.decode_last_rune(b.text[start:at])
		before = edit_class(r)
	}
	if at < end {
		r, _ := utf8.decode_rune(b.text[at:end])
		after = edit_class(r)
	}
	class: Edit_Class
	switch {
	case after == .Word || before == .Word: class = .Word
	case after == .Other || before == .Other: class = .Other
	case after == .Space || before == .Space: class = .Space
	case: return at, at
	}
	from, to = at, at
	for from > start {
		r, size := utf8.decode_last_rune(b.text[start:from])
		if edit_class(r) != class {break}
		from -= size
	}
	for to < end {
		r, size := utf8.decode_rune(b.text[to:end])
		if edit_class(r) != class {break}
		to += size
	}
	return from, to
}

// The line holding `at` with its line ending, as a triple click selects it; the last line has none.
@(require_results)
edit_line_at :: proc(b: ^Edit_Buffer, offset: int) -> (from, to: int) {
	at := edit_clamp(b, offset)
	from, to = edit_line_start(b, at), edit_line_end(b, at)
	if to < len(b.text) {to = edit_right(b, to)}
	return from, to
}

@(require_results)
edit_unit_at :: proc(b: ^Edit_Buffer, at: int, unit: Edit_Unit) -> (from, to: int) {
	if unit == .Word {return edit_word_at(b, at)}
	return edit_line_at(b, at)
}

// Selects the unit at `at`, or after the click that selected `from`..`to`, a drag to `at`: the selection
// keeps that first unit and grows by whole units toward the pointer, the caret on the side it moved to.
edit_select_unit :: proc(b: ^Edit_Buffer, from, to: int, unit: Edit_Unit, at: int) {
	start, end := edit_unit_at(b, at, unit)
	if start < from {
		b.anchor, b.caret = to, start
	} else {
		b.anchor, b.caret = from, max(end, to)
	}
}

// Where Home takes the caret. `row_start` is the start of the row the caret is on, which differs from the
// line's start on a soft-wrapped line: the first press goes there. Then it toggles between the line's
// first character that is not a space or tab and its start.
@(require_results)
edit_home_target :: proc(b: ^Edit_Buffer, row_start: int) -> int {
	start := edit_line_start(b, b.caret)
	if row_start != start && b.caret != row_start {return row_start}
	end := edit_line_end(b, start)
	indent := start
	for indent < end && (b.text[indent] == ' ' || b.text[indent] == '\t') {indent += 1}
	return b.caret != indent && indent < end ? indent : start
}

// Where End takes the caret: `row_end` first, the last place the caret reaches on its soft-wrapped row,
// then the line's end.
@(require_results)
edit_end_target :: proc(b: ^Edit_Buffer, row_end: int) -> int {
	end := edit_line_end(b, b.caret)
	return row_end != end && b.caret != row_end ? row_end : end
}

// Replaces from..to with `text`, recorded for undo; the caret lands after the new text. A `run` joins
// the edit before it when it carries on where that one stopped.
@(require_results)
edit_replace :: proc(b: ^Edit_Buffer, start, stop: int, text: string, run := Edit_Run.None) -> bool {
	from, to := clamp(start, b.floor, len(b.text)), clamp(stop, b.floor, len(b.text))
	if from == to && text == "" {return true}
	removed := string(b.text[from:to])
	if !edit_join(b, from, to, removed, text, run) {
		edit := Edit {
			at            = from,
			caret_before  = b.caret,
			anchor_before = b.anchor,
			run           = run,
		}
		removed_error, inserted_error: mem.Allocator_Error
		edit.removed, removed_error = strings.clone(removed)
		edit.inserted, inserted_error = strings.clone(text)
		if removed_error != nil || inserted_error != nil {
			edit_free(edit)
			return false
		}
		if len(b.undo) >= UNDO_LIMIT {
			edit_free(b.undo[0])
			ordered_remove(&b.undo, 0)
		}
		if _, err := append(&b.undo, edit); err != nil {
			edit_free(edit)
			return false
		}
	}
	for edit in b.redo {edit_free(edit)}
	clear(&b.redo)
	if !edit_splice(b, from, to, text) {return false}
	b.caret = from + len(text)
	b.anchor = b.caret
	return true
}

// Extends the last edit with this one when both belong to one run of typing or deleting.
@(private)
edit_join :: proc(b: ^Edit_Buffer, from, to: int, removed, text: string, run: Edit_Run) -> bool {
	if run == .None || len(b.undo) == 0 || len(b.redo) > 0 {return false}
	last := &b.undo[len(b.undo) - 1]
	if last.run != run {return false}
	parts: [2]string
	switch run {
	case .None:
		return false
	case .Typing:
		// A space after a word starts the next undo step, so undo takes back a word at a time.
		if from != to || from != last.at + len(last.inserted) || last.inserted == "" {return false}
		if text == " " && !strings.has_suffix(last.inserted, " ") {return false}
		joined, err := strings.concatenate({last.inserted, text})
		if err != nil {return false}
		delete(last.inserted)
		last.inserted = joined
		return true
	case .Deleting:
		if text != "" || last.inserted != "" {return false}
		switch {
		case to == last.at:
			parts = {removed, last.removed}
		case from == last.at:
			parts = {last.removed, removed}
		case:
			return false
		}
	}
	joined, err := strings.concatenate(parts[:])
	if err != nil {return false}
	delete(last.removed)
	last.removed = joined
	last.at = min(last.at, from)
	return true
}

@(private, require_results)
edit_splice :: proc(b: ^Edit_Buffer, from, to: int, text: string) -> bool {
	removed := to - from
	grow := len(text) - removed
	old := len(b.text)
	if grow > 0 {
		if err := resize(&b.text, old + grow); err != nil {return false}
		copy(b.text[to + grow:], b.text[to:old])
	} else if grow < 0 {
		copy(b.text[from + len(text):], b.text[to:old])
		resize(&b.text, old + grow)
	}
	copy(b.text[from:], text)
	b.revision += 1
	return true
}

// Inserts at the caret over the selection. Typing joins one undo step with the characters before it.
@(require_results)
edit_insert :: proc(b: ^Edit_Buffer, text: string, typing := false) -> bool {
	from, to := edit_selection(b)
	return edit_replace(b, from, to, text, typing && from == to ? .Typing : .None)
}

// Deletes the selection, or the character (`word`: word) before or after the caret.
@(require_results)
edit_delete :: proc(b: ^Edit_Buffer, forward, word: bool) -> bool {
	from, to := edit_selection(b)
	if from == to {
		if forward {
			to = word ? edit_word_right(b, b.caret) : edit_right(b, b.caret)
		} else {
			from = word ? edit_word_left(b, b.caret) : edit_left(b, b.caret)
		}
		if from == to {return true}
		return edit_replace(b, from, to, "", .Deleting)
	}
	return edit_replace(b, from, to, "")
}

@(require_results)
edit_undo :: proc(b: ^Edit_Buffer) -> bool {
	if len(b.undo) == 0 {return false}
	edit := pop(&b.undo)
	if !edit_splice(b, edit.at, edit.at + len(edit.inserted), edit.removed) {
		append(&b.undo, edit)
		return false
	}
	if _, err := append(&b.redo, edit); err != nil {edit_free(edit)}
	b.caret, b.anchor = edit.caret_before, edit.anchor_before
	return true
}

@(require_results)
edit_redo :: proc(b: ^Edit_Buffer) -> bool {
	if len(b.redo) == 0 {return false}
	edit := pop(&b.redo)
	if !edit_splice(b, edit.at, edit.at + len(edit.removed), edit.inserted) {
		append(&b.redo, edit)
		return false
	}
	edit.run = .None
	if _, err := append(&b.undo, edit); err != nil {edit_free(edit)}
	b.caret = edit.at + len(edit.inserted)
	b.anchor = b.caret
	return true
}

// What starts a line before its text: indentation, quote markers and a list item's marker and
// checkbox, as Enter continues them.
@(private)
Line_Prefix :: struct {
	// Through the quote markers; through the list marker and checkbox.
	quote_end, end: int,
	bullet:         bool,
	// An ordered item's number and its delimiter, '.' or ')'.
	number:         int,
	delimiter:      u8,
	task:           bool,
}

@(private)
line_prefix :: proc(line: string) -> Line_Prefix {
	p: Line_Prefix
	i := 0
	for {
		j := i
		for j < len(line) && (line[j] == ' ' || line[j] == '\t') {j += 1}
		if j < len(line) && line[j] == '>' {
			i = j + 1
			if i < len(line) && line[i] == ' ' {i += 1}
			continue
		}
		break
	}
	p.quote_end, p.end = i, i
	j := i
	for j < len(line) && (line[j] == ' ' || line[j] == '\t') {j += 1}
	marker_end := -1
	if j < len(line) && (line[j] == '-' || line[j] == '*' || line[j] == '+') {
		marker_end, p.bullet = j + 1, true
	} else {
		k := j
		number := 0
		for k < len(line) && k - j < 9 && line[k] >= '0' && line[k] <= '9' {
			number = number * 10 + int(line[k] - '0')
			k += 1
		}
		if k > j && k < len(line) && (line[k] == '.' || line[k] == ')') {
			marker_end, p.number, p.delimiter = k + 1, number, line[k]
		}
	}
	if marker_end < 0 || (marker_end < len(line) && line[marker_end] != ' ' && line[marker_end] != '\t') {
		p.bullet, p.delimiter = false, 0
		return p
	}
	p.end = min(marker_end + 1, len(line))
	rest := line[p.end:]
	mark := len(rest) >= 3 && rest[0] == '[' && rest[2] == ']' && strings.index_byte(" xX", rest[1]) >= 0
	if mark && (len(rest) == 3 || rest[3] == ' ') {
		p.task = true
		p.end += min(4, len(rest))
	}
	return p
}

// Enter: a new line that continues the caret's list item or quote. On an item with nothing after its
// marker, Enter ends the list instead, leaving the line blank.
@(require_results)
edit_newline :: proc(b: ^Edit_Buffer) -> bool {
	from, to := edit_selection(b)
	start := edit_line_start(b, from)
	line := string(b.text[start:edit_line_end(b, from)])
	p := line_prefix(line)
	listed := p.bullet || p.delimiter != 0
	if from - start < p.end || (!listed && p.quote_end == 0) {return edit_replace(b, from, to, b.newline)}
	if strings.trim_space(line[p.end:]) == "" && from == to {
		return edit_replace(b, start, start + len(line), "")
	}
	next := strings.builder_make(context.temp_allocator)
	strings.write_string(&next, b.newline)
	if !listed {
		strings.write_string(&next, line[:p.quote_end])
		return edit_replace(b, from, to, strings.to_string(next))
	}
	marker := strings.trim_left(line[p.quote_end:p.end], " \t")
	// The quote markers, then the item's own indentation.
	strings.write_string(&next, line[:p.end - len(marker)])
	if p.bullet {
		strings.write_byte(&next, marker[0])
		strings.write_byte(&next, ' ')
	} else {
		strings.write_int(&next, p.number + 1)
		strings.write_byte(&next, p.delimiter)
		strings.write_byte(&next, ' ')
	}
	if p.task {strings.write_string(&next, "[ ] ")}
	return edit_replace(b, from, to, strings.to_string(next))
}

// Tab and Shift+Tab: indents the lines the selection touches by one tab, or takes one level of
// indentation (a tab or up to four spaces) away. A tab with nothing selected outside a list item is
// typed.
@(require_results)
edit_indent :: proc(b: ^Edit_Buffer, outdent: bool) -> bool {
	from, to := edit_selection(b)
	first := edit_line_start(b, from)
	if !outdent && from == to {
		p := line_prefix(string(b.text[first:edit_line_end(b, from)]))
		if !p.bullet && p.delimiter == 0 {return edit_replace(b, from, to, "\t", .Typing)}
	}
	// A selection that ends at the very start of a line leaves that line alone.
	last := to > from && b.text[to - 1] == '\n' ? to - 1 : to
	last_end := edit_line_end(b, last)
	out := strings.builder_make(context.temp_allocator)
	caret, anchor := b.caret, b.anchor
	// Where the caret and anchor go: they move with their line's text, one at a line's start stays
	// there, and one inside indentation that goes lands where the line's text now starts.
	moved :: proc(offset, at, line_end, removed, shift: int, outdent: bool) -> (int, bool) {
		if offset < at || offset > line_end {return offset, false}
		if offset == at {return offset + shift, true}
		return offset + shift + (outdent ? -min(removed, offset - at) : 1), true
	}
	new_caret, new_anchor := caret, anchor
	shift := 0
	at := first
	for {
		newline := strings.index_byte(string(b.text[at:last_end]), '\n')
		line_end := newline < 0 ? last_end : at + newline
		line := string(b.text[at:line_end])
		removed := 0
		if outdent {
			if strings.has_prefix(line, "\t") {
				removed = 1
			} else {
				for removed < len(line) && removed < 4 && line[removed] == ' ' {removed += 1}
			}
			strings.write_string(&out, line[removed:])
		} else {
			strings.write_byte(&out, '\t')
			strings.write_string(&out, line)
		}
		if next, ok := moved(caret, at, line_end, removed, shift, outdent); ok {new_caret = next}
		if next, ok := moved(anchor, at, line_end, removed, shift, outdent); ok {new_anchor = next}
		shift += outdent ? -removed : 1
		if newline < 0 {break}
		strings.write_byte(&out, '\n')
		at = line_end + 1
	}
	if !edit_replace(b, first, last_end, strings.to_string(out)) {return false}
	b.caret, b.anchor = edit_clamp(b, new_caret), edit_clamp(b, new_anchor)
	return true
}

// Ticks or clears the task whose mark sits at `mark`, as one undoable edit that leaves the caret be.
@(require_results)
edit_task_toggle :: proc(b: ^Edit_Buffer, mark: int) -> bool {
	if mark < b.floor || mark >= len(b.text) {return false}
	caret, anchor := b.caret, b.anchor
	next := b.text[mark] == ' ' ? "x" : " "
	if !edit_replace(b, mark, mark + 1, next) {return false}
	b.caret, b.anchor = caret, anchor
	return true
}

// The file's text with the task mark at `mark` flipped, for a pane that is not editing; false when
// `mark` is not a task's mark.
task_mark_flip :: proc(text: []u8, mark: int) -> bool {
	if mark < 1 || mark + 1 >= len(text) || text[mark - 1] != '[' || text[mark + 1] != ']' {return false}
	switch text[mark] {
	case ' ':
		text[mark] = 'x'
	case 'x', 'X':
		text[mark] = ' '
	case:
		return false
	}
	return true
}
