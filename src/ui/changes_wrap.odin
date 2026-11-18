package ui

import "aio:font"
import tr "aio:turns"

// Soft wrap, the other way to show a code line wider than its cell (turns.diff_long_lines = wrap). A line
// breaks where its text runs out of room, a rune at a time, and each piece takes a line of its own, so a
// row is as tall as the lines its taller side wraps to. Only the first piece carries the numbers and the
// sign. Nothing scrolls sideways. The table of heights is rebuilt only when the diff, the width, the scale
// or the font change, into buffers that are kept, and a line of plain printable ASCII in a monospace font
// is counted by its length alone, so a resize costs one step per row and a walk only for the odd line.

// What the wrap table holds and was built for.
Changes_Wrap :: struct {
	// Whether the table matches the rows of the pairs it was built beside: while it does not, every row
	// is one line.
	valid:                         bool,
	// The length of each line of every file in order (a flat line of file i is at file_lines[i] + line) when
	// it is plain printable ASCII, else -1: such a line wraps by arithmetic. Built once per diff.
	plain:                         [dynamic]i32,
	plain_built:                   bool,
	plain_revision:                u64,
	plain_files:                   int,
	// What the heights were built for.
	built, side_by_side:           bool,
	revision:                      u64,
	files:                         int,
	band, scale, size:             f32,
	family:                        font.Family,
	// The lines of text each pair row takes, as running totals: before[k] is how many lines the rows
	// before pair k of every file in order take, one entry longer than the pairs.
	before:                        [dynamic]i32,
	// The lines each hunk's header takes beyond its first, in hunk order across the files.
	head:                          [dynamic]i32,
}

@(private)
wrap_valid :: proc(rows: ^Changes_Rows) -> bool {
	return rows.wrapped && rows.wrap.valid
}

@(private)
wrap_free :: proc(w: ^Changes_Wrap) {
	delete(w.plain)
	delete(w.before)
	delete(w.head)
	w^ = {}
}

// The length of `s` when every byte is printable ASCII, else -1.
@(private = "file")
plain_length :: proc(s: string) -> i32 {
	for b in transmute([]u8)s {
		if b < 0x20 || b >= 0x7F {return -1}
	}
	return i32(len(s))
}

// How many columns of a monospace font's cells a wrapped row holds in `room`.
@(private)
code_cols :: proc(f: Code_Font, room: f32) -> int {
	if f.cell <= 0 {return 1}
	limit := room + CODE_EDGE
	cols := max(1, int(limit / f.cell))
	for f32(cols + 1) * f.cell <= limit {cols += 1}
	for cols > 1 && f32(cols) * f.cell > limit {cols -= 1}
	return cols
}

// How many lines `text` takes in `room`; `plain` is its length when it is printable ASCII, else -1.
@(private)
wrap_line_rows :: proc(t: ^Text, f: Code_Font, text: string, plain: int, room: f32) -> int {
	if len(text) == 0 {return 1}
	if f.mono && plain >= 0 {
		cols := code_cols(f, room)
		return (plain + cols - 1) / cols
	}
	rows, start := 0, 0
	for start < len(text) {
		start += code_fit(t, f, text[start:], room)
		rows += 1
	}
	return max(1, rows)
}

// The bytes of line `k` of `text` in `room`; an empty range at the end past the last line.
@(private)
wrap_row :: proc(t: ^Text, f: Code_Font, text: string, plain: int, room: f32, k: int) -> (start, end: int) {
	if f.mono && plain >= 0 {
		cols := code_cols(f, room)
		start = min(k * cols, len(text))
		return start, min(start + cols, len(text))
	}
	for _ in 0 ..< k {
		if start >= len(text) {break}
		start += code_fit(t, f, text[start:], room)
	}
	if start < len(text) {end = start + code_fit(t, f, text[start:], room)} else {end = start}
	return
}

// The line of `text` the boundary at byte `offset` is on, and its bytes: a boundary between two lines is the
// start of the second, and the end of the text is the end of the last.
@(private)
wrap_row_of :: proc(
	t: ^Text, f: Code_Font, text: string, plain: int, room: f32, offset: int,
) -> (
	k, start, end: int,
) {
	for {
		start, end = wrap_row(t, f, text, plain, room, k)
		if offset < end || end >= len(text) {return}
		k += 1
	}
}

