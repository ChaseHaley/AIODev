package ui

import "aio:colour"
import "aio:render"
import "aio:syntax"
import tr "aio:turns"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:strconv"

@(private = "file")
CHANGES_STATUS_WIDTH :: f32(16)
@(private = "file")
CHANGES_SEND_BAR_HEIGHT :: f32(40)
// The Send, Copy and Discard buttons share one width, so hit tests need no text metrics.
@(private = "file")
CHANGES_ACTION_WIDTH :: f32(72)
@(private = "file")
CHANGES_DETACHED_LABEL :: "Not in this diff"

// The terminal palette entry each token kind takes; -1 is the theme's text colour.
CHANGES_SYNTAX_PALETTE :: [syntax.Token_Kind]int {
	.Plain     = -1,
	.Keyword   = 5,
	.Type      = 6,
	.Function  = 4,
	.String    = 2,
	.Number    = 3,
	.Constant  = 3,
	.Comment   = 8,
	.Operator  = -1,
	.Attribute = 4,
	.Tag       = 1,
}

// The diff body of file `i`: its hunks' header rows, their rows, and the comment cards below the rows.
@(private)
file_body_height :: proc(rows: ^Changes_Rows, view: ^Changes_View, i: int) -> int {
	f := &view.files[i]
	if f.binary || len(f.hunks) == 0 {return rows.note}
	total := 0
	for h in 0 ..< len(f.hunks) {total += hunk_height(rows, view, i, h)}
	return total
}

// How many lines of text row `row` of `file` takes: one, or as many as its taller side wraps to.
@(private)
row_text_lines :: proc(rows: ^Changes_Rows, file, row: int) -> int {
	if !wrap_valid(rows) || file < 0 || file + 1 >= len(rows.pairs.file_pairs) || row < 0 {return 1}
	at := rows.pairs.file_pairs[file] + row
	if at + 1 >= len(rows.wrap.before) {return 1}
	return int(rows.wrap.before[at + 1] - rows.wrap.before[at])
}

// How many lines of text the rows of `file` before row `row` take; `row` may be one past the last.
@(private)
lines_before :: proc(rows: ^Changes_Rows, file, row: int) -> int {
	if !wrap_valid(rows) || file < 0 || file + 1 >= len(rows.pairs.file_pairs) {return row}
	at := rows.pairs.file_pairs[file]
	if at + row >= len(rows.wrap.before) {return row}
	return int(rows.wrap.before[at + row] - rows.wrap.before[at])
}

// A row's height, a line's height for each line it wraps to.
@(private)
row_height :: proc(rows: ^Changes_Rows, file, row: int) -> int {
	return row_text_lines(rows, file, row) * rows.line
}

// The height of hunk `h`'s header row: one line, and one more for each line its section wraps onto.
@(private)
hunk_head :: proc(rows: ^Changes_Rows, file, h: int) -> int {
	if !wrap_valid(rows) || file < 0 || file >= len(rows.pairs.file_hunks) || h < 0 {return rows.hunk}
	at := rows.pairs.file_hunks[file] + h
	if at >= len(rows.wrap.head) {return rows.hunk}
	return rows.hunk + int(rows.wrap.head[at]) * rows.line
}

// Hunk `h` of `file`: its header, its rows and the cards below them.
@(private)
hunk_height :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, h: int) -> int {
	base, count := hunk_rows(rows, file, h)
	text := lines_before(rows, file, base + count) - lines_before(rows, file, base)
	return hunk_head(rows, file, h) + text * rows.line + cards_through(rows, view, file, base, base + count - 1)
}

// One row of a hunk: the flat lines of its left and right cells, -1 for a blank cell. A unified row holds
// its one line on both sides.
Changes_Pair :: struct {
	left, right: i32,
}

// The rows of every file in hunk order, in the layout `side_by_side` names, and the row of each flat line.
// changes_layout builds it with the rest of the rows cache, but only when the diff or the layout changed:
// `revision` and `files` are the view's at the last build.
Changes_Pairs :: struct {
	built, side_by_side:    bool,
	revision:               u64,
	files:                  int,
	pairs:                  [dynamic]Changes_Pair,
	// Per file, then the end: where its rows start in `pairs` and its flat lines in `line_rows`.
	file_pairs, file_lines: [dynamic]int,
	// Per hunk of every file in order, then the end: where its rows start in `pairs`. File i's hunks start
	// at hunk_pairs[file_hunks[i]].
	hunk_pairs, file_hunks: [dynamic]int,
	// The row of each flat line within its file's rows.
	line_rows:              [dynamic]i32,
	// The row each card sits under, parallel to rows.cards, and the row the selection ends on: the lowest
	// row holding any of their lines, or -1. Side by side that need not be the last line's row. They follow
	// the comments, so changes_cards_measure refreshes them on every layout.
	card_rows:              [dynamic]int,
	selection_row:          int,
}

@(private)
changes_pairs_destroy :: proc(t: ^Changes_Pairs) {
	delete(t.pairs)
	delete(t.file_pairs)
	delete(t.file_lines)
	delete(t.hunk_pairs)
	delete(t.file_hunks)
	delete(t.line_rows)
	delete(t.card_rows)
	t^ = {}
}

// Emits a gap between matched replacements, padding the shorter side. The order of the lines
// on each side stays the same for scrolling, selection and comments.
@(private = "file", require_results)
append_gap :: proc(t: ^Changes_Pairs, base, left, old_end, right, new_end: int) -> bool {
	for k in 0 ..< max(old_end - left, new_end - right) {
		pair := Changes_Pair{-1, -1}
		if left + k < old_end {pair.left = i32(base + left + k)}
		if right + k < new_end {pair.right = i32(base + right + k)}
		if _, err := append(&t.pairs, pair); err != nil {return false}
	}
	return true
}

@(private = "file", require_results)
hunk_pairs_append :: proc(t: ^Changes_Pairs, h: ^tr.Hunk, base: int) -> bool {
	lines := h.lines
	if !t.side_by_side {
		for i in 0 ..< len(lines) {
			line := i32(base + i)
			if _, err := append(&t.pairs, Changes_Pair{line, line}); err != nil {return false}
		}
		return true
	}
	i := 0
	edit_at := 0
	for i < len(lines) {
		#partial switch lines[i].kind {
		case .Removed, .Added:
			old_end, added, new_end, next := tr.diff_change_block(lines, i)
			left, right := i, added
			for edit_at < len(h.edits) && h.edits[edit_at].left < old_end {
				edit := h.edits[edit_at]
				append_gap(t, base, left, edit.left, right, edit.right) or_return
				pair := Changes_Pair{i32(base + edit.left), i32(base + edit.right)}
				if _, err := append(&t.pairs, pair); err != nil {return false}
				left, right = edit.left + 1, edit.right + 1
				edit_at += 1
			}
			append_gap(t, base, left, old_end, right, new_end) or_return
			append_gap(t, base, old_end, added, new_end, next) or_return
			i = next
		case:
			line := i32(base + i)
			if _, err := append(&t.pairs, Changes_Pair{line, line}); err != nil {return false}
			i += 1
		}
	}
	return true
}

// Lays out every file's rows for `view.side_by_side`, unless they already are for this diff. Out of
// memory, the table is left empty, and every file shows its header and hunk headers without rows.
@(private)
changes_pairs_build :: proc(t: ^Changes_Pairs, view: ^Changes_View) {
	if t.built && t.revision == view.revision && t.files == len(view.files) &&
	   t.side_by_side == view.side_by_side {return}
	t.built, t.revision, t.files, t.side_by_side = true, view.revision, len(view.files), view.side_by_side
	clear(&t.pairs)
	clear(&t.file_pairs)
	clear(&t.file_lines)
	clear(&t.hunk_pairs)
	clear(&t.file_hunks)
	clear(&t.line_rows)
	if !pairs_fill(t, view) {
		clear(&t.pairs)
		clear(&t.file_pairs)
		clear(&t.file_lines)
		clear(&t.hunk_pairs)
		clear(&t.file_hunks)
		clear(&t.line_rows)
	}
}

@(private = "file", require_results)
pairs_fill :: proc(t: ^Changes_Pairs, view: ^Changes_View) -> bool {
	for &f in view.files {
		first, lines := len(t.pairs), len(t.line_rows)
		if _, err := append(&t.file_pairs, first); err != nil {return false}
		if _, err := append(&t.file_lines, lines); err != nil {return false}
		if _, err := append(&t.file_hunks, len(t.hunk_pairs)); err != nil {return false}
		count := 0
		for &hunk in f.hunks {
			if _, err := append(&t.hunk_pairs, len(t.pairs)); err != nil {return false}
			hunk_pairs_append(t, &hunk, count) or_return
			count += len(hunk.lines)
		}
		if resize(&t.line_rows, lines + count) != nil {return false}
		rows := t.line_rows[lines:]
		for pair, row in t.pairs[first:] {
			if pair.left >= 0 {rows[pair.left] = i32(row)}
			if pair.right >= 0 {rows[pair.right] = i32(row)}
		}
	}
	if _, err := append(&t.file_pairs, len(t.pairs)); err != nil {return false}
	if _, err := append(&t.file_lines, len(t.line_rows)); err != nil {return false}
	_, err := append(&t.hunk_pairs, len(t.pairs))
	return err == nil
}

// How many rows file `file` has.
@(private = "file")
file_row_count :: proc(rows: ^Changes_Rows, file: int) -> int {
	t := &rows.pairs
	if file < 0 || file + 1 >= len(t.file_pairs) {return 0}
	return t.file_pairs[file + 1] - t.file_pairs[file]
}

