package markdown

import "cosmos:textedit"
import "core:strings"

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
edit_newline :: proc(b: ^textedit.Buffer) -> bool {
	from, to := textedit.selection(b)
	start := textedit.line_start(b, from)
	line := string(b.text[start:textedit.line_end(b, from)])
	p := line_prefix(line)
	listed := p.bullet || p.delimiter != 0
	if from - start < p.end || (!listed && p.quote_end == 0) {return textedit.replace(b, from, to, b.newline)}
	if strings.trim_space(line[p.end:]) == "" && from == to {
		return textedit.replace(b, start, start + len(line), "")
	}
	next := strings.builder_make(context.temp_allocator)
	strings.write_string(&next, b.newline)
	if !listed {
		strings.write_string(&next, line[:p.quote_end])
		return textedit.replace(b, from, to, strings.to_string(next))
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
	return textedit.replace(b, from, to, strings.to_string(next))
}

// Tab and Shift+Tab: indents the lines the selection touches by one tab, or takes one level of
// indentation (a tab or up to four spaces) away. A tab with nothing selected outside a list item is
// typed.
@(require_results)
edit_indent :: proc(b: ^textedit.Buffer, outdent: bool) -> bool {
	from, to := textedit.selection(b)
	first := textedit.line_start(b, from)
	if !outdent && from == to {
		p := line_prefix(string(b.text[first:textedit.line_end(b, from)]))
		if !p.bullet && p.delimiter == 0 {return textedit.replace(b, from, to, "\t", .Typing)}
	}
	// A selection that ends at the very start of a line leaves that line alone.
	last := to > from && b.text[to - 1] == '\n' ? to - 1 : to
	last_end := textedit.line_end(b, last)
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
	if !textedit.replace(b, first, last_end, strings.to_string(out)) {return false}
	b.caret, b.anchor = textedit.clamp_offset(b, new_caret), textedit.clamp_offset(b, new_anchor)
	return true
}

// Ticks or clears the task whose mark sits at `mark`, as one undoable edit that leaves the caret be.
@(require_results)
edit_task_toggle :: proc(b: ^textedit.Buffer, mark: int) -> bool {
	if mark < b.floor || mark >= len(b.text) {return false}
	caret, anchor := b.caret, b.anchor
	next := b.text[mark] == ' ' ? "x" : " "
	if !textedit.replace(b, mark, mark + 1, next) {return false}
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