// How many lines the header of hunk `h` takes in `room`: its label, a space and its section, the section
// continuing on lines of their own from the left.
@(private)
head_rows :: proc(t: ^Text, f: Code_Font, h: ^tr.Hunk, room: f32) -> int {
	if h.section == "" {return 1}
	buf: [CHANGES_HUNK_LABEL_BYTES]u8
	after := code_width(t, f, hunk_label(buf[:], h)) + f.cell
	rest := h.section
	if room - after >= f.cell {rest = rest[code_fit(t, f, rest, room - after):]}
	rows := 1
	for len(rest) > 0 {
		rest = rest[code_fit(t, f, rest, room):]
		rows += 1
	}
	return rows
}

// The plain length of flat line `line` of `file`, -1 when the line is not plain or unknown.
@(private)
wrap_plain :: proc(rows: ^Changes_Rows, file, line: int) -> int {
	t, w := &rows.pairs, &rows.wrap
	if file < 0 || file >= len(t.file_lines) || line < 0 {return -1}
	at := t.file_lines[file] + line
	return at < len(w.plain) ? int(w.plain[at]) : -1
}

// Lays the wrap table out for the rows `changes_pairs_build` just made, unless it already is for them at this
// width, scale and font. `band` is the width every row fills.
@(private)
changes_wrap_build :: proc(rows: ^Changes_Rows, view: ^Changes_View, mono: ^Text, band: f32) {
	w, t := &rows.wrap, &rows.pairs
	if !rows.wrapped {
		w.built, w.valid = false, false
		return
	}
	if !(w.plain_built && w.plain_revision == view.revision && w.plain_files == len(view.files)) {
		w.plain_built, w.plain_revision, w.plain_files = true, view.revision, len(view.files)
		clear(&w.plain)
		for &file in view.files {
			for &hunk in file.hunks {
				for &line in hunk.lines {
					text := line.kind == .No_Newline ? CHANGES_NO_NEWLINE : line.text
					if _, err := append(&w.plain, plain_length(text)); err != nil {w.plain_built = false}
				}
			}
		}
	}
	if w.built && w.revision == view.revision && w.files == len(view.files) &&
	   w.side_by_side == t.side_by_side && w.band == band && w.scale == rows.scale && w.size == mono.size_px &&
	   w.family == mono.family {return}
	w.built, w.revision, w.files, w.side_by_side = true, view.revision, len(view.files), t.side_by_side
	w.band, w.scale, w.size, w.family = band, rows.scale, mono.size_px, mono.family
	clear(&w.before)
	clear(&w.head)
	w.valid = false
	if len(t.file_pairs) != len(view.files) + 1 || len(t.file_hunks) != len(view.files) {return}
	f := code_font(mono)
	if _, err := append(&w.before, 0); err != nil {return}
	for &file, i in view.files {
		room, head := code_room(rows, &file, band), head_room(rows, band)
		pair, line0, flat := t.file_pairs[i], t.file_lines[i], 0
		for &hunk, h in file.hunks {
			if _, err := append(&w.head, i32(head_rows(mono, f, &hunk, head) - 1)); err != nil {return}
			stop := t.hunk_pairs[t.file_hunks[i] + h + 1]
			for ; pair < stop; pair += 1 {
				p := t.pairs[pair]
				n := 1
				for side in ([2]i32{p.left, p.right}) {
					at := int(side) - flat
					if side < 0 || at < 0 || at >= len(hunk.lines) {continue}
					text := hunk.lines[at].kind == .No_Newline ? CHANGES_NO_NEWLINE : hunk.lines[at].text
					plain := line0 + int(side) < len(w.plain) ? int(w.plain[line0 + int(side)]) : -1
					n = max(n, wrap_line_rows(mono, f, text, plain, room))
				}
				if _, err := append(&w.before, w.before[len(w.before) - 1] + i32(n)); err != nil {return}
			}
			flat += len(hunk.lines)
		}
	}
	w.valid = len(w.before) == len(t.pairs) + 1
}