// Hunk `h` of `file`: its first row within the file's rows, and how many rows it has.
@(private = "file")
hunk_rows :: proc(rows: ^Changes_Rows, file, h: int) -> (base, count: int) {
	t := &rows.pairs
	if file < 0 || file >= len(t.file_hunks) || h < 0 {return}
	at := t.file_hunks[file] + h
	if at + 1 >= len(t.hunk_pairs) {return}
	first := t.hunk_pairs[at]
	return first - t.file_pairs[file], t.hunk_pairs[at + 1] - first
}

// Row `row` of `file`; both cells blank when there is none.
@(private = "file")
row_pair :: proc(rows: ^Changes_Rows, file, row: int) -> Changes_Pair {
	if row < 0 || row >= file_row_count(rows, file) {return {-1, -1}}
	return rows.pairs.pairs[rows.pairs.file_pairs[file] + row]
}

// The row that holds flat line `line` of `file`, -1 when there is none.
@(private)
line_row :: proc(rows: ^Changes_Rows, file, line: int) -> int {
	t := &rows.pairs
	if file < 0 || file + 1 >= len(t.file_lines) || line < 0 {return -1}
	at := t.file_lines[file] + line
	if at >= t.file_lines[file + 1] {return -1}
	return int(t.line_rows[at])
}

@(private = "file")
DIFF_MIN_SIDE :: f32(96)

// Give the one-pixel line a larger hit target without swallowing the right line-number gutter.
@(private = "file")
DIFF_SPLIT_GRAB_LEFT :: f32(10)
@(private = "file")
DIFF_SPLIT_GRAB_RIGHT :: f32(2)

@(private = "file")
split_min :: proc(band, scale: f32) -> f32 {
	return min(math.ceil(DIFF_MIN_SIDE * scale), math.floor(max(0, band - 1) / 2))
}

@(private = "file")
split_adjustable :: proc(band, scale: f32) -> bool {
	return band >= 2 * math.ceil(DIFF_MIN_SIDE * scale) + 2
}

@(private)
split_position :: proc(band, scale, fraction: f32) -> f32 {
	minimum := split_min(band, scale)
	room := max(0, band - 1)
	return clamp(math.round(room * (fraction == 0 ? 0.5 : fraction)), minimum, room - minimum)
}

// The cells of a row, either side of a one-pixel divider. Layout caches the same pixel position
// for measuring, painting and hit testing.
@(private)
row_halves :: proc(row: render.Rect, left_width: f32) -> (left, right, divider: render.Rect) {
	mid := row.x + left_width
	left = {row.x, row.y, left_width, row.height}
	divider = {mid, row.y, min(1, row.width), row.height}
	right = {mid + divider.width, row.y, max(0, row.width - left_width - divider.width), row.height}
	return
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

// Whether comment `i` shows below its lines rather than in the "Not in this diff" group. Under a notice
// no lines show, so every comment is in the group.
@(private)
comment_attached :: proc(view: ^Changes_View, i: int) -> bool {
	c := view.comments[i]
	return view.notice == .None && !c.detached && c.file >= 0 && c.file < len(view.files)
}

// Whether the new-comment editor is open below the selection.
@(private = "file")
writing_new :: proc(view: ^Changes_View) -> bool {
	s := view.selection
	return view.editing == len(view.comments) && s.active && s.file >= 0 && s.file < len(view.files)
}

// Cards are numbered like rows.cards: comment i is card i, the new-comment editor is len(view.comments).
// The file a card shows in, -1 for a detached comment or no new comment.
@(private = "file")
card_file :: proc(view: ^Changes_View, card: int) -> int {
	if card < len(view.comments) {return comment_attached(view, card) ? view.comments[card].file : -1}
	return writing_new(view) ? view.selection.file : -1
}

// The row a card sits under, from the latest changes_cards_measure; -1 when it is not in a file.
@(private = "file")
card_row :: proc(rows: ^Changes_Rows, card: int) -> int {
	return card < len(rows.pairs.card_rows) ? rows.pairs.card_rows[card] : -1
}

// The lowest row of `file` that holds any of flat lines `first` through `last`; -1 for none.
@(private = "file")
range_row :: proc(rows: ^Changes_Rows, file, first, last: int) -> int {
	row := -1
	for line in min(first, last) ..= max(first, last) {row = max(row, line_row(rows, file, line))}
	return row
}

// A card's height with the gap above it, where its notch points at its lines, and below it; zero for a card
// that is not shown.
@(private = "file")
card_slot :: proc(rows: ^Changes_Rows, card: int) -> int {
	if card >= len(rows.cards) || rows.cards[card] <= 0 {return 0}
	return rows.cards[card] + card_gap_above(rows) + card_gap_below(rows)
}

@(private = "file")
card_gap_above :: proc(rows: ^Changes_Rows) -> int {
	return int(math.round(CHANGES_CARD_GAP_ABOVE * rows.scale))
}

@(private = "file")
card_gap_below :: proc(rows: ^Changes_Rows) -> int {
	return int(math.round(CHANGES_CARD_GAP_BELOW * rows.scale))
}

// The height of the cards below rows `low` through `high` of `file`.
@(private = "file")
cards_through :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, low, high: int) -> int {
	if high < low {return 0}
	total := 0
	for card in 0 ..= len(view.comments) {
		if card_file(view, card) != file {continue}
		if row := card_row(rows, card); row >= low && row <= high {total += card_slot(rows, card)}
	}
	return total
}

// What the cards' layout depends on besides the diff: the notes, which one is edited and its tag, and the
// selection's lines, which a new note goes below. Part of the rows cache key. What the editor's text does
// to the layout is only its card's height, which changes_layout compares apart (editor_stale), and a text
// selection's offsets move nothing, so typing and dragging do not lay the diff out again.
@(private)
changes_comments_key :: proc(view: ^Changes_View) -> u64 {
	mix :: proc(hash, value: u64) -> u64 {return (hash ~ value) * 1099511628211}
	mix_string :: proc(hash: u64, s: string) -> u64 {
		hash := hash
		for b in transmute([]u8)s {hash = mix(hash, u64(b))}
		return mix(hash, 0x100)
	}
	hash := u64(14695981039346656037)
	hash = mix(hash, u64(view.editing + 1))
	if view.editing >= 0 {hash = mix(hash, u64(view.draft))}
	hash = mix(hash, u64(len(view.comments)))
	for c in view.comments {
		hash = mix(mix(mix(hash, u64(c.file + 1)), u64(c.first + 1)), u64(c.last + 1))
		hash = mix(hash, c.detached ? 2 : 1)
		hash = mix(mix(hash, u64(c.kind)), c.partial ? 2 : 1)
		hash = mix(mix(hash, u64(c.first_offset)), u64(c.last_offset))
		hash = mix_string(mix_string(mix_string(hash, c.text), c.label_name), c.label_colour)
	}
	if s := view.selection; s.active {
		hash = mix(mix(mix(hash, u64(s.file + 1)), u64(s.first + 1)), u64(s.last + 1))
	}
	return hash
}

// Measures each card at the cached width, for changes_layout: comment i's card, then the new-comment
// editor's (zero when it is closed). The edited comment's card is the editor. Also finds the row each
// card and the selection end on.
@(private)
changes_cards_measure :: proc(rows: ^Changes_Rows, view: ^Changes_View, text, mono: ^Text) {
	clear(&rows.cards)
	clear(&rows.notes)
	virtual.arena_free_all(&rows.notes_arena)
	t := &rows.pairs
	clear(&t.card_rows)
	selection := view.selection
	t.selection_row = -1
	if selection.active {t.selection_row = range_row(rows, selection.file, selection.first, selection.last)}
	rows.tag_width = view.editing >= 0 ? editor_tag_width(view, text, rows.scale) : 0
	for c, i in view.comments {
		append(&t.card_rows, comment_attached(view, i) ? range_row(rows, c.file, c.first, c.last) : -1)
		if view.editing == i {
			append(&rows.cards, editor_height(rows, view, text, c.file))
			append(&rows.notes, Note_Plan{})
		} else {
			plan := note_measure(rows, view, c, text, mono)
			append(&rows.cards, int(math.round(plan.height)))
			append(&rows.notes, plan)
		}
	}
	writing := writing_new(view)
	append(&rows.cards, writing ? editor_height(rows, view, text, view.selection.file) : 0)
	append(&rows.notes, Note_Plan{})
	append(&t.card_rows, writing ? t.selection_row : -1)
}

// Whether the editor card is not the height it was measured at: the text typed into it changed how many
// lines it wraps to. Typing within a line leaves the cached rows as they are.
@(private)
editor_stale :: proc(rows: ^Changes_Rows, view: ^Changes_View, text: ^Text) -> bool {
	if view.editing < 0 || view.editing >= len(rows.cards) {return false}
	if view.editing == len(view.comments) && !writing_new(view) {return false}
	file := view.editing < len(view.comments) ? view.comments[view.editing].file : view.selection.file
	return rows.cards[view.editing] != editor_height(rows, view, text, file)
}

// The "Not in this diff" group at the end of the stream: a heading and the detached comments' cards.
@(private)
changes_detached_height :: proc(rows: ^Changes_Rows, view: ^Changes_View) -> int {
	total := 0
	for i in 0 ..< len(view.comments) {
		if !comment_attached(view, i) {total += card_slot(rows, i)}
	}
	if total == 0 {return 0}
	return rows.header + total + rows.gap
}

// What an overview tick marks.
Changes_Tick_Kind :: enum u8 {
	Added,
	Removed,
	Comment,
}

