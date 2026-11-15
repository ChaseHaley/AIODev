package ui

import "aio:font"
import "aio:render"
import "aio:syntax"
import tr "aio:turns"
import "core:fmt"
import "core:math"
import "core:strconv"

@(private = "file")
CHANGES_TAB_COLUMNS :: 4
@(private = "file")
CHANGES_STATUS_WIDTH :: f32(16)
@(private = "file")
CHANGES_SEND_BAR_HEIGHT :: f32(40)
// The Send, Copy, Discard and Comment buttons share one width, so hit tests need no text metrics.
@(private = "file")
CHANGES_ACTION_WIDTH :: f32(72)
@(private = "file")
CHANGES_COMMENT_HINT :: "Enter to save · Esc to cancel"
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
	count := file_row_count(rows, i)
	return len(f.hunks) * rows.hunk + count * rows.line + cards_through(rows, view, i, 0, count - 1)
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

// The end of the run of `kind` lines from `start`, taking the No_Newline marker that follows the run, so
// a marker stays on its side.
@(private = "file")
run_end :: proc(lines: []tr.Diff_Line, start: int, kind: tr.Line_Kind) -> int {
	end := start
	for end < len(lines) && lines[end].kind == kind {end += 1}
	if end > start && end < len(lines) && lines[end].kind == .No_Newline {end += 1}
	return end
}

