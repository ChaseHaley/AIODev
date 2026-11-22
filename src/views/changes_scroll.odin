package views

import "cosmos:font"
import tr "aio:turns"
import "core:fmt"
import "core:math"
import "cosmos:ui"

// Sideways scrolling of the diff's code. A line too long for its cell is never cut short or faded: the
// code columns of every file scroll together, a whole text column at a time, by a sideways wheel or Shift
// and the wheel, by the scrollbar along the diff's bottom edge, and by a text drag that runs out of its
// cell. Each file stops at its own widest line, so a file of short lines stays put while a long one scrolls
// on. The numbers, signs, file headers and note cards do not move. One offset serves both layouts, so a
// removed line and the added line beside it stay under each other.

@(private)
CHANGES_NO_NEWLINE :: "No newline at end of file"

@(private)
CHANGES_HUNK_LABEL_BYTES :: 64

// A hunk's header text before its section: the line ranges between @@ marks.
@(private)
hunk_label :: proc(buf: []u8, h: ^tr.Hunk) -> string {
	return fmt.bprintf(buf, "@@ -%d,%d +%d,%d @@", h.old_start, h.old_count, h.new_start, h.new_count)
}

// The widest code line of every file and the widest of its hunk header rows (label, a space and section),
// in pixels. They are measured when the diff or the diff's font changes, so neither scrolling nor drawing
// the scrollbar walks the text.
Changes_Widths :: struct {
	built:      bool,
	revision:   u64,
	files:      int,
	size:       f32,
	family:     font.Family,
	code:       [dynamic][2]f32,
	head:       [dynamic]f32,
}

@(private)
changes_widths_build :: proc(w: ^Changes_Widths, view: ^Changes_View, mono: ^ui.Text) {
	if w.built && w.revision == view.revision && w.files == len(view.files) && w.size == mono.size_px &&
	   w.family == mono.family {return}
	w.built, w.revision, w.files = true, view.revision, len(view.files)
	w.size, w.family = mono.size_px, mono.family
	clear(&w.code)
	clear(&w.head)
	f := code_font(mono)
	for &file in view.files {
		code: [2]f32
		head: f32
		for &hunk in file.hunks {
			buf: [CHANGES_HUNK_LABEL_BYTES]u8
			width := code_width(mono, f, hunk_label(buf[:], &hunk))
			if hunk.section != "" {width += f.cell + code_width(mono, f, hunk.section)}
			head = max(head, width)
			side := tr.Line_Kind.Context
			for &line in hunk.lines {
				text := line.kind == .No_Newline ? CHANGES_NO_NEWLINE : line.text
				line_width := code_width(mono, f, text)
				if line.kind != .No_Newline {side = line.kind}
				if side != .Added {code[0] = max(code[0], line_width)}
				if side != .Removed {code[1] = max(code[1], line_width)}
			}
		}
		_, code_error := append(&w.code, code)
		_, head_error := append(&w.head, head)
		if code_error != nil || head_error != nil {
			// Out of memory: no file scrolls.
			clear(&w.code)
			clear(&w.head)
			return
		}
	}
}

// The room each side has for code text, or the unified row's room in the first slot.
@(private)
code_rooms :: proc(rows: ^Changes_Rows, f: ^tr.Diff_File, band: f32) -> [2]f32 {
	number := code_number_width(f, rows.digit)
	if !rows.pairs.side_by_side {
		return {code_column({0, 0, band, 0}, number, rows.digit, rows.scale, true).width, 0}
	}
	left, right, _ := row_halves({0, 0, band, 0}, rows.split_left)
	return {
		code_column(left, number, rows.digit, rows.scale, false).width,
		code_column(right, number, rows.digit, rows.scale, false).width,
	}
}

// What a hunk header row's text has room for: the band less its padding at both ends and the room the
// hunk's select button keeps at the right.
@(private)
head_room :: proc(rows: ^Changes_Rows, band: f32) -> f32 {
	return max(0, band - 2 * ui.SPACE_2 * rows.scale - f32(rows.hunk) - ui.SPACE_1 * rows.scale)
}