// A run of added or removed rows or a comment card, by its place in the stream, in whole pixels. A card's
// tick names its card, so the strip can colour it as the note is; the others hold -1.
Changes_Tick :: struct {
	y, height: i32,
	kind:      Changes_Tick_Kind,
	card:      i32,
}

// Adds a tick, or grows the one at `last` when `y` continues it; `last` follows the newest tick of its kind.
@(private = "file")
tick_add :: proc(rows: ^Changes_Rows, last: ^int, y, height: int, kind: Changes_Tick_Kind) {
	if last^ >= 0 {
		run := &rows.ticks[last^]
		if int(run.y) + int(run.height) == y {
			run.height += i32(height)
			return
		}
	}
	if _, err := append(&rows.ticks, Changes_Tick{i32(y), i32(height), kind, -1}); err == nil {
		last^ = len(rows.ticks) - 1
	}
}

// The kind of flat line `line` of a hunk whose first line is `flat`; Context for a blank cell.
@(private = "file")
tick_line_kind :: proc(lines: []tr.Diff_Line, flat: int, line: i32) -> tr.Line_Kind {
	at := int(line) - flat
	if line < 0 || at < 0 || at >= len(lines) {return .Context}
	return lines[at].kind
}

// Rebuilds the overview's ticks from the rows: for each expanded file, the runs of added and removed rows
// (a side-by-side row can carry both), then the comment cards. Runs that continue across rows are one tick.
// Called by changes_layout, so the strip never walks the diff while drawing.
@(private)
changes_ticks_build :: proc(rows: ^Changes_Rows, view: ^Changes_View) {
	clear(&rows.ticks)
	if view.notice != .None || len(rows.tops) != len(view.files) + 1 {return}
	for file in 0 ..< len(view.files) {
		f := &view.files[file]
		if changes_collapsed(view, file) || f.binary || len(f.hunks) == 0 {continue}
		y, flat := rows.tops[file] + rows.header, 0
		for &hunk, h in f.hunks {
			base, count := hunk_rows(rows, file, h)
			y += hunk_head(rows, file, h)
			added, removed := -1, -1
			for i in 0 ..< count {
				pair := row_pair(rows, file, base + i)
				height := row_height(rows, file, base + i)
				if tick_line_kind(hunk.lines, flat, pair.left) == .Removed {
					tick_add(rows, &removed, y, height, .Removed)
				}
				if tick_line_kind(hunk.lines, flat, pair.right) == .Added {
					tick_add(rows, &added, y, height, .Added)
				}
				y += height
				if len(view.comments) > 0 {y += cards_through(rows, view, file, base + i, base + i)}
			}
			flat += len(hunk.lines)
		}
	}
	for card in 0 ..< len(rows.cards) {
		top, shown := card_top(rows, view, card)
		if !shown {continue}
		_, _ = append(&rows.ticks, Changes_Tick{i32(top), i32(rows.cards[card]), .Comment, i32(card)})
	}
}

// Where row `i` of a hunk starts below the hunk's header: the rows above it and their cards. `base` is the
// hunk's first row in its file.
@(private = "file")
row_offset :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, base, i: int) -> int {
	before := lines_before(rows, file, base + i) - lines_before(rows, file, base)
	return before * rows.line + cards_through(rows, view, file, base, base + i - 1)
}

// The last row of a hunk of `count` rows that starts at or above `local`, which is measured from the
// hunk's first row; 0 above it.
@(private = "file")
hunk_row_at :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, base, count, local: int) -> int {
	low, high := 0, count - 1
	for low < high {
		mid := (low + high + 1) / 2
		if row_offset(rows, view, file, base, mid) <= local {low = mid} else {high = mid - 1}
	}
	return low
}

// The stream row where row `row` of `file` starts; false when the file is collapsed or has no such row.
@(private)
row_top :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, row: int) -> (y: int, ok: bool) {
	if file < 0 || file >= len(view.files) || file >= len(rows.tops) - 1 || row < 0 {return}
	if changes_collapsed(view, file) || view.files[file].binary {return}
	y = rows.tops[file] + rows.header
	for h in 0 ..< len(view.files[file].hunks) {
		base, count := hunk_rows(rows, file, h)
		if row < base + count {
			return y + hunk_head(rows, file, h) + row_offset(rows, view, file, base, row - base), true
		}
		y += hunk_height(rows, view, file, h)
	}
	return 0, false
}

// The row at the top of the diff and how far the top is below its start, found in the rows as they are, so
// that a change that rewraps them can put the same row back at the top. `row` is -1 for a point that is
// not in a row, which is held to its file's top; `offset` is negative above the first row of a hunk.
Changes_Anchor :: struct {
	ok:                 bool,
	file, row, offset:  int,
}

@(private)
changes_anchor_find :: proc(rows: ^Changes_Rows, view: ^Changes_View, scroll: int) -> Changes_Anchor {
	file := changes_file_at(rows, scroll)
	if file < 0 || file >= len(view.files) || file >= len(rows.tops) - 1 {return {}}
	top := rows.tops[file]
	f := &view.files[file]
	if changes_collapsed(view, file) || f.binary || scroll < top + rows.header {
		return {true, file, -1, scroll - top}
	}
	y := top + rows.header
	for h in 0 ..< len(f.hunks) {
		height := hunk_height(rows, view, file, h)
		if scroll < y + height {
			base, count := hunk_rows(rows, file, h)
			local := scroll - y - hunk_head(rows, file, h)
			if count == 0 {return {true, file, -1, scroll - top}}
			if local < 0 {return {true, file, base, local}}
			i := hunk_row_at(rows, view, file, base, count, local)
			return {true, file, base + i, local - row_offset(rows, view, file, base, i)}
		}
		y += height
	}
	return {true, file, -1, scroll - top}
}

// Where in the stream the anchor's row starts now, with its offset; false when its file or row is gone.
@(private)
changes_anchor_place :: proc(
	rows: ^Changes_Rows, view: ^Changes_View, a: Changes_Anchor,
) -> (
	at: int,
	ok: bool,
) {
	if a.file < 0 || a.file >= len(rows.tops) - 1 {return}
	if a.row < 0 {return rows.tops[a.file] + a.offset, true}
	y, found := row_top(rows, view, a.file, a.row)
	if !found {return rows.tops[a.file], true}
	return y + a.offset, true
}

// The stream row where card `card` starts: under the lowest row that holds any of its lines, after the
// cards of earlier comments under that row.
@(private = "file")
card_top :: proc(rows: ^Changes_Rows, view: ^Changes_View, card: int) -> (y: int, ok: bool) {
	if card < 0 || card >= len(rows.cards) || rows.cards[card] <= 0 {return}
	file := card_file(view, card)
	if file < 0 {
		if card >= len(view.comments) || rows.detached <= 0 {return}
		y = rows.total - rows.detached + rows.header
		for i in 0 ..< card {
			if !comment_attached(view, i) {y += card_slot(rows, i)}
		}
		return y + card_gap_above(rows), true
	}
	row := card_row(rows, card)
	y = row_top(rows, view, file, row) or_return
	y += row_height(rows, file, row)
	for i in 0 ..< card {
		if card_file(view, i) == file && card_row(rows, i) == row {y += card_slot(rows, i)}
	}
	return y + card_gap_above(rows), true
}

// Where card `card` is in the window, whatever the diff area shows of it; false when it is not in the stream.
changes_card_rect :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, card: int,
) -> (
	rect: render.Rect,
	shown: bool,
) {
	rows := &state.rows
	if !rows.valid {return}
	top := card_top(rows, view, card) or_return
	y := g.diff.y - f32(state.diff_scroll) + f32(top)
	span := card_span(rows, view, card_file(view, card))
	return {g.diff.x + span.x, y, span.width, f32(rows.cards[card])}, true
}

// `r` when any of it is in the diff area's height, else zero.
@(private = "file")
diff_visible :: proc(g: Changes_Geometry, r: render.Rect) -> render.Rect {
	if r.y + r.height <= g.diff.y || r.y >= g.diff.y + g.diff.height {return {}}
	return r
}

// The band every row of the stream fills: the diff area less its padding. The caller sets its y and height.
@(private)
diff_band :: proc(g: Changes_Geometry) -> render.Rect {
	pad := SPACE_2 * g.scale
	return {g.diff.x + pad, 0, max(0, g.diff.width - 2 * pad), 0}
}

// The divider's x in window pixels. Only the portions over code rows are painted and draggable.
changes_divider_rect :: proc(g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State) -> render.Rect {
	if !view.side_by_side || view.notice != .None || len(view.files) == 0 || !state.rows.valid {return {}}
	band := diff_band(g)
	if !split_adjustable(band.width, g.scale) {return {}}
	return {band.x + state.rows.split_left, g.diff.y, 1, g.diff.height}
}

// Keeps the point first grabbed on the divider under the pointer, and leaves both code cells usable.
changes_divider_move :: proc(state: ^Changes_State, g: Changes_Geometry, x: f32) -> bool {
	band := diff_band(g)
	if !split_adjustable(band.width, g.scale) {return false}
	minimum := split_min(band.width, g.scale)
	room := band.width - 1
	left := clamp(math.round(x - band.x), minimum, room - minimum)
	if left == state.rows.split_left {return false}
	state.split = left / room
	return true
}

// Which side a code cell belongs to, including either copy of a context line.
changes_cell_half :: proc(g: Changes_Geometry, state: ^Changes_State, cell: render.Rect) -> Changes_Half {
	if !state.rows.pairs.side_by_side {return .Both}
	return .Left if cell.x <= diff_band(g).x else .Right
}