// Appends a hunk's rows. Side by side, a context line fills both cells, and a removed run shares rows with
// the added run right after it (row k is the k-th removed and the k-th added line), blank cells padding
// the shorter side.
@(private = "file", require_results)
hunk_pairs_append :: proc(t: ^Changes_Pairs, lines: []tr.Diff_Line, base: int) -> bool {
	if !t.side_by_side {
		for i in 0 ..< len(lines) {
			line := i32(base + i)
			if _, err := append(&t.pairs, Changes_Pair{line, line}); err != nil {return false}
		}
		return true
	}
	i := 0
	for i < len(lines) {
		#partial switch lines[i].kind {
		case .Removed, .Added:
			removed := run_end(lines, i, .Removed)
			added := run_end(lines, removed, .Added)
			left, right := removed - i, added - removed
			for k in 0 ..< max(left, right) {
				pair := Changes_Pair{-1, -1}
				if k < left {pair.left = i32(base + i + k)}
				if k < right {pair.right = i32(base + removed + k)}
				if _, err := append(&t.pairs, pair); err != nil {return false}
			}
			i = added
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
			hunk_pairs_append(t, hunk.lines, count) or_return
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
@(private = "file")
line_row :: proc(rows: ^Changes_Rows, file, line: int) -> int {
	t := &rows.pairs
	if file < 0 || file + 1 >= len(t.file_lines) || line < 0 {return -1}
	at := t.file_lines[file] + line
	if at >= t.file_lines[file + 1] {return -1}
	return int(t.line_rows[at])
}

// The cells of a side-by-side row, either side of a one-pixel divider.
@(private = "file")
row_halves :: proc(row: render.Rect) -> (left, right, divider: render.Rect) {
	mid := math.round(row.x + row.width / 2)
	left = {row.x, row.y, max(0, mid - row.x), row.height}
	divider = {mid, row.y, 1, row.height}
	right = {mid + 1, row.y, max(0, row.x + row.width - mid - 1), row.height}
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
@(private = "file")
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

@(private = "file")
card_margin :: proc(rows: ^Changes_Rows) -> int {return int(math.round(SPACE_1 * rows.scale))}

// A card's height with the gap above and below it; zero for a card that is not shown.
@(private = "file")
card_slot :: proc(rows: ^Changes_Rows, card: int) -> int {
	if card >= len(rows.cards) || rows.cards[card] <= 0 {return 0}
	return rows.cards[card] + 2 * card_margin(rows)
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

// What the cards' layout depends on besides the diff: the comments, which one is edited and the selection,
// which the Comment button and a new comment go below. Part of the rows cache key.
@(private)
changes_comments_key :: proc(view: ^Changes_View) -> u64 {
	mix :: proc(hash, value: u64) -> u64 {return (hash ~ value) * 1099511628211}
	hash := u64(14695981039346656037)
	hash = mix(hash, u64(view.editing + 1))
	hash = mix(hash, u64(len(view.comments)))
	for c in view.comments {
		hash = mix(mix(mix(hash, u64(c.file + 1)), u64(c.first + 1)), u64(c.last + 1))
		hash = mix(hash, c.detached ? 2 : 1)
		for b in transmute([]u8)c.text {hash = mix(hash, u64(b))}
		hash = mix(hash, 0x100)
	}
	if s := view.selection; s.active {
		hash = mix(mix(mix(hash, u64(s.file + 1)), u64(s.first + 1)), u64(s.last + 1))
	}
	return hash
}

@(private = "file")
card_delete_size :: proc(scale: f32) -> f32 {return HEIGHT_COMPACT * scale}

// The width a comment's text wraps at in a card `card_width` wide: the inset, then the text, then the
// delete button.
@(private = "file")
card_text_width :: proc(card_width, scale: f32) -> f32 {
	return max(1, card_width - SPACE_2 * scale - 2 * SPACE_1 * scale - card_delete_size(scale))
}

@(private = "file")
card_delete_rect :: proc(card: render.Rect, scale: f32) -> render.Rect {
	size := card_delete_size(scale)
	return {card.x + card.width - SPACE_1 * scale - size, card.y + SPACE_1 * scale, size, size}
}

@(private = "file")
editor_field_rect :: proc(card: render.Rect, scale: f32) -> render.Rect {
	pad := SPACE_2 * scale
	return {card.x + pad, card.y + pad, max(0, card.width - 2 * pad), HEIGHT_STANDARD * scale}
}

// Measures each card at the cached width, for changes_layout: comment i's card, then the new-comment
// editor's (zero when it is closed). The edited comment's card is the editor. Also finds the row each
// card and the selection end on.
@(private)
changes_cards_measure :: proc(rows: ^Changes_Rows, view: ^Changes_View, text: ^Text) {
	clear(&rows.cards)
	t := &rows.pairs
	clear(&t.card_rows)
	s := rows.scale
	body := text_styled(text, .Body)
	detail := text_styled(text, .Detail)
	pad := SPACE_2 * s
	editor := int(math.round(2 * pad + HEIGHT_STANDARD * s + SPACE_1 * s + detail.line_height))
	least := card_delete_size(s) + 2 * SPACE_1 * s
	width := card_text_width(rows.width - 4 * SPACE_2 * s, s)
	selection := view.selection
	t.selection_row = -1
	if selection.active {t.selection_row = range_row(rows, selection.file, selection.first, selection.last)}
	for c, i in view.comments {
		append(&t.card_rows, comment_attached(view, i) ? range_row(rows, c.file, c.first, c.last) : -1)
		if view.editing == i {
			append(&rows.cards, editor)
			continue
		}
		lines := Wrap_Lines {
			text       = &body,
			s          = c.text,
			width      = width,
			last_space = -1,
		}
		count := 0
		for {
			_, _, ok := wrap_next(&lines)
			if !ok {break}
			count += 1
		}
		append(&rows.cards, int(math.round(max(least, 2 * pad + f32(count) * body.line_height))))
	}
	writing := writing_new(view)
	append(&rows.cards, writing ? editor : 0)
	append(&t.card_rows, writing ? t.selection_row : -1)
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

// Where row `i` of a hunk starts below the hunk's header: the rows above it and their cards. `base` is the
// hunk's first row in its file.
@(private = "file")
row_offset :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, base, i: int) -> int {
	return i * rows.line + cards_through(rows, view, file, base, base + i - 1)
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
@(private = "file")
row_top :: proc(rows: ^Changes_Rows, view: ^Changes_View, file, row: int) -> (y: int, ok: bool) {
	if file < 0 || file >= len(view.files) || file >= len(rows.tops) - 1 || row < 0 {return}
	if changes_collapsed(view, file) || view.files[file].binary {return}
	y = rows.tops[file] + rows.header
	for h in 0 ..< len(view.files[file].hunks) {
		base, count := hunk_rows(rows, file, h)
		if row < base + count {return y + rows.hunk + row_offset(rows, view, file, base, row - base), true}
		y += rows.hunk + count * rows.line + cards_through(rows, view, file, base, base + count - 1)
	}
	return 0, false
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
		return y + card_margin(rows), true
	}
	row := card_row(rows, card)
	y = row_top(rows, view, file, row) or_return
	y += rows.line
	for i in 0 ..< card {
		if card_file(view, i) == file && card_row(rows, i) == row {y += card_slot(rows, i)}
	}
	return y + card_margin(rows), true
}

@(private = "file")
card_rect :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, card: int,
) -> (
	rect: render.Rect,
	shown: bool,
) {
	rows := &state.rows
	if !rows.valid {return}
	top := card_top(rows, view, card) or_return
	inset := 2 * SPACE_2 * g.scale
	y := g.diff.y - f32(state.diff_scroll) + f32(top)
	return {g.diff.x + inset, y, max(0, g.diff.width - 2 * inset), f32(rows.cards[card])}, true
}

// `r` when any of it is in the diff area's height, else zero.
@(private = "file")
diff_visible :: proc(g: Changes_Geometry, r: render.Rect) -> render.Rect {
	if r.y + r.height <= g.diff.y || r.y >= g.diff.y + g.diff.height {return {}}
	return r
}

// The row of flat line `line` of `file` across the file's card; side by side, the cell that holds it, or
// the whole row for a context line, which fills both. Zero when it is not on screen.
changes_line_rect :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, file, line: int,
) -> render.Rect {
	rows := &state.rows
	if !rows.valid || view.notice != .None {return {}}
	row := line_row(rows, file, line)
	top, ok := row_top(rows, view, file, row)
	if !ok {return {}}
	pad := SPACE_2 * g.scale
	y := g.diff.y - f32(state.diff_scroll) + f32(top)
	rect := render.Rect{g.diff.x + pad, y, max(0, g.diff.width - 2 * pad), f32(rows.line)}
	if rows.pairs.side_by_side {
		pair := row_pair(rows, file, row)
		left, right, _ := row_halves(rect)
		if int(pair.right) != line {
			rect = left
		} else if int(pair.left) != line {
			rect = right
		}
	}
	return diff_visible(g, rect)
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

// The Comment button at the right end of the lowest row holding a selected line, while nothing is being
// written; side by side, at the right end of that row's selected cell, the right one when both are. Zero
// when it is not on screen.
changes_comment_button_rect :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State,
) -> render.Rect {
	s := view.selection
	rows := &state.rows
	if !s.active || view.editing >= 0 || !rows.valid || view.notice != .None {return {}}
	row := rows.pairs.selection_row
	top, ok := row_top(rows, view, s.file, row)
	if !ok {return {}}
	pad := SPACE_2 * g.scale
	y := g.diff.y - f32(state.diff_scroll) + f32(top)
	cell := render.Rect{g.diff.x + pad, y, max(0, g.diff.width - 2 * pad), f32(rows.line)}
	if rows.pairs.side_by_side {
		left, right, _ := row_halves(cell)
		cell = line_selected(view, s.file, int(row_pair(rows, s.file, row).right)) ? right : left
	}
	if diff_visible(g, cell).width <= 0 {return {}}
	width := min(CHANGES_ACTION_WIDTH * g.scale, cell.width)
	return {cell.x + cell.width - SPACE_1 * g.scale - width, cell.y, width, cell.height}
}

// The comment button of a hunk header row, at its right end.
@(private = "file")
hunk_comment_rect :: proc(header: render.Rect, scale: f32) -> render.Rect {
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

// The editor of the comment being written, inside its card; false when none is open or it is off the
// stream.
changes_editor_box :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, text: ^Text,
) -> (
	box: Field_Box,
	shown: bool,
) {
	if view.editing < 0 || view.editor == nil {return}
	card := card_rect(g, view, state, view.editing) or_return
	return field_box_standard(view.editor, text, editor_field_rect(card, g.scale), g.scale), true
}

// The comment card at the point: its delete button, the editor it holds, or the card itself.
@(private = "file")
comment_hit :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, x, y: f32,
) -> Changes_Hit {
	for card in 0 ..= len(view.comments) {
		rect, shown := card_rect(g, view, state, card)
		if !shown || !render.rect_contains(rect, x, y) {continue}
		if card == view.editing {return {.Comment_Editor, card, 0}}
		if render.rect_contains(card_delete_rect(rect, g.scale), x, y) {return {.Comment_Delete, card, 0}}
		return {.Comment_Card, card, 0}
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
	// Under a notice the stream holds only the comments.
	if view.notice != .None {return comment_hit(g, view, state, x, y)}
	rows := &state.rows
	if !rows.valid {return {.Diff, -1, 0}}
	s := view.selection
	if render.rect_contains(changes_comment_button_rect(g, view, state), x, y) {
		return {.Comment_Button, s.file, max(s.first, s.last)}
	}
	if hit := comment_hit(g, view, state, x, y); hit.part != .None {return hit}
	at := int(y - g.diff.y) + state.diff_scroll
	file := changes_file_at(rows, at)
	if file < 0 || file >= len(rows.tops) - 1 {return {.Diff, -1, 0}}
	if at < rows.tops[file] + rows.header {return {.File_Header, file, 0}}
	f := &view.files[file]
	if changes_collapsed(view, file) || f.binary {return {.Diff, file, 0}}
	pad := SPACE_2 * g.scale
	origin := g.diff.y - f32(state.diff_scroll)
	band := render.Rect{g.diff.x + pad, 0, max(0, g.diff.width - 2 * pad), f32(rows.line)}
	top, flat := rows.tops[file] + rows.header, 0
	for &hunk, h in f.hunks {
		base, count := hunk_rows(rows, file, h)
		height := rows.hunk + count * rows.line + cards_through(rows, view, file, base, base + count - 1)
		if at < top + height {
			if at < top + rows.hunk {
				header := band
				header.y, header.height = origin + f32(top), f32(rows.hunk)
				if len(hunk.lines) > 0 && render.rect_contains(hunk_comment_rect(header, g.scale), x, y) {
					return {.Hunk_Comment, file, flat}
				}
				return {.Diff, file, 0}
			}
			local := at - top - rows.hunk
			i := hunk_row_at(rows, view, file, base, count, local)
			if count == 0 || local >= row_offset(rows, view, file, base, i) + rows.line {
				return {.Diff, file, 0}
			}
			pair := row_pair(rows, file, base + i)
			line := int(pair.left)
			if rows.pairs.side_by_side {
				if _, right, _ := row_halves(band); x >= right.x {line = int(pair.right)}
			}
			at_line := line - flat
			if line < 0 || at_line < 0 || at_line >= len(hunk.lines) {return {.Diff, file, 0}}
			if hunk.lines[at_line].kind == .No_Newline {return {.Diff, file, 0}}
			return {.Line, file, line}
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

// The leading runes of `s` that can reach `width` in a monospace font whose glyphs advance `advance`, plus
// two, so the fade still sees the overflow. A minified line is therefore never walked whole.
mono_prefix :: proc(s: string, width, advance: f32) -> string {
	if advance <= 0 {return clip_bytes(s, CHANGES_CLIP_BYTES)}
	limit := int(max(0, width) / advance) + 2
	count := 0
	for _, offset in s {
		if count == limit {return s[:offset]}
		count += 1
	}
	return s
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

@(private = "file")
status_mark :: proc(status: tr.File_Status, theme: Theme) -> (mark: string, color: render.Color) {
	switch status {
	case .Modified:
		return "M", theme.warning
	case .Added:
		return "A", theme.success
	case .Deleted:
		return "D", theme.error
	case .Renamed:
		return "R", theme.info
	case .Copied:
		return "C", theme.info
	}
	return "M", theme.warning
}

@(private = "file")
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
	// Where the line numbers, the sign and the text start in the current file.
	old_x, new_x, sign_x, text_x, column: f32,
}

@(private = "file")
digit_count :: proc(n: int) -> int {
	count := 1
	for v := n; v >= 10; v /= 10 {count += 1}
	return count
}

@(private = "file")
paint_gutter :: proc(p: ^Diff_Paint, f: ^tr.Diff_File) {
	biggest := 0
	if len(f.hunks) > 0 {
		last := f.hunks[len(f.hunks) - 1]
		biggest = int(max(last.old_start + last.old_count, last.new_start + last.new_count))
	}
	s := p.scale
	p.column = f32(digit_count(biggest)) * p.digit
	p.old_x = p.card_x + SPACE_2 * s
	p.new_x = p.old_x + p.column + SPACE_2 * s
	p.sign_x = p.new_x + p.column + SPACE_2 * s
	p.text_x = p.sign_x + p.digit + SPACE_1 * s
}

@(private = "file")
number_draw :: proc(p: ^Diff_Paint, n: i32, x, baseline: f32) -> render.Build_Status {
	if n <= 0 {return .Ok}
	buf: [16]u8
	label := strconv.write_int(buf[:], i64(n), 10)
	return draw_text(p.mono, p.list, label, x + p.column - f32(len(label)) * p.digit, baseline, p.theme.faint)
}

// Draws the start of a diff line from `x`, fading out over the last fifth of `width` when it runs past
// it. A tab advances CHANGES_TAB_COLUMNS spaces. `spans` are byte offsets into `s`, which starts where
// the line does, so the walk colours each rune by the span it is in; text outside them takes `ink`. Spans
// come from the whole file, which a clean or smudge filter can make differ from the diff text, so they are
// only read at offsets inside `s`: one reaching past the end colours what is inside, and an empty or
// out-of-order one is skipped.
@(private = "file")
paint_text :: proc(
	p: ^Diff_Paint, s: string, spans: []syntax.Span, x, baseline, width: f32, ink: render.Color,
) -> render.Build_Status {
	if width <= 0 {return .Ok}
	t := p.mono
	palette := CHANGES_SYNTAX_PALETTE
	space: f32
	if g, found := font.glyph_lookup(t.fonts, t.family, .Regular, ' '); found {
		space = font.glyph_advance(t.fonts, g, t.size_px)
	}
	start := len(p.list.glyphs)
	pen := x
	next := 0
	clipped := false
	for r, offset in s {
		if pen >= x + width {
			clipped = true
			break
		}
		for next < len(spans) && int(spans[next].end) <= offset {next += 1}
		c := ink
		if next < len(spans) && int(spans[next].start) <= offset {
			index := palette[spans[next].kind]
			c = index >= 0 ? p.theme.palette[index] : p.theme.text
		}
		if r == '\t' {
			pen += CHANGES_TAB_COLUMNS * space
			continue
		}
		g, found := font.glyph_lookup(t.fonts, t.family, .Regular, r)
		if !found {continue}
		if result := draw_glyph(t, p.list, g, pen, baseline, c); result != .Ok {return result}
		pen += font.glyph_advance(t.fonts, g, t.size_px)
	}
	if clipped || pen > x + width {
		for &glyph in p.list.glyphs[start:] {
			glyph.flags |= render.GLYPH_FADE
			glyph.fade_start, glyph.fade_end = x + width * 0.8, x + width
		}
	}
	return .Ok
}

// The spans of flat line `line` of `file`, and whether the file is highlighted at all.
@(private = "file")
line_spans :: proc(view: ^Changes_View, file, line: int) -> (spans: []syntax.Span, highlighted: bool) {
	if file < 0 || file >= len(view.highlights) {return nil, false}
	lines := view.highlights[file].lines
	if line < 0 || line >= len(lines) {return nil, len(lines) > 0}
	return lines[line], true
}

// Whether flat line `line` of `file` is in the selection.
@(private = "file")
line_selected :: proc(view: ^Changes_View, file, line: int) -> bool {
	s := view.selection
	return s.active && s.file == file && line >= min(s.first, s.last) && line <= max(s.first, s.last)
}

@(private = "file")
paint_line :: proc(
	p: ^Diff_Paint, line: ^tr.Diff_Line, file, flat: int, y, height: f32,
) -> render.Build_Status {
	t := p.theme
	baseline := baseline_in(y, height, p.mono)
	row := render.Rect{p.card_x, y, p.card_width, height}
	switch line.kind {
	case .Added:
		draw_rect(p.list, {rect = row, color = t.diff_added})
	case .Removed:
		draw_rect(p.list, {rect = row, color = t.diff_removed})
	case .Context, .No_Newline:
	}
	if line_selected(p.view, file, flat) {
		draw_rect(p.list, {rect = row, color = t.selection})
		draw_rect(p.list, {rect = {row.x, y, max(1, math.round(2 * p.scale)), height}, color = t.accent})
	}
	if line.kind == .No_Newline {
		return draw_fading_text(
			p.mono, p.list, "No newline at end of file", p.text_x, baseline, t.faint,
			p.card_x + p.card_width - p.text_x,
		)
	}
	if line.kind != .Added {
		if r := number_draw(p, line.old_line, p.old_x, baseline); r != .Ok {return r}
	}
	if line.kind != .Removed {
		if r := number_draw(p, line.new_line, p.new_x, baseline); r != .Ok {return r}
	}
	spans, highlighted := line_spans(p.view, file, flat)
	ink := highlighted ? t.text : t.muted
	switch line.kind {
	case .Added:
		if r := draw_text(p.mono, p.list, "+", p.sign_x, baseline, t.success); r != .Ok {return r}
		ink = t.text
	case .Removed:
		if r := draw_text(p.mono, p.list, "-", p.sign_x, baseline, t.error); r != .Ok {return r}
		ink = t.text
	case .Context, .No_Newline:
	}
	width := p.card_x + p.card_width - p.text_x
	return paint_text(p, mono_prefix(line.text, width, p.digit), spans, p.text_x, baseline, width, ink)
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
	#partial switch d.kind {
	case .Added:
		draw_rect(p.list, {rect = cell, color = t.diff_added})
	case .Removed:
		draw_rect(p.list, {rect = cell, color = t.diff_removed})
	}
	if line_selected(p.view, file, line) {
		draw_rect(p.list, {rect = cell, color = t.selection})
		bar := render.Rect{cell.x, cell.y, max(1, math.round(2 * s)), cell.height}
		draw_rect(p.list, {rect = bar, color = t.accent})
	}
	baseline := baseline_in(cell.y, cell.height, p.mono)
	number_x := cell.x + SPACE_2 * s
	sign_x := number_x + p.column + SPACE_2 * s
	text_x := sign_x + p.digit + SPACE_1 * s
	width := cell.x + cell.width - text_x
	if d.kind == .No_Newline {
		return draw_fading_text(p.mono, p.list, "No newline at end of file", text_x, baseline, t.faint, width)
	}
	if r := number_draw(p, old ? d.old_line : d.new_line, number_x, baseline); r != .Ok {return r}
	spans, highlighted := line_spans(p.view, file, line)
	ink := highlighted ? t.text : t.muted
	#partial switch d.kind {
	case .Added:
		if r := draw_text(p.mono, p.list, "+", sign_x, baseline, t.success); r != .Ok {return r}
		ink = t.text
	case .Removed:
		if r := draw_text(p.mono, p.list, "-", sign_x, baseline, t.error); r != .Ok {return r}
		ink = t.text
	}
	return paint_text(p, mono_prefix(d.text, width, p.digit), spans, text_x, baseline, width, ink)
}

// Hunk `index` of `file`, whose first line is flat line `flat`: its header row, then its rows.
@(private = "file")
paint_hunk :: proc(
	p: ^Diff_Paint, rows: ^Changes_Rows, h: ^tr.Hunk, file, index, flat: int, y: f32,
) -> render.Build_Status {
	t, s := p.theme, p.scale
	header := render.Rect{p.card_x, y, p.card_width, f32(rows.hunk)}
	draw_rect(p.list, {rect = header, color = t.code_background})
	pointed := p.pointer.y >= p.top && p.pointer.y < p.bottom
	commenting := len(h.lines) > 0 && pointed && render.rect_contains(header, p.pointer.x, p.pointer.y)
	buf: [64]u8
	label := fmt.bprintf(buf[:], "@@ -%d,%d +%d,%d @@", h.old_start, h.old_count, h.new_start, h.new_count)
	baseline := baseline_in(y, f32(rows.hunk), p.mono)
	room := p.card_width - 2 * SPACE_2 * s
	if commenting {room -= header.height + SPACE_1 * s}
	x := p.card_x + SPACE_2 * s
	if r := draw_fading_text(p.mono, p.list, label, x, baseline, t.muted, room); r != .Ok {return r}
	if h.section != "" {
		after := text_width(p.mono, label) + SPACE_2 * s
		section := mono_prefix(h.section, room - after, p.digit)
		if r := draw_fading_text(p.mono, p.list, section, x + after, baseline, t.faint, room - after);
		   r != .Ok {return r}
	}
	if commenting {
		hover, press := changes_lit(p.state, {.Hunk_Comment, file, flat})
		button := hunk_comment_rect(header, s)
		if icon_button_draw(
			p.list, t, button, .Comment, hover, press, s, p.pointer, ICON_INDICATOR, RADIUS_CONTROL,
		) != .None {return .Ok}
	}
	top := y + f32(rows.hunk)
	height := f32(rows.line)
	base, count := hunk_rows(rows, file, index)
	for i := hunk_row_at(rows, p.view, file, base, count, int(p.top - top)); i < count; i += 1 {
		row := top + f32(row_offset(rows, p.view, file, base, i))
		if row >= p.bottom {break}
		pair := row_pair(rows, file, base + i)
		if rows.pairs.side_by_side {
			left, right, divider := row_halves({p.card_x, row, p.card_width, height})
			if r := paint_cell(p, h, file, flat, int(pair.left), true, left); r != .Ok {return r}
			if r := paint_cell(p, h, file, flat, int(pair.right), false, right); r != .Ok {return r}
			draw_rect(p.list, {rect = divider, color = t.border})
		} else if at := int(pair.left) - flat; at >= 0 && at < len(h.lines) {
			if r := paint_line(p, &h.lines[at], file, int(pair.left), row, height); r != .Ok {return r}
		}
	}
	return .Ok
}

@(private = "file")
paint_file :: proc(p: ^Diff_Paint, rows: ^Changes_Rows, i: int, y: f32) -> render.Build_Status {
	t, s := p.theme, p.scale
	view := p.view
	f := &view.files[i]
	head := render.Rect{p.card_x, y, p.card_width, f32(rows.header)}
	collapsed := changes_collapsed(view, i)
	hover, press := changes_lit(p.state, {.File_Header, i, 0})
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
	if r := draw_fading_text(
		body, p.list, file_label(label_buf[:], f), x, baseline_in(face.y, face.height, body), t.text,
		right - x,
	); r != .Ok {return r}
	if collapsed {return .Ok}

	top := y + f32(rows.header)
	if f.binary || len(f.hunks) == 0 {
		note := f.binary ? "Binary file" : "No content changes"
		return draw_text(
			p.small, p.list, note, p.card_x + CONTROL_INSET * s, baseline_in(top, f32(rows.note), p.small),
			t.muted,
		)
	}
	paint_gutter(p, f)
	flat := 0
	for &hunk, h in f.hunks {
		base, count := hunk_rows(rows, i, h)
		height := f32(rows.hunk + count * rows.line + cards_through(rows, view, i, base, base + count - 1))
		if top + height > p.top {
			if top >= p.bottom {break}
			if r := paint_hunk(p, rows, &hunk, i, h, flat, top); r != .Ok {return r}
		}
		top += height
		flat += len(hunk.lines)
	}
	return .Ok
}

// A comment's card: its text with a delete button, or the editor while it is being written.
@(private = "file")
paint_card :: proc(p: ^Diff_Paint, rect: render.Rect, card: int) -> render.Build_Status {
	t, s := p.theme, p.scale
	view := p.view
	radius := RADIUS_CONTROL * s
	draw_rect(p.list, {rect = rect, color = t.surface, radius = radius})
	draw_rect(p.list, {rect = rect, color = t.border, radius = radius, stroke = s})
	if card == view.editing {
		if view.editor == nil {return .Ok}
		field := editor_field_rect(rect, s)
		box := field_box_standard(view.editor, p.body, field, s)
		box_draw(p.list, field, t, true, s)
		if r := field_box_draw(box, p.list, t, field_box_baseline(box), true, "Write a comment"); r != .Ok {
			return r
		}
		baseline := field.y + field.height + SPACE_1 * s + p.small.ascent
		hint := CHANGES_COMMENT_HINT
		return draw_fading_text(p.small, p.list, hint, field.x, baseline, t.muted, field.width)
	}
	if card >= len(view.comments) {return .Ok}
	hover, press := changes_lit(p.state, {.Comment_Delete, card, 0})
	delete := card_delete_rect(rect, s)
	if icon_button_draw(
		p.list, t, delete, .Close, hover, press, s, p.pointer, ICON_INDICATOR, RADIUS_CONTROL,
	) != .None {return .Ok}
	text := view.comments[card].text
	lines := Wrap_Lines {
		text       = p.body,
		s          = text,
		width      = card_text_width(rect.width, s),
		last_space = -1,
	}
	x := rect.x + SPACE_2 * s
	y := rect.y + SPACE_2 * s
	for {
		start, end, ok := wrap_next(&lines)
		if !ok || y >= p.bottom {break}
		if y + p.body.line_height > p.top {
			line := text[start:end]
			if r := draw_text(p.body, p.list, line, x, y + p.body.ascent, t.text); r != .Ok {return r}
		}
		y += p.body.line_height
	}
	return .Ok
}

// The cards, the "Not in this diff" heading and the Comment button, over the rows they belong to.
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
		rect, shown := card_rect(g, view, state, card)
		if !shown || rect.y >= p.bottom || rect.y + rect.height <= p.top {continue}
		if r := paint_card(p, rect, card); r != .Ok {return r}
	}
	if button := changes_comment_button_rect(g, view, state); button.width > 0 {
		return text_button_draw(p.list, p.small, p.theme, button, "Comment", false, p.scale, p.pointer)
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
	scope, opened := clip_scope_open(list, g.diff)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	s := g.scale
	small := text_styled(text, .Detail)
	strong := text_styled(text, .Strong)
	pad := SPACE_2 * s
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
		card_x     = g.diff.x + pad,
		card_width = max(0, g.diff.width - 2 * pad),
		top        = g.diff.y,
		bottom     = g.diff.y + g.diff.height,
		digit      = text_width(mono, "0"),
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
	return paint_comments(&p, g, rows)
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
	noun := view.send.count == 1 ? "comment" : "comments"
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