// How many text columns file `file` can scroll: how far its widest code line and hunk header row run past
// the room each has.
@(private)
file_scroll_extent :: proc(
	rows: ^Changes_Rows, view: ^Changes_View, file: int, band: f32,
) -> (limit, shown: int) {
	w := &rows.widths
	if file < 0 || file >= len(w.code) || file >= len(w.head) || file >= len(view.files) || rows.digit <= 0 {
		return
	}
	rooms := code_rooms(rows, &view.files[file], band)
	width := w.code[file]
	room := rooms[0]
	over := width[0] - room
	if rows.pairs.side_by_side {
		if right := width[1] - rooms[1]; right > over {over, room = right, rooms[1]}
	} else {
		over = max(width[0], width[1]) - room
	}
	head := head_room(rows, band)
	if extra := w.head[file] - head; extra > over {over, room = extra, head}
	if over <= CODE_EDGE {return}
	return int(math.ceil(over / rows.digit - CODE_EDGE)), int(room / rows.digit)
}

// How many text columns file `file`'s rows are scrolled by: the pane's offset, held at the file's limit.
@(private)
changes_h_columns :: proc(state: ^Changes_State, view: ^Changes_View, file: int, band: f32) -> int {
	if view.wrap {return 0}
	limit, _ := file_scroll_extent(&state.rows, view, file, band)
	return min(state.h_scroll, limit)
}

// The most columns any shown file scrolls, and how many columns of text the room of the file that scrolls
// most holds. Both are zero while nothing scrolls.
changes_h_extent :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State,
) -> (
	limit, shown: int,
) {
	rows := &state.rows
	if view.wrap || !rows.valid || view.notice != .None || len(rows.tops) != len(view.files) + 1 ||
	   rows.digit <= 0 {
		return
	}
	band := diff_band(g).width
	for &file, i in view.files {
		if changes_collapsed(view, i) || file.binary || len(file.hunks) == 0 {continue}
		if more, room := file_scroll_extent(rows, view, i, band); more > limit {limit, shown = more, room}
	}
	return
}

// Scrolls the code `delta` columns, right when positive; true when it moved. The offset stays within what
// the widest file shown scrolls.
changes_scroll_columns :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, delta: int,
) -> bool {
	limit, _ := changes_h_extent(g, view, state)
	before := state.h_scroll
	state.h_scroll = clamp(before + delta, 0, limit)
	return state.h_scroll != before
}

// The scrollbar along the diff's bottom edge; nothing is shown while no file scrolls. Its extents are
// columns.
changes_h_scrollbar :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State,
) -> (
	bar: ui.Scrollbar,
	visible: bool,
) {
	limit, shown := changes_h_extent(g, view, state)
	if limit <= 0 {return}
	extent := ui.Scroll_Extent{limit + shown, shown, clamp(state.h_scroll, 0, limit)}
	hovered := state.hover.part == .H_Scroll
	return ui.scrollbar_layout_horizontal(g.diff, extent, ui.scrollbar_state(hovered, state.h_bar), g.scale)
}

// One page of a held track press toward (x, y) on the scrollbar along the diff's bottom edge; see
// scrollbar_page.
changes_h_page :: proc(
	state: ^Changes_State, g: Changes_Geometry, view: ^Changes_View, x, y: f32, side: ui.Scroll_Side,
) -> ui.Scroll_Page {
	bar, visible := changes_h_scrollbar(g, view, state)
	if !visible {return .Off_Track}
	offset, result := ui.scrollbar_page(bar, x, y, side)
	if result == .Paged {_ = changes_scroll_columns(state, g, view, offset - state.h_scroll)}
	return result
}

// The bytes of flat line `line` of `file` that show: from the first rune the scroll reaches to where the
// room ends. False when the line has no row. The harness reads it to check that the end of a long line can
// be reached.
changes_line_visible :: proc(
	g: Changes_Geometry, view: ^Changes_View, state: ^Changes_State, mono: ^ui.Text, file, line: int,
) -> (
	from, to: int,
	ok: bool,
) {
	_, column := changes_line_code(g, view, state, mono, file, line) or_return
	text, _ := line_text(view, file, line)
	if wrap_valid(&state.rows) {return 0, len(text), true}
	from = code_offset_at(mono, text, column.width, -1, column.scroll)
	to = code_offset_at(mono, text, column.width, max(f32), column.scroll)
	return from, to, true
}