// The row of the stream that starts at `top`, `height` tall, across the band.
@(private = "file")
row_rect :: proc(g: Changes_Geometry, state: ^Changes_State, top, height: int) -> render.Rect {
	band := diff_band(g)
	return {band.x, g.diff.y - f32(state.diff_scroll) + f32(top), band.width, f32(height)}
}

// The row of flat line `line` of `file` across the band; side by side, the cell that holds it, or the whole
// row for a context line, which fills both, unless `x` is given: then the half of it that `x` is in. Zero
// when the line has no row; not clipped to the diff area.
@(private = "file")
line_cell :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, file, line: int, x := f32(-1),
) -> render.Rect {
	rows := &state.rows
	if !rows.valid || view.notice != .None {return {}}
	row := line_row(rows, file, line)
	top, ok := row_top(rows, view, file, row)
	if !ok {return {}}
	rect := row_rect(g, state, top, row_height(rows, file, row))
	if rows.pairs.side_by_side {
		pair := row_pair(rows, file, row)
		left, right, _ := row_halves(rect, rows.split_left)
		if int(pair.right) != line {
			rect = left
		} else if int(pair.left) != line {
			rect = right
		} else if x >= 0 {
			rect = x >= right.x ? right : left
		}
	}
	return rect
}

// The row of flat line `line` of `file` across the file's card; side by side, the cell that holds it, or
// the whole row for a context line, which fills both. Zero when it is not on screen.
changes_line_rect :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, file, line: int,
) -> render.Rect {
	return diff_visible(g, line_cell(g, view, state, file, line))
}

// Where flat line `line` of `file` draws its text: the cell it sits in, as changes_line_rect gives it but
// wherever on the stream it is (a context line side by side takes the half that `x` is in, the left one
// without `x`), and the column of numbers, sign and text inside. The painter and a character hit test both
// read it, so a point maps to the character drawn there with code_offset_at. `mono` is the diff's text;
// false when the line has no row.
changes_line_code :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, mono: ^Text, file, line: int,
	x := f32(-1),
) -> (
	cell: render.Rect,
	column: Code_Column,
	ok: bool,
) {
	cell = line_cell(g, view, state, file, line, x)
	if cell.width <= 0 {return}
	digit := text_width(mono, "0")
	number := code_number_width(&view.files[file], digit)
	column = code_column(cell, number, digit, g.scale, !state.rows.pairs.side_by_side)
	column.scroll = f32(changes_h_columns(state, view, file, diff_band(g).width)) * digit
	return cell, column, true
}

// The diff_scroll that puts `file`'s header at the top of the diff, in either layout, or the current one
// for no such file. It reads the rows, so the pane lays out after unfolding the file and before asking.
// Clamped to the stream; changes_draw clamps it to the visible extent.
changes_diff_file_top :: proc(state: ^Changes_State, view: ^Changes_View, file: int) -> int {
	rows := &state.rows
	if !rows.valid || file < 0 || file >= len(view.files) || file >= len(rows.tops) - 1 {
		return state.diff_scroll
	}
	return clamp(rows.tops[file], 0, rows.total)
}

// The file whose header or body is at the top of the visible diff; -1 when none is.
changes_top_file :: proc(state: ^Changes_State, view: ^Changes_View) -> int {
	rows := &state.rows
	if !rows.valid || view.notice != .None {return -1}
	file := changes_file_at(rows, state.diff_scroll)
	if file >= len(view.files) || file >= len(rows.tops) - 1 {return -1}
	return file
}

// The file whose header is pinned at the top of the diff area, and where it is drawn: across the diff
// area, at its top, or above it as the end of its file's body pushes it up, so it leaves with the body and
// its border never lands on the next header. A header sticks while it has scrolled above the top and some
// of its file's body is still in view, so a collapsed file never does. `file` is -1 when none sticks.
changes_sticky_header :: proc(
	state: ^Changes_State, view: ^Changes_View, g: Changes_Geometry,
) -> (
	file: int,
	rect: render.Rect,
) {
	file = -1
	rows := &state.rows
	if !rows.valid || view.notice != .None || g.diff.height <= 0 {return}
	scroll := state.diff_scroll
	at := changes_file_at(rows, scroll)
	if at < 0 || at >= len(view.files) || at >= len(rows.tops) - 1 || changes_collapsed(view, at) {return}
	end := rows.tops[at + 1] - rows.gap
	if rows.tops[at] >= scroll || scroll >= end {return}
	y := g.diff.y + f32(min(0, end - scroll - rows.header))
	return at, {g.diff.x, y, g.diff.width, f32(rows.header)}
}

// The select button of a hunk header row, at its right end.
@(private = "file")
hunk_select_rect :: proc(header: render.Rect, scale: f32) -> render.Rect {
	size := header.height
	return {header.x + header.width - SPACE_1 * scale - size, header.y, size, size}
}

// The send bar's height: shown while there are comments.
changes_send_bar_height :: proc(view: ^Changes_View, scale: f32) -> f32 {
	return view.send.count > 0 ? math.round(CHANGES_SEND_BAR_HEIGHT * scale) : 0
}

// The send bar's buttons, from the right: Discard, Copy, Send. Zero without a bar.
changes_send_rects :: proc(g: Changes_Geometry, view: ^Changes_View) -> (send, copy, discard: render.Rect) {
	bar := g.send_bar
	if bar.height <= 0 || bar.width <= 0 {return}
	s := g.scale
	width, height, gap := CHANGES_ACTION_WIDTH * s, HEIGHT_COMPACT * s, SPACE_2 * s
	y := math.round(bar.y + (bar.height - height) / 2)
	discard = {bar.x + bar.width - SPACE_2 * s - width, y, width, height}
	copy = {discard.x - gap - width, y, width, height}
	send = {copy.x - gap - width, y, width, height}
	return
}

// The comment card at the point: the editor's parts, a saved card's buttons, or the card itself.
@(private = "file")
comment_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	for card in 0 ..= len(view.comments) {
		rect, shown := changes_card_rect(g, view, state, card)
		if !shown || !render.rect_contains(rect, x, y) {continue}
		return card_hit(g, view, state, card, rect, x, y)
	}
	return {}
}

// What lies at the point in the diff area and the send bar. Needs the rows of the latest changes_layout.
changes_diff_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	if render.rect_contains(g.send_bar, x, y) {
		send, copy, discard := changes_send_rects(g, view)
		if render.rect_contains(send, x, y) {return {.Send, 0, 0}}
		if render.rect_contains(copy, x, y) {return {.Copy, 0, 0}}
		if render.rect_contains(discard, x, y) {return {.Discard, 0, 0}}
		return {}
	}
	if !render.rect_contains(g.diff, x, y) {return {}}
	if hit := selection_bar_hit(g, x, y); hit.part != .None {return hit}
	if bar, shown := changes_h_scrollbar(g, view, state); shown && scrollbar_contains(bar, x, y) {
		return {.H_Scroll, 0, 0}
	}
	// Under a notice the stream holds only the comments.
	if view.notice != .None {return comment_hit(g, view, state, x, y)}
	rows := &state.rows
	if !rows.valid {return {.Diff, -1, 0}}
	if sticky, rect := changes_sticky_header(state, view, g); sticky >= 0 {
		if render.rect_contains(rect, x, y) {return {.Sticky_Header, sticky, 0}}
	}
	if hit := comment_hit(g, view, state, x, y); hit.part != .None {return hit}
	at := int(y - g.diff.y) + state.diff_scroll
	file := changes_file_at(rows, at)
	if file < 0 || file >= len(rows.tops) - 1 {return {.Diff, -1, 0}}
	if at < rows.tops[file] + rows.header {return {.File_Header, file, 0}}
	f := &view.files[file]
	if changes_collapsed(view, file) || f.binary {return {.Diff, file, 0}}
	origin := g.diff.y - f32(state.diff_scroll)
	band := diff_band(g)
	band.height = f32(rows.line)
	top, flat := rows.tops[file] + rows.header, 0
	for &hunk, h in f.hunks {
		base, count := hunk_rows(rows, file, h)
		height := hunk_height(rows, view, file, h)
		if at < top + height {
			if at < top + hunk_head(rows, file, h) {
				// The select button sits on the header's first line.
				header := band
				header.y, header.height = origin + f32(top), f32(rows.hunk)
				if len(hunk.lines) > 0 && render.rect_contains(hunk_select_rect(header, g.scale), x, y) {
					return {.Hunk_Select, file, flat}
				}
				return {.Diff, file, 0}
			}
			local := at - top - hunk_head(rows, file, h)
			i := hunk_row_at(rows, view, file, base, count, local)
			if count == 0 || local >= row_offset(rows, view, file, base, i) + row_height(rows, file, base + i) {
				return {.Diff, file, 0}
			}
			pair := row_pair(rows, file, base + i)
			line, cell := int(pair.left), band
			if rows.pairs.side_by_side {
				left, right, divider := row_halves(band, rows.split_left)
				if !view.selecting && x >= divider.x - DIFF_SPLIT_GRAB_LEFT * g.scale &&
				   x < right.x + DIFF_SPLIT_GRAB_RIGHT * g.scale && split_adjustable(band.width, g.scale) {
					return {.Split_Divider, 0, 0}
				}
				cell = left
				if x >= right.x {line, cell = int(pair.right), right}
			}
			at_line := line - flat
			if line < 0 || at_line < 0 || at_line >= len(hunk.lines) {return {.Diff, file, 0}}
			if hunk.lines[at_line].kind == .No_Newline {return {.Diff, file, 0}}
			// The numbers and the sign pick the line; the code text starts a text selection.
			number := code_number_width(f, rows.digit)
			column := code_column(cell, number, rows.digit, g.scale, !rows.pairs.side_by_side)
			return {x < column.text_x ? .Gutter : .Line, file, line}
		}
		top += height
		flat += len(hunk.lines)
	}
	return {.Diff, file, 0}
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

// The text of a file header: the path, or old and new for a rename or copy.
@(private = "file")
file_label :: proc(buf: []u8, f: ^tr.Diff_File) -> string {
	if (f.status == .Renamed || f.status == .Copied) && f.old_path != f.new_path && f.old_path != "" {
		return fmt.bprintf(buf, "%s → %s", f.old_path, f.new_path)
	}
	if f.status == .Deleted || f.new_path == "" {return clip_bytes(f.old_path, len(buf))}
	return clip_bytes(f.new_path, len(buf))
}

// The colour role of a file's status: modified warns, added is a success, deleted an error, and renamed
// or copied files are informational. The file headers and the file list's badges both read it.
changes_status_tint :: proc(status: tr.File_Status) -> Dropdown_Tint {
	switch status {
	case .Modified:
		return .Warning
	case .Added:
		return .Success
	case .Deleted:
		return .Error
	case .Renamed, .Copied:
		return .Info
	}
	return .Warning
}

@(private = "file")
status_mark :: proc(status: tr.File_Status, theme: Theme) -> (mark: string, color: render.Color) {
	color = dropdown_tint_color(theme, changes_status_tint(status))
	switch status {
	case .Modified:
		return "M", color
	case .Added:
		return "A", color
	case .Deleted:
		return "D", color
	case .Renamed:
		return "R", color
	case .Copied:
		return "C", color
	}
	return "M", color
}

@(private)
Diff_Paint :: struct {
	list:                 ^render.Draw_List,
	mono, small, strong, body: ^Text,
	theme:                Theme,
	scale:                f32,
	view:                 ^Changes_View,
	state:                ^Changes_State,
	pointer:              [2]f32,
	// The file card's horizontal extent; rows fill it.
	card_x, card_width:   f32,
	// The visible part of the diff area, to skip rows outside it.
	top, bottom:          f32,
	digit:                f32,
	// How wide the current file's line number columns are.
	number_width:         f32,
	// The text's font, and how far the current file's code is scrolled left, in pixels.
	font:                 Code_Font,
	scroll:               f32,
	// Whether long lines wrap and how tall a line of text is.
	wrap:                 bool,
	line_h:               f32,
}

@(private = "file")
number_draw :: proc(p: ^Diff_Paint, n: i32, x, baseline: f32) -> render.Build_Status {
	if n <= 0 {return .Ok}
	buf: [16]u8
	label := strconv.write_int(buf[:], i64(n), 10)
	left := x + p.number_width - f32(len(label)) * p.digit
	return draw_text(p.mono, p.list, label, left, baseline, p.theme.faint)
}

// What a diff row's code text sits on, which its inks are raised against.
Changes_Background :: enum u8 {
	Context,
	Added,
	Removed,
	Context_Selected,
	Added_Selected,
	Removed_Selected,
	Added_Edit,
	Removed_Edit,
}

// A row's inks: the 16 palette colours, then the text, the muted context text and the two signs.
CHANGES_INK_TEXT :: 16
CHANGES_INK_MUTED :: 17
CHANGES_INK_ADDED_SIGN :: 18
CHANGES_INK_REMOVED_SIGN :: 19
CHANGES_INKS :: 20

// The colours the ink table is built from: the ratio, the row fills and the inks.
Changes_Ink_Key :: struct {
	ratio:                                   f32,
	pane, added, removed, selection:         render.Color,
	text, muted, success, error:             render.Color,
	palette:                                 [16]render.Color,
}

// Code text colours raised to the view's minimum contrast against each row background. Built when the key
// changes, so drawing only looks colours up; `builds` counts the builds.
Changes_Inks :: struct {
	key:    Changes_Ink_Key,
	builds: int,
	table:  [Changes_Background][CHANGES_INKS]render.Color,
}

// `top` composited over `bottom` by its alpha, opaque.
@(private)
colour_over :: proc(top, bottom: render.Color) -> render.Color {
	a := top.a
	return {top.r * a + bottom.r * (1 - a), top.g * a + bottom.g * (1 - a), top.b * a + bottom.b * (1 - a), 1}
}

// A stronger pass of the row's own theme colour, only on changed text.
@(private = "file")
edit_tint :: proc(tint: render.Color) -> render.Color {
	out := tint
	out.a = min(0.65, tint.a * 2.5)
	return out
}

// Rebuilds the table when the theme's colours or the ratio changed since the last build.
@(private)
changes_inks_refresh :: proc(inks: ^Changes_Inks, theme: Theme, ratio: f32) {
	key := Changes_Ink_Key {
		ratio     = ratio,
		pane      = theme.pane,
		added     = theme.diff_added,
		removed   = theme.diff_removed,
		selection = theme.selection,
		text      = theme.text,
		muted     = theme.muted,
		success   = theme.success,
		error     = theme.error,
		palette   = theme.palette,
	}
	if inks.builds > 0 && inks.key == key {return}
	inks.key = key
	inks.builds += 1
	sources: [CHANGES_INKS]render.Color
	palette := theme.palette
	copy(sources[:16], palette[:])
	sources[CHANGES_INK_TEXT], sources[CHANGES_INK_MUTED] = theme.text, theme.muted
	sources[CHANGES_INK_ADDED_SIGN], sources[CHANGES_INK_REMOVED_SIGN] = theme.success, theme.error
	pane := theme.pane
	pane.a = 1
	added, removed := colour_over(theme.diff_added, pane), colour_over(theme.diff_removed, pane)
	backgrounds := [Changes_Background]render.Color {
		.Context          = pane,
		.Added            = added,
		.Removed          = removed,
		.Context_Selected = colour_over(theme.selection, pane),
		.Added_Selected   = colour_over(theme.selection, added),
		.Removed_Selected = colour_over(theme.selection, removed),
		.Added_Edit       = colour_over(edit_tint(theme.diff_added), added),
		.Removed_Edit     = colour_over(edit_tint(theme.diff_removed), removed),
	}
	for back, kind in backgrounds {
		for source, i in sources {inks.table[kind][i] = colour.minimum_contrast(source, back, ratio)}
	}
}

// The inks of a row of `kind`, selected or not.
@(private = "file")
row_inks :: proc(p: ^Diff_Paint, kind: tr.Line_Kind, selected: bool) -> ^[CHANGES_INKS]render.Color {
	background: Changes_Background
	#partial switch kind {
	case .Added:
		background = selected ? .Added_Selected : .Added
	case .Removed:
		background = selected ? .Removed_Selected : .Removed
	case:
		background = selected ? .Context_Selected : .Context
	}
	return &p.state.inks.table[background]
}

// The spans of flat line `line` of `file`, and whether the file is highlighted at all.
@(private = "file")
line_spans :: proc(view: ^Changes_View, file, line: int) -> (spans: []syntax.Span, highlighted: bool) {
	if file < 0 || file >= len(view.highlights) {return nil, false}
	lines := view.highlights[file].lines
	if line < 0 || line >= len(lines) {return nil, len(lines) > 0}
	return lines[line], true
}

// Whether a selection or note made in `made` shows in `cell`: the whole row of the unified layout (`Both`) or
// one cell of a side-by-side row. A line is drawn only in the cell it belongs to (a context line in both), so
// a selection made in one cell marks no line of the other cell, and a context line is marked only in the cell
// it was made in.
@(private = "file")
in_half :: proc(made, cell: Changes_Half) -> bool {
	return cell == .Both || made == .Both || made == cell
}

// Whether a line of `kind` belongs to a selection or note made in `half`: a cell side by side holds its own
// side's lines, so a range dragged across a change block takes in none of the other cell's.
@(require_results)
changes_half_has :: proc(half: Changes_Half, kind: tr.Line_Kind) -> bool {
	switch half {
	case .Both:
		return true
	case .Left:
		return kind != .Added
	case .Right:
		return kind != .Removed
	}
	return true
}

// Whether flat line `line` of `file`, drawn in `cell`, is in the selection.
@(private = "file")
line_selected :: proc(view: ^Changes_View, file, line: int, kind: tr.Line_Kind, cell: Changes_Half) -> bool {
	s := view.selection
	if !s.active || s.file != file || line < min(s.first, s.last) || line > max(s.first, s.last) {return false}
	return changes_half_has(s.half, kind) && in_half(s.half, cell)
}

// Whether flat line `line` of `file` is picked whole: in a selection of lines rather than of text.
@(private = "file")
line_picked :: proc(view: ^Changes_View, file, line: int, kind: tr.Line_Kind, cell: Changes_Half) -> bool {
	return line_selected(view, file, line, kind, cell) && !view.selection.partial
}

// Whether the pointer is on flat line `line` of `file` while a press picks whole lines.
@(private = "file")
line_hovered :: proc(p: ^Diff_Paint, file, line: int) -> bool {
	if !p.view.select_lines && !p.view.alt {return false}
	h := p.state.hover
	return (h.part == .Line || h.part == .Gutter) && h.index == file && h.line == line
}

// The note whose card the pointer is on, -1 for none: its marks in the code draw stronger.
@(private)
hot_note :: proc(state: ^Changes_State) -> int {
	#partial switch state.hover.part {
	case .Comment_Card, .Comment_Edit, .Comment_Remove, .Comment_Editor, .Editor_Untag, .Editor_Bold,
	     .Editor_Code, .Editor_Block, .Editor_Suggest, .Editor_Cancel, .Editor_Save:
		return state.hover.index
	}
	return -1
}

// How much of its colour a note's marks take: its tint behind text and its row tint, each also while the
// pointer is on its card, and the line under and through its text.
@(private = "file")
CHANGES_MARK_TINT :: f32(0.16)
@(private = "file")
CHANGES_MARK_TINT_HOT :: f32(0.30)
@(private = "file")
CHANGES_MARK_ROW_HOT :: f32(0.12)
@(private = "file")
CHANGES_MARK_LINE :: f32(0.8)
// How strongly the line under the pointer shows in line mode.
@(private = "file")
CHANGES_LINE_HOVER :: f32(0.55)

// What the selection and the notes draw on one line: the bar and the row tint a whole-line note gives the
// row, and byte ranges for the rest. The selection comes first, so its tint wins where they meet.
@(private = "file")
CHANGES_LINE_NOTES :: 5
@(private = "file")
CHANGES_LINE_EDGES :: 2 * (CHANGES_LINE_NOTES + 1)
@(private = "file")
CHANGES_RUNS :: CHANGES_LINE_EDGES + 2 * tr.DIFF_EDIT_RANGE_LIMIT

@(private = "file")
Line_Marks :: struct {
	bar, tint: render.Color,
	count:     int,
	segs:      [CHANGES_LINE_NOTES + 1]Code_Run,
}

@(private)
colour_alpha :: proc(c: render.Color, alpha: f32) -> render.Color {
	return {c.r, c.g, c.b, c.a * alpha}
}

// Collects the marks of flat line `line` of `file`, which is drawn in `cell` and whose text is `length`
// bytes. Only attached notes whose lines reach it count, and the one being edited draws none. A line draws
// the selection and the marks of its first CHANGES_LINE_NOTES notes; any further note on it shows through
// its card alone, which the fixed room for the runs makes safe.
@(private = "file")
line_marks :: proc(
	p: ^Diff_Paint, file, line, length: int, kind: tr.Line_Kind, cell: Changes_Half,
) -> (
	marks: Line_Marks,
) {
	view, theme := p.view, p.theme
	add :: proc(marks: ^Line_Marks, seg: Code_Run) {
		if marks.count < len(marks.segs) {
			marks.segs[marks.count] = seg
			marks.count += 1
		}
	}
	if s := view.selection; line_selected(view, file, line, kind, cell) {
		seg := Code_Run {
			end      = length,
			selected = true,
		}
		if s.partial {
			seg.start = line == min(s.first, s.last) ? s.first_offset : 0
			seg.end = line == max(s.first, s.last) ? s.last_offset : length
			seg.tint = theme.selection
		}
		add(&marks, seg)
	}
	if len(view.comments) == 0 {return}
	hot := hot_note(p.state)
	for c, i in view.comments {
		if c.file != file || line < c.first || line > c.last || i == view.editing {continue}
		if !in_half(c.half, cell) || !changes_half_has(c.half, kind) {continue}
		if !comment_attached(view, i) {continue}
		colour := changes_note_color(theme, c)
		strong := i == hot
		strike := c.kind == .Delete ? colour_alpha(theme.error, CHANGES_MARK_LINE) : render.Color{}
		if !c.partial {
			if marks.bar.a == 0 {marks.bar = colour}
			if strong {marks.tint = colour_alpha(colour, CHANGES_MARK_ROW_HOT)}
			add(&marks, Code_Run{end = length, strike = strike})
			continue
		}
		add(
			&marks,
			Code_Run {
				start     = line == c.first ? c.first_offset : 0,
				end       = line == c.last ? c.last_offset : length,
				tint      = colour_alpha(colour, strong ? CHANGES_MARK_TINT_HOT : CHANGES_MARK_TINT),
				underline = colour_alpha(colour, CHANGES_MARK_LINE),
				strike    = strike,
			},
		)
	}
	return
}

// Cuts at the edges of notes, selections and diff ranges. Selection and notes take precedence
// over a diff tint; their underline and strike stay independent of the background.
@(private = "file")
line_runs :: proc(
	marks: ^Line_Marks, length: int, changes: []tr.Diff_Range, tint: render.Color, out: ^[CHANGES_RUNS]Code_Run,
) -> []Code_Run {
	edges: [CHANGES_RUNS]int = ---
	count := 0
	for &seg in marks.segs[:marks.count] {
		seg.start, seg.end = clamp(seg.start, 0, length), clamp(seg.end, 0, length)
		if seg.end <= seg.start {continue}
		edges[count], edges[count + 1] = seg.start, seg.end
		count += 2
	}
	for i in 1 ..< count {
		for j := i; j > 0 && edges[j] < edges[j - 1]; j -= 1 {edges[j], edges[j - 1] = edges[j - 1], edges[j]}
	}
	// Merge the already sorted diff edges into the note edges, from right to left.
	total := count + 2 * len(changes)
	for edge, at := 2 * len(changes) - 1, total - 1; edge >= 0; at -= 1 {
		change := changes[edge / 2]
		x := change.start if edge % 2 == 0 else change.end
		if count > 0 && edges[count - 1] > x {
			count -= 1
			edges[at] = edges[count]
		} else {
			edges[at] = x
			edge -= 1
		}
	}
	change_at := 0
	runs := 0
	for i in 1 ..< total {
		start, end := edges[i - 1], edges[i]
		if start == end {continue}
		run := Code_Run {
			start = start,
			end   = end,
		}
		reached := false
		for seg in marks.segs[:marks.count] {
			if seg.start > start || seg.end < end || seg.end <= seg.start {continue}
			reached = true
			if run.tint.a == 0 {run.tint = seg.tint}
			if run.underline.a == 0 {run.underline = seg.underline}
			if run.strike.a == 0 {run.strike = seg.strike}
			run.selected ||= seg.selected
		}
		for change_at < len(changes) && changes[change_at].end <= start {change_at += 1}
		if run.tint.a == 0 && !run.selected && change_at < len(changes) && changes[change_at].start <= start {
			run.tint = tint
			run.changed = true
			reached = true
		}
		if reached {
			out[runs] = run
			runs += 1
		}
	}
	return out[:runs]
}

// A row's marks under its text: the tint of a whole-line note the pointer is on, and the note's bar at the
// row's left.
@(private = "file")
marks_draw :: proc(p: ^Diff_Paint, marks: Line_Marks, row: render.Rect) {
	if marks.tint.a > 0 {draw_rect(p.list, {rect = row, color = marks.tint})}
	if marks.bar.a > 0 {
		bar := render.Rect{row.x, row.y, max(1, math.round(2 * p.scale)), row.height}
		draw_rect(p.list, {rect = bar, color = marks.bar})
	}
}

// The selection over a row picked whole, its bar at the left; or, while presses pick lines, the faint bar of
// the line under the pointer.
@(private = "file")
row_pick_draw :: proc(p: ^Diff_Paint, file, line: int, picked: bool, row: render.Rect) {
	t := p.theme
	bar := render.Rect{row.x, row.y, max(1, math.round(2 * p.scale)), row.height}
	if picked {
		draw_rect(p.list, {rect = row, color = t.selection})
		draw_rect(p.list, {rect = bar, color = t.accent})
	} else if line_hovered(p, file, line) {
		draw_rect(p.list, {rect = bar, color = colour_alpha(t.accent, CHANGES_LINE_HOVER)})
	}
}

// Both sides of the match table are ordered, so look up only the visible changed lines.
@(private = "file")
edit_ranges :: proc(h: ^tr.Hunk, at: int, kind: tr.Line_Kind) -> []tr.Diff_Range {
	if kind != .Added && kind != .Removed {return nil}
	lo, hi := 0, len(h.edits)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		edit := h.edits[mid]
		line := edit.left if kind == .Removed else edit.right
		if line == at {
			if kind == .Removed {return h.edit_ranges[edit.first:edit.split]}
			return h.edit_ranges[edit.split:edit.end]
		}
		if line < at {lo = mid + 1} else {hi = mid}
	}
	return nil
}

// A line's sign and text in `column`: the sign inked for the row it is picked on, the text by runs of
// `marks`. The numbers are the caller's, for they differ by layout.
@(private = "file")
paint_code :: proc(
	p: ^Diff_Paint, d: ^tr.Diff_Line, file, flat: int, picked: bool, marks: ^Line_Marks, column: Code_Column,
	row: render.Rect, baseline: f32, changes: []tr.Diff_Range,
) -> render.Build_Status {
	spans, highlighted := line_spans(p.view, file, flat)
	inks := row_inks(p, d.kind, picked)
	plain := highlighted ? CHANGES_INK_TEXT : CHANGES_INK_MUTED
	#partial switch d.kind {
	case .Added:
		if r := draw_text(p.mono, p.list, "+", column.sign_x, baseline, inks[CHANGES_INK_ADDED_SIGN]); r != .Ok {
			return r
		}
		plain = CHANGES_INK_TEXT
	case .Removed:
		if r := draw_text(p.mono, p.list, "-", column.sign_x, baseline, inks[CHANGES_INK_REMOVED_SIGN]); r != .Ok {
			return r
		}
		plain = CHANGES_INK_TEXT
	}
	runs: [CHANGES_RUNS]Code_Run = ---
	tint: render.Color
	changed_inks: ^[CHANGES_INKS]render.Color
	if len(changes) > 0 {
		add := d.kind == .Added
		tint = edit_tint(p.theme.diff_added if add else p.theme.diff_removed)
		changed_inks = &p.state.inks.table[.Added_Edit if add else .Removed_Edit]
	}
	line := Code_Line {
		text          = d.text,
		spans         = spans,
		runs          = line_runs(marks, len(d.text), changes, tint, &runs),
		font          = p.font,
		x             = column.text_x,
		width         = column.width,
		scroll        = p.scroll,
		top           = row.y,
		height        = p.line_h,
		baseline      = baseline,
		scale         = p.scale,
		inks          = row_inks(p, d.kind, false),
		selected_inks = row_inks(p, d.kind, true),
		changed_inks  = changed_inks,
		plain         = plain,
	}
	if !p.wrap {return code_line_draw(p.list, p.mono, line)}
	// Wrapped, each line the text breaks into is drawn under the one before; the first carries the sign.
	length := wrap_plain(&p.state.rows, file, flat)
	for k := max(0, int((p.top - row.y) / p.line_h)); ; k += 1 {
		top := row.y + f32(k) * p.line_h
		if top >= p.bottom {break}
		start, end := wrap_row(p.mono, p.font, d.text, length, column.width, k)
		line.text, line.base = d.text[start:end], start
		line.top, line.baseline = top, baseline + f32(k) * p.line_h
		if r := code_line_draw(p.list, p.mono, line); r != .Ok {return r}
		if end >= len(d.text) {break}
	}
	return .Ok
}

// The "no newline" marker in `column`, scrolled with the code, or wrapped like any other text.
@(private = "file")
paint_marker :: proc(
	p: ^Diff_Paint, file, flat: int, column: Code_Column, baseline: f32,
) -> render.Build_Status {
	left := column.text_x
	if !p.wrap {
		return code_text_draw(
			p.list, p.mono, p.font, CHANGES_NO_NEWLINE, left - p.scroll, left, left + column.width, baseline,
			p.theme.faint,
		)
	}
	length := wrap_plain(&p.state.rows, file, flat)
	marker := CHANGES_NO_NEWLINE
	for k := 0; ; k += 1 {
		start, end := wrap_row(p.mono, p.font, marker, length, column.width, k)
		if r := code_text_draw(
			p.list, p.mono, p.font, marker[start:end], left, left, left + column.width,
			baseline + f32(k) * p.line_h, p.theme.faint,
		); r != .Ok {return r}
		if end >= len(marker) {break}
	}
	return .Ok
}

@(private = "file")
paint_line :: proc(
	p: ^Diff_Paint, h: ^tr.Hunk, at, file, flat: int, y, height: f32,
) -> render.Build_Status {
	line := &h.lines[at]
	t := p.theme
	baseline := baseline_in(y, p.line_h, p.mono)
	row := render.Rect{p.card_x, y, p.card_width, height}
	switch line.kind {
	case .Added:
		draw_rect(p.list, {rect = row, color = t.diff_added})
	case .Removed:
		draw_rect(p.list, {rect = row, color = t.diff_removed})
	case .Context, .No_Newline:
	}
	picked := line_picked(p.view, file, flat, line.kind, .Both)
	marks := line_marks(p, file, flat, len(line.text), line.kind, .Both)
	marks_draw(p, marks, row)
	row_pick_draw(p, file, flat, picked, row)
	column := code_column(row, p.number_width, p.digit, p.scale, true)
	if line.kind == .No_Newline {return paint_marker(p, file, flat, column, baseline)}
	if line.kind != .Added {
		if r := number_draw(p, line.old_line, column.old_x, baseline); r != .Ok {return r}
	}
	if line.kind != .Removed {
		if r := number_draw(p, line.new_line, column.new_x, baseline); r != .Ok {return r}
	}
	return paint_code(p, line, file, flat, picked, &marks, column, row, baseline, edit_ranges(h, at, line.kind))
}

// One cell of a side-by-side row: flat line `line` of the hunk whose first line is flat line `flat`, with
// its old line number on the left and its new one on the right; a blank cell for -1.
@(private = "file")
paint_cell :: proc(
	p: ^Diff_Paint, h: ^tr.Hunk, file, flat, line: int, old: bool, cell: render.Rect,
) -> render.Build_Status {
	t, s := p.theme, p.scale
	at := line - flat
	if line < 0 || at < 0 || at >= len(h.lines) {
		draw_rect(p.list, {rect = cell, color = t.code_background})
		return .Ok
	}
	d := &h.lines[at]
	column := code_column(cell, p.number_width, p.digit, s, false)
	// Wrapped, the row is as tall as its taller cell, and this cell's fill stops where its own text does.
	own := cell
	if p.wrap {
		text := d.kind == .No_Newline ? CHANGES_NO_NEWLINE : d.text
		lines := wrap_line_rows(p.mono, p.font, text, wrap_plain(&p.state.rows, file, line), column.width)
		own.height = f32(lines) * p.line_h
		if own.height < cell.height {
			rest := render.Rect{cell.x, cell.y + own.height, cell.width, cell.height - own.height}
			draw_rect(p.list, {rect = rest, color = t.code_background})
		}
	}
	#partial switch d.kind {
	case .Added:
		draw_rect(p.list, {rect = own, color = t.diff_added})
	case .Removed:
		draw_rect(p.list, {rect = own, color = t.diff_removed})
	}
	half := old ? Changes_Half.Left : Changes_Half.Right
	picked := line_picked(p.view, file, line, d.kind, half)
	marks := line_marks(p, file, line, len(d.text), d.kind, half)
	marks_draw(p, marks, own)
	row_pick_draw(p, file, line, picked, own)
	baseline := baseline_in(cell.y, p.line_h, p.mono)
	if d.kind == .No_Newline {return paint_marker(p, file, line, column, baseline)}
	if r := number_draw(p, old ? d.old_line : d.new_line, column.old_x, baseline); r != .Ok {return r}
	return paint_code(p, d, file, line, picked, &marks, column, cell, baseline, edit_ranges(h, at, d.kind))
}

// Hunk `index` of `file`, whose first line is flat line `flat`: its header row, then its rows.
@(private = "file")
paint_hunk :: proc(
	p: ^Diff_Paint, rows: ^Changes_Rows, h: ^tr.Hunk, file, index, flat: int, y: f32,
) -> render.Build_Status {
	t, s := p.theme, p.scale
	header := render.Rect{p.card_x, y, p.card_width, f32(hunk_head(rows, file, index))}
	draw_rect(p.list, {rect = header, color = t.code_background})
	first := render.Rect{p.card_x, y, p.card_width, f32(rows.hunk)}
	pointed := p.pointer.y >= p.top && p.pointer.y < p.bottom
	picking := len(h.lines) > 0 && pointed && render.rect_contains(first, p.pointer.x, p.pointer.y)
	buf: [CHANGES_HUNK_LABEL_BYTES]u8
	label := hunk_label(buf[:], h)
	baseline := baseline_in(y, f32(rows.hunk), p.mono)
	// The room the select button takes at the right is always kept.
	left := p.card_x + SPACE_2 * s
	right := p.card_x + p.card_width - SPACE_2 * s - first.height - SPACE_1 * s
	origin := left - p.scroll
	if r := code_text_draw(p.list, p.mono, p.font, label, origin, left, right, baseline, t.muted); r != .Ok {
		return r
	}
	if h.section != "" && !p.wrap {
		after := origin + code_width(p.mono, p.font, label) + p.font.cell
		if r := code_text_draw(p.list, p.mono, p.font, h.section, after, left, right, baseline, t.faint);
		   r != .Ok {return r}
	} else if h.section != "" {
		// Wrapped, the section fills what the label leaves of the first line, then lines of its own.
		rest := h.section
		after := left + code_width(p.mono, p.font, label) + p.font.cell
		cut := 0
		if right - after >= p.font.cell {cut = code_fit(p.mono, p.font, rest, right - after)}
		if r := code_text_draw(p.list, p.mono, p.font, rest[:cut], after, after, right, baseline, t.faint);
		   r != .Ok {return r}
		rest = rest[cut:]
		for j := 1; len(rest) > 0; j += 1 {
			cut = code_fit(p.mono, p.font, rest, right - left)
			line := baseline + f32(j) * p.line_h
			if r := code_text_draw(p.list, p.mono, p.font, rest[:cut], left, left, right, line, t.faint);
			   r != .Ok {return r}
			rest = rest[cut:]
		}
	}
	if picking {
		hover, press := changes_lit(p.state, {.Hunk_Select, file, flat})
		button := hunk_select_rect(first, s)
		if icon_button_draw(
			p.list, t, button, .Select_Lines, hover, press, s, p.pointer, ICON_INDICATOR, RADIUS_CONTROL,
		) != .None {return .Ok}
	}
	top := y + header.height
	base, count := hunk_rows(rows, file, index)
	divider_ink := t.border
	if p.state.hover.part == .Split_Divider || p.state.press.part == .Split_Divider {divider_ink = t.accent}
	for i := hunk_row_at(rows, p.view, file, base, count, int(p.top - top)); i < count; i += 1 {
		row := top + f32(row_offset(rows, p.view, file, base, i))
		if row >= p.bottom {break}
		height := f32(row_height(rows, file, base + i))
		pair := row_pair(rows, file, base + i)
		if rows.pairs.side_by_side {
			left, right, divider := row_halves({p.card_x, row, p.card_width, height}, rows.split_left)
			if r := paint_cell(p, h, file, flat, int(pair.left), true, left); r != .Ok {return r}
			if r := paint_cell(p, h, file, flat, int(pair.right), false, right); r != .Ok {return r}
			draw_rect(p.list, {rect = divider, color = divider_ink})
		} else if at := int(pair.left) - flat; at >= 0 && at < len(h.lines) {
			if r := paint_line(p, h, at, file, int(pair.left), row, height); r != .Ok {return r}
		}
	}
	return .Ok
}

// A file's header in `head`: the fold chevron, the status mark, the path, the badges and the counts, on
// a button surface that plays the hover and press of `part`.
@(private = "file")
paint_header :: proc(p: ^Diff_Paint, i: int, head: render.Rect, part: Changes_Part) -> render.Build_Status {
	t, s := p.theme, p.scale
	view := p.view
	f := &view.files[i]
	collapsed := changes_collapsed(view, i)
	hover, press := changes_lit(p.state, {part, i, 0})
	draw_rect(p.list, {rect = head, color = t.surface, radius = RADIUS_CONTROL * s})
	face, ink, err := button_draw(
		p.list,
		t,
		{rect = head, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat},
		s,
		p.pointer,
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
	return draw_fading_text(
		body, p.list, file_label(label_buf[:], f), x, baseline_in(face.y, face.height, body), t.text,
		right - x,
	)
}

@(private = "file")
paint_file :: proc(p: ^Diff_Paint, rows: ^Changes_Rows, i: int, y: f32) -> render.Build_Status {
	s := p.scale
	view := p.view
	f := &view.files[i]
	head := render.Rect{p.card_x, y, p.card_width, f32(rows.header)}
	if r := paint_header(p, i, head, .File_Header); r != .Ok {return r}
	if changes_collapsed(view, i) {return .Ok}
	t := p.theme

	top := y + f32(rows.header)
	if f.binary || len(f.hunks) == 0 {
		note := f.binary ? "Binary file" : "No content changes"
		return draw_text(
			p.small, p.list, note, p.card_x + CONTROL_INSET * s, baseline_in(top, f32(rows.note), p.small),
			t.muted,
		)
	}
	p.number_width = code_number_width(f, p.digit)
	p.scroll = f32(changes_h_columns(p.state, view, i, p.card_width)) * p.digit
	flat := 0
	for &hunk, h in f.hunks {
		height := f32(hunk_height(rows, view, i, h))
		if top + height > p.top {
			if top >= p.bottom {break}
			if r := paint_hunk(p, rows, &hunk, i, h, flat, top); r != .Ok {return r}
		}
		top += height
		flat += len(hunk.lines)
	}
	return .Ok
}

// A comment's card: its note, or the editor while it is being written.
@(private = "file")
paint_card :: proc(p: ^Diff_Paint, rect: render.Rect, card: int) -> render.Build_Status {
	if card == p.view.editing {return paint_editor_card(p, rect, card)}
	if card >= len(p.view.comments) {return .Ok}
	return paint_note_card(p, rect, card)
}

// The cards and the "Not in this diff" heading, over the rows they belong to.
@(private = "file")
paint_comments :: proc(p: ^Diff_Paint, g: Changes_Geometry, rows: ^Changes_Rows) -> render.Build_Status {
	view, state := p.view, p.state
	if rows.detached > 0 {
		y := g.diff.y - f32(state.diff_scroll) + f32(rows.total - rows.detached)
		if y < p.bottom && y + f32(rows.header) > p.top {
			if r := draw_text(
				p.small, p.list, CHANGES_DETACHED_LABEL, p.card_x + CONTROL_INSET * p.scale,
				baseline_in(y, f32(rows.header), p.small), p.theme.muted,
			); r != .Ok {return r}
		}
	}
	for card in 0 ..= len(view.comments) {
		rect, shown := changes_card_rect(g, view, state, card)
		if !shown || rect.y >= p.bottom || rect.y + rect.height <= p.top {continue}
		if r := paint_card(p, rect, card); r != .Ok {return r}
	}
	return .Ok
}

// Draws the diff stream; under a notice only its comments, which are all in the "Not in this diff" group.
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
	notice := view.notice != .None
	if !rows.valid || g.diff.width <= 0 || (notice && rows.detached <= 0) {return .Ok}
	if !notice && len(rows.tops) != len(view.files) + 1 {return .Ok}
	changes_inks_refresh(&state.inks, theme, view.minimum_contrast)
	scope, opened := clip_scope_open(list, g.diff)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := g.scale
	small := text_styled(text, .Detail)
	strong := text_styled(text, .Strong)
	band := diff_band(g)
	p := Diff_Paint {
		list       = list,
		mono       = mono,
		small      = &small,
		strong     = &strong,
		body       = text,
		theme      = theme,
		scale      = s,
		view       = view,
		state      = state,
		pointer    = pointer,
		card_x     = band.x,
		card_width = band.width,
		top        = g.diff.y,
		bottom     = g.diff.y + g.diff.height,
		digit      = text_width(mono, "0"),
		font       = code_font(mono),
		wrap       = wrap_valid(rows),
		line_h     = f32(rows.line),
	}
	if notice {return paint_comments(&p, g, rows)}
	scroll := state.diff_scroll
	origin := g.diff.y - f32(scroll)
	files := len(view.files)
	first := max(0, changes_file_at(rows, scroll))
	for i := first; i < files && f32(rows.tops[i]) + origin < p.bottom; i += 1 {
		if r := paint_file(&p, rows, i, origin + f32(rows.tops[i])); r != .Ok {return r}
	}
	if view.omitted > 0 {
		y := origin + f32(rows.tops[files])
		if y < p.bottom && y + f32(rows.footer) > p.top {
			buf: [64]u8
			noun := view.omitted == 1 ? "file" : "files"
			label := fmt.bprintf(buf[:], "%d untracked %s not shown", view.omitted, noun)
			if r := draw_text(
				&small, list, label, p.card_x + CONTROL_INSET * s, baseline_in(y, f32(rows.footer), &small),
				theme.muted,
			); r != .Ok {return r}
		}
	}
	if r := paint_comments(&p, g, rows); r != .Ok {return r}
	// The pinned header covers whatever scrolled under it: lines and cards. A layer
	// draws its rects before its text, so the header takes a layer of its own above the stream's text.
	sticky, rect := changes_sticky_header(state, view, g)
	if sticky >= 0 && render.push_layer(list, g.diff) == .None {
		draw_rect(list, {rect = rect, color = theme.pane})
		draw_rect(list, {rect = {rect.x, rect.y + rect.height, rect.width, 1}, color = theme.border})
		if r := paint_header(&p, sticky, {p.card_x, rect.y, p.card_width, rect.height}, .Sticky_Header); r != .Ok {
			return r
		}
	}
	if bar, shown := changes_h_scrollbar(g, view, state); shown {
		scrollbar_draw(list, theme, bar, scrollbar_state(state.hover.part == .H_Scroll, state.h_bar))
	}
	return selection_bar_draw(list, text, theme, g, view, state, pointer)
}

// The send bar under the diff: the count and the agent they go to, then Send, Copy and Discard. Send
// stays at 45 % while the agent can't take the message; the pane shows why as its tooltip.
@(private)
changes_send_bar_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	g: Changes_Geometry,
	view: ^Changes_View,
	state: ^Changes_State,
	pointer: [2]f32,
) -> render.Build_Status {
	bar := g.send_bar
	if bar.height <= 0 || bar.width <= 0 {return .Ok}
	s := g.scale
	draw_rect(list, {rect = bar, color = theme.pane})
	draw_rect(list, {rect = {bar.x, bar.y, bar.width, s}, color = theme.border})
	send, copy, discard := changes_send_rects(g, view)
	body := text_styled(text, .Body)
	buf: [256]u8
	noun := view.send.count == 1 ? "note" : "notes"
	target := clip_bytes(view.send.target, 160)
	count := view.send.count
	label := fmt.bprintf(buf[:], "%d %s", count, noun)
	if target != "" {label = fmt.bprintf(buf[:], "%d %s · to %s", count, noun, target)}
	x := bar.x + SPACE_3 * s
	if r := draw_fading_text(
		&body, list, label, x, baseline_in(bar.y, bar.height, &body), theme.text, send.x - SPACE_2 * s - x,
	); r != .Ok {return r}

	if view.send.can_send {
		hover, press := changes_lit(state, {.Send, 0, 0})
		r := primary_button_draw(list, text, theme, send, "Send", hover, press, false, s, pointer)
		if r != .Ok {return r}
	} else {
		radius := RADIUS_CONTROL * s
		fill, ink := theme.accent, theme.accent_text
		fill.a *= DISABLED_ALPHA
		ink.a *= DISABLED_ALPHA
		draw_rect(list, {rect = send, color = fill, radius = radius})
		strong := text_styled(text, .Strong)
		width := min(text_width(&strong, "Send"), send.width)
		baseline := baseline_in(send.y, send.height, &strong)
		r := draw_text(&strong, list, "Send", send.x + (send.width - width) / 2, baseline, ink, send.width)
		if r != .Ok {return r}
	}
	if r := text_button_draw(list, &body, theme, copy, "Copy", false, s, pointer); r != .Ok {return r}

	hover, press := changes_lit(state, {.Discard, 0, 0})
	face, ink, err := button_draw(
		list,
		theme,
		{rect = discard, hover = hover, press = press, radius = RADIUS_CONTROL, surface = .Flat},
		s,
		pointer,
	)
	if err != .None {return .Ok}
	width := min(text_width(&body, "Discard"), face.width)
	baseline := baseline_in(face.y, face.height, &body)
	return draw_text(&body, list, "Discard", face.x + (face.width - width) / 2, baseline, ink, face.width)
}
