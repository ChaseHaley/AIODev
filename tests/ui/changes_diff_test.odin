package ui_test

import "aio:colour"
import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:syntax"
import "aio:turns"
import "aio:ui"
import "core:testing"

@(private = "file")
Diff_Fixture :: struct {
	fonts:      ^font.System,
	text, mono: ui.Text,
	lines:      [3]turns.Diff_Line,
	hunks:      [1]turns.Hunk,
	files:      [1]turns.Diff_File,
	comments:   [2]ui.Changes_Comment_View,
	editor:     ui.Text_Field,
	side_lines: [10]turns.Diff_Line,
	ends:       [4]turns.Diff_Line,
	side_hunks: [2]turns.Hunk,
	side_files: [2]turns.Diff_File,
}

// One file with one hunk: a context, a removed and an added line, in a git scope so the diff spans the
// pane. Nothing is selected or edited.
@(private = "file")
diff_fixture_make :: proc(t: ^testing.T, f: ^Diff_Fixture, view: ^ui.Changes_View) -> bool {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, nil, 13)) {
		font.system_destroy(f.fonts)
		return false
	}
	f.mono = ui.text_mono(&f.text, f.text.family)
	f.lines = {
		{kind = .Context, old_line = 1, new_line = 1, text = "ab"},
		{kind = .Removed, old_line = 2, text = "b"},
		{kind = .Added, new_line = 2, text = "\tab"},
	}
	f.hunks = {{old_start = 1, old_count = 2, new_start = 1, new_count = 2, lines = f.lines[:]}}
	f.files = {{old_path = "a.odin", new_path = "a.odin", status = .Modified, added = 1, removed = 1,
		hunks = f.hunks[:]}}
	view^ = {
		scope    = .Uncommitted,
		first    = -1,
		last     = -1,
		files    = f.files[:],
		editing  = -1,
		editor   = &f.editor,
		revision = 1,
	}
	return true
}

@(private = "file")
diff_fixture_destroy :: proc(f: ^Diff_Fixture) {
	delete(f.editor.bytes)
	font.system_destroy(f.fonts)
}

@(private = "file")
lay_out :: proc(f: ^Diff_Fixture, view: ^ui.Changes_View, state: ^ui.Changes_State) -> ui.Changes_Geometry {
	g := ui.changes_geometry({0, 0, 900, 600}, 1, view, &f.text)
	ui.changes_layout(state, view, &f.text, &f.mono, g.diff.width, 1)
	return g
}

// Two files for the side-by-side layout. The first: a context line, a replace run of two removed and three
// added lines, a context line, a lone added line, a context line and a lone removed line. The second: a
// changed last line without a newline on either side.
@(private = "file")
side_by_side_use :: proc(f: ^Diff_Fixture, view: ^ui.Changes_View) {
	f.side_lines = {
		{kind = .Context, old_line = 1, new_line = 1, text = "a"},
		{kind = .Removed, old_line = 2, text = "r1"},
		{kind = .Removed, old_line = 3, text = "r2"},
		{kind = .Added, new_line = 2, text = "a1"},
		{kind = .Added, new_line = 3, text = "a2"},
		{kind = .Added, new_line = 4, text = "a3"},
		{kind = .Context, old_line = 4, new_line = 5, text = "b"},
		{kind = .Added, new_line = 6, text = "n"},
		{kind = .Context, old_line = 5, new_line = 7, text = "c"},
		{kind = .Removed, old_line = 6, text = "x"},
	}
	f.ends = {
		{kind = .Removed, old_line = 1, text = "x"},
		{kind = .No_Newline},
		{kind = .Added, new_line = 1, text = "y"},
		{kind = .No_Newline},
	}
	f.side_hunks = {
		{old_start = 1, old_count = 6, new_start = 1, new_count = 7, lines = f.side_lines[:]},
		{old_start = 1, old_count = 1, new_start = 1, new_count = 1, lines = f.ends[:]},
	}
	f.side_files = {
		{old_path = "a.odin", new_path = "a.odin", status = .Modified, added = 4, removed = 3,
			hunks = f.side_hunks[:1]},
		{old_path = "b.odin", new_path = "b.odin", status = .Modified, added = 1, removed = 1,
			hunks = f.side_hunks[1:]},
	}
	view.files = f.side_files[:]
	view.side_by_side = true
	view.revision += 1
}

@(private = "file")
centre :: proc(r: render.Rect) -> [2]f32 {return {r.x + r.width / 2, r.y + r.height / 2}}

@(test)
changes_diff_colours_spans_through_tabs :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)

	// Both "a"s are keywords and both "b"s strings; the added line starts with a tab. The removed line's
	// spans lie past its end or run backwards, as a filtered file's can, so it stays plain.
	context_spans := [?]syntax.Span{{0, 1, .Keyword}, {1, 2, .String}}
	removed_spans := [?]syntax.Span{{3, 99, .Number}, {1, 0, .Tag}}
	added_spans := [?]syntax.Span{{1, 2, .Keyword}, {2, 3, .String}}
	file_lines := [?][]syntax.Span{context_spans[:], removed_spans[:], added_spans[:]}
	highlights := [?]syntax.File_Lines{{lines = file_lines[:]}}
	view.highlights = highlights[:]
	theme: ui.Theme
	theme.text = {1, 1, 1, 1}
	theme.palette[5] = {1, 0, 0, 1}
	theme.palette[2] = {0, 1, 0, 1}
	theme.palette[3] = {0, 0, 1, 1}
	theme.palette[1] = {1, 1, 0, 1}

	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	// The pane opens a layer before it draws; the view draws into it.
	testing.expect_value(t, render.push_layer(&list, g.area), render.Error.None)
	status, _ := ui.changes_draw(&list, &f.text, &f.mono, &theme, g, &view, &state, 1, {-1, -1}, 0)
	testing.expect_value(t, status, render.Build_Status.Ok)

	keywords, strings_: [dynamic]render.Rect
	defer delete(keywords)
	defer delete(strings_)
	for glyph in list.glyphs {
		if glyph.color == theme.palette[5] {append(&keywords, glyph.rect)}
		if glyph.color == theme.palette[2] {append(&strings_, glyph.rect)}
	}
	if !testing.expect_value(t, len(keywords), 2) || !testing.expect_value(t, len(strings_), 2) {return}
	tab := ui.text_width(&f.mono, "    ")
	testing.expect(t, abs(keywords[1].x - keywords[0].x - tab) <= 1)
	testing.expect(t, abs(strings_[1].x - strings_[0].x - tab) <= 1)
	testing.expect(t, strings_[0].x > keywords[0].x)
	removed := ui.changes_line_rect(g, &view, &state, 0, 1)
	plain := 0
	for glyph in list.glyphs {
		testing.expect(t, glyph.color != theme.palette[3] && glyph.color != theme.palette[1])
		inside := glyph.rect.y >= removed.y && glyph.rect.y < removed.y + removed.height
		if inside && glyph.color == theme.text {plain += 1}
	}
	testing.expect_value(t, plain, 1)
}

@(test)
changes_rows_include_comment_cards :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	g := lay_out(&f, &view, &state)
	plain := state.rows.total
	added := ui.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect(t, added.height > 0)

	// A comment on the first two lines puts its card between them and the added line, without a new revision.
	f.comments[0] = {file = 0, first = 0, last = 1, text = "Rename this"}
	view.comments = f.comments[:1]
	g = lay_out(&f, &view, &state)
	if !testing.expect_value(t, len(state.rows.cards), 2) {return}
	card := state.rows.cards[0]
	testing.expect(t, card >= 32)
	testing.expect_value(t, state.rows.cards[1], 0)
	testing.expect_value(t, state.rows.total, plain + card + 8)
	moved := ui.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, moved.y, added.y + f32(card + 8))
	testing.expect_value(t, ui.changes_line_rect(g, &view, &state, 0, 1).y,
		ui.changes_line_rect(g, &view, &state, 0, 0).y + f32(state.rows.line))

	// A longer text wraps onto more lines and grows the card.
	long := "This comment is long enough that it has to wrap onto a second line in a card this narrow. "
	f.comments[0].text = long
	ui.changes_layout(&state, &view, &f.text, &f.mono, 300, 1)
	testing.expect(t, state.rows.cards[0] > card)

	// Writing a new comment under the selection adds the editor's card.
	f.comments[0].text = "Rename this"
	view.selection = {file = 0, first = 2, last = 2, active = true}
	view.editing = 1
	g = lay_out(&f, &view, &state)
	editor := 8 + 32 + 4 + 8 + int(ui.text_styled(&f.text, .Detail).line_height)
	testing.expect_value(t, state.rows.cards[1], editor)
	testing.expect_value(t, state.rows.total, plain + card + 8 + editor + 8)

	// A detached comment moves to the "Not in this diff" group at the end.
	view.editing = -1
	f.comments[0].detached = true
	g = lay_out(&f, &view, &state)
	testing.expect_value(t, state.rows.detached, state.rows.header + card + 8 + state.rows.gap)
	testing.expect_value(t, state.rows.total, plain + state.rows.detached)
	testing.expect_value(t, ui.changes_line_rect(g, &view, &state, 0, 2).y, added.y)
}

@(test)
changes_diff_hit_finds_lines_buttons_and_cards :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	f.comments[0] = {file = 0, first = 0, last = 0, text = "Why?"}
	view.comments = f.comments[:1]
	view.send = {count = 1, target = "claude", can_send = true}
	g := lay_out(&f, &view, &state)
	rows := &state.rows

	header := ui.changes_diff_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, header, ui.Changes_Hit{.File_Header, 0, 0})

	// The gutter and the text of a line both count as the line.
	row := ui.changes_line_rect(g, &view, &state, 0, 2)
	gutter := ui.changes_diff_hit(g, &view, &state, row.x + 2, row.y + 2)
	testing.expect_value(t, gutter, ui.Changes_Hit{.Line, 0, 2})
	text := ui.changes_diff_hit(g, &view, &state, row.x + row.width / 2, row.y + row.height - 1)
	testing.expect_value(t, text, ui.Changes_Hit{.Line, 0, 2})

	// The hunk header's comment button sits at its right end; the rest of the row is the diff.
	hunk_y := g.diff.y + f32(rows.header) + f32(rows.hunk) / 2
	right := g.diff.x + g.diff.width - 8 - 4 - f32(rows.hunk) / 2
	button := ui.changes_diff_hit(g, &view, &state, right, hunk_y)
	testing.expect_value(t, button, ui.Changes_Hit{.Hunk_Comment, 0, 0})
	rest := ui.changes_diff_hit(g, &view, &state, g.diff.x + 50, hunk_y)
	testing.expect_value(t, rest, ui.Changes_Hit{.Diff, 0, 0})

	// The card under the first line: the delete button at its top right, the rest edits it.
	first := ui.changes_line_rect(g, &view, &state, 0, 0)
	card := render.Rect{g.diff.x + 16, first.y + first.height + 4, g.diff.width - 32, f32(rows.cards[0])}
	on_card := ui.changes_diff_hit(g, &view, &state, card.x + 20, card.y + card.height / 2)
	testing.expect_value(t, on_card, ui.Changes_Hit{.Comment_Card, 0, 0})
	delete := ui.changes_diff_hit(g, &view, &state, card.x + card.width - 4 - 12, card.y + 4 + 12)
	testing.expect_value(t, delete, ui.Changes_Hit{.Comment_Delete, 0, 0})
	view.editing = 0
	g = lay_out(&f, &view, &state)
	editing := ui.changes_diff_hit(g, &view, &state, card.x + 20, card.y + 20)
	testing.expect_value(t, editing, ui.Changes_Hit{.Comment_Editor, 0, 0})
	box, shown := ui.changes_editor_box(g, &view, &state, &f.text)
	testing.expect(t, shown)
	testing.expect_value(t, box.rect, render.Rect{card.x + 8, card.y + 8, card.width - 16, 32})

	// With a selection and no editor, the Comment button covers the right end of its last row.
	view.editing = -1
	view.selection = {file = 0, first = 1, last = 2, active = true}
	g = lay_out(&f, &view, &state)
	comment := ui.changes_comment_button_rect(g, &view, &state)
	testing.expect(t, comment.width > 0)
	last := ui.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, comment.y, last.y)
	at := centre(comment)
	pressed := ui.changes_diff_hit(g, &view, &state, at.x, at.y)
	testing.expect_value(t, pressed, ui.Changes_Hit{.Comment_Button, 0, 2})

	// The send bar's buttons.
	send, copy, discard := ui.changes_send_rects(g, &view)
	rects := [?]render.Rect{send, copy, discard}
	parts := [?]ui.Changes_Part{.Send, .Copy, .Discard}
	for rect, i in rects {
		p := centre(rect)
		hit := ui.changes_diff_hit(g, &view, &state, p.x, p.y)
		testing.expect_value(t, hit, ui.Changes_Hit{parts[i], 0, 0})
	}
	testing.expect(t, send.x + send.width < copy.x && copy.x + copy.width < discard.x)
	testing.expect(t, discard.x + discard.width <= g.send_bar.x + g.send_bar.width)
	bare := ui.changes_diff_hit(g, &view, &state, g.send_bar.x + 20, g.send_bar.y + 20)
	testing.expect_value(t, bare, ui.Changes_Hit{})
}

@(test)
changes_send_bar_height_follows_the_comment_count :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	testing.expect_value(t, ui.changes_send_bar_height(&view, 1), f32(0))
	without := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, without.send_bar.height, f32(0))
	send, _, _ := ui.changes_send_rects(without, &view)
	testing.expect_value(t, send, render.Rect{})

	view.send.count = 3
	testing.expect_value(t, ui.changes_send_bar_height(&view, 1), f32(40))
	testing.expect_value(t, ui.changes_send_bar_height(&view, 2), f32(80))
	with := ui.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, with.send_bar, render.Rect{0, 560, 900, 40})
	testing.expect_value(t, with.diff.height, without.diff.height - 40)
}

@(test)
changes_pairs_share_rows_side_by_side :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	lay_out(&f, &view, &state)
	pairs := &state.rows.pairs
	testing.expect(t, pairs.side_by_side)
	// Context fills both cells; the replace run shares rows and pads the shorter side; lone runs get blank
	// cells; a No_Newline marker stays on the side it follows.
	want := [?]ui.Changes_Pair {
		{0, 0}, {1, 3}, {2, 4}, {-1, 5}, {6, 6}, {-1, 7}, {8, 8}, {9, -1},
		{0, 2}, {1, 3},
	}
	if !testing.expect_value(t, len(pairs.pairs), len(want)) {return}
	for pair, i in want {testing.expect_value(t, pairs.pairs[i], pair)}
	if testing.expect_value(t, len(pairs.file_pairs), 3) {
		testing.expect_value(t, pairs.file_pairs[1], 8)
		testing.expect_value(t, pairs.file_pairs[2], 10)
	}
	rows := &state.rows
	testing.expect_value(t, rows.tops[1], rows.header + rows.hunk + 8 * rows.line + rows.gap)

	// Unified, every line is its own row; switching rebuilds without a new revision.
	view.side_by_side = false
	lay_out(&f, &view, &state)
	testing.expect(t, !pairs.side_by_side)
	if testing.expect_value(t, len(pairs.pairs), 14) {
		testing.expect_value(t, pairs.pairs[3], ui.Changes_Pair{3, 3})
		testing.expect_value(t, pairs.pairs[11], ui.Changes_Pair{1, 1})
	}
	testing.expect_value(t, rows.tops[1], rows.header + rows.hunk + 10 * rows.line + rows.gap)
}

@(test)
changes_diff_side_by_side_hits_and_rects_per_half :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	inner := g.diff.width - 16

	// The replace row: the removed line in the left cell, the added line in the right one.
	left := ui.changes_line_rect(g, &view, &state, 0, 1)
	right := ui.changes_line_rect(g, &view, &state, 0, 3)
	testing.expect_value(t, left.y, right.y)
	testing.expect_value(t, left.x, g.diff.x + 8)
	testing.expect(t, left.x + left.width < right.x)
	testing.expect_value(t, right.x + right.width, g.diff.x + 8 + inner)
	at := centre(left)
	testing.expect_value(t, ui.changes_diff_hit(g, &view, &state, at.x, at.y), ui.Changes_Hit{.Line, 0, 1})
	at = centre(right)
	testing.expect_value(t, ui.changes_diff_hit(g, &view, &state, at.x, at.y), ui.Changes_Hit{.Line, 0, 3})

	// A context line fills the row, and both halves hit it.
	context_row := ui.changes_line_rect(g, &view, &state, 0, 0)
	testing.expect_value(t, context_row.width, inner)
	testing.expect_value(t, context_row.y, left.y - f32(state.rows.line))
	y := context_row.y + 2
	testing.expect_value(t, ui.changes_diff_hit(g, &view, &state, left.x + 4, y), ui.Changes_Hit{.Line, 0, 0})
	testing.expect_value(t, ui.changes_diff_hit(g, &view, &state, at.x, y), ui.Changes_Hit{.Line, 0, 0})

	// Blank cells: left of the third added line, right of the lone removed line.
	padded := ui.changes_line_rect(g, &view, &state, 0, 5)
	testing.expect_value(t, padded.x, right.x)
	blank := ui.changes_diff_hit(g, &view, &state, left.x + 4, padded.y + 2)
	testing.expect_value(t, blank, ui.Changes_Hit{.Diff, 0, 0})
	lone := ui.changes_line_rect(g, &view, &state, 0, 9)
	testing.expect_value(t, lone.x, left.x)
	lone_right := ui.changes_diff_hit(g, &view, &state, at.x, lone.y + 2)
	testing.expect_value(t, lone_right, ui.Changes_Hit{.Diff, 0, 0})
	lone_left := ui.changes_diff_hit(g, &view, &state, left.x + 4, lone.y + 2)
	testing.expect_value(t, lone_left, ui.Changes_Hit{.Line, 0, 9})

	// The No_Newline markers share the row under the changed line and are not lines to select.
	marker := ui.changes_line_rect(g, &view, &state, 1, 1)
	testing.expect_value(t, marker.y, ui.changes_line_rect(g, &view, &state, 1, 3).y)
	on_marker := ui.changes_diff_hit(g, &view, &state, left.x + 4, marker.y + 2)
	testing.expect_value(t, on_marker, ui.Changes_Hit{.Diff, 1, 0})

	// A card goes under the row that holds the comment's last line, across the whole width.
	f.comments[0] = {file = 0, first = 3, last = 3, text = "Why?"}
	view.comments = f.comments[:1]
	g = lay_out(&f, &view, &state)
	slot := f32(state.rows.cards[0] + 8)
	below := ui.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, below.y, left.y + f32(state.rows.line) + slot)
	testing.expect_value(t, ui.changes_line_rect(g, &view, &state, 0, 1).y, left.y)
	card_y := left.y + f32(state.rows.line) + 4 + 2
	card_left := ui.changes_diff_hit(g, &view, &state, left.x + 20, card_y)
	testing.expect_value(t, card_left, ui.Changes_Hit{.Comment_Card, 0, 0})
	card_right := ui.changes_diff_hit(g, &view, &state, at.x, card_y)
	testing.expect_value(t, card_right, ui.Changes_Hit{.Comment_Card, 0, 0})
}

@(test)
changes_diff_file_top_scrolls_to_a_file_in_both_layouts :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	tops: [2]int
	for side, i in ([2]bool{false, true}) {
		view.side_by_side = side
		lay_out(&f, &view, &state)
		tops[i] = state.rows.tops[1]
		testing.expect_value(t, ui.changes_diff_file_top(&state, &view, 1), tops[i])
		testing.expect_value(t, ui.changes_diff_file_top(&state, &view, 0), 0)
		state.diff_scroll = tops[i]
		testing.expect_value(t, ui.changes_top_file(&state, &view), 1)
		state.diff_scroll = tops[i] - 1
		testing.expect_value(t, ui.changes_top_file(&state, &view), 0)
		// No such file keeps the scroll.
		testing.expect_value(t, ui.changes_diff_file_top(&state, &view, 5), tops[i] - 1)
		state.diff_scroll = 0
	}
	// Side by side, the replace run takes fewer rows, so the second file starts higher.
	testing.expect(t, tops[1] < tops[0])
	view.notice = .No_Changes
	view.revision += 1
	lay_out(&f, &view, &state)
	testing.expect_value(t, ui.changes_top_file(&state, &view), -1)
}

@(test)
changes_side_by_side_cards_sit_under_the_lowest_selected_row :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	// Lines 0-3 are the context line, both removed lines and the first added one. The last of them, the
	// added line, is in row 1, but the second removed line is in row 2 below it.
	view.selection = {file = 0, first = 0, last = 3, active = true}
	g := lay_out(&f, &view, &state)
	removed := ui.changes_line_rect(g, &view, &state, 0, 2)
	button := ui.changes_comment_button_rect(g, &view, &state)
	testing.expect_value(t, button.y, removed.y)
	testing.expect(t, button.x > removed.x && button.x + button.width <= removed.x + removed.width)
	padded := ui.changes_line_rect(g, &view, &state, 0, 5).y

	// A comment on those lines sits under row 2: row 3 moves down, row 2 stays.
	f.comments[0] = {file = 0, first = 0, last = 3, text = "Why?"}
	view.comments = f.comments[:1]
	view.selection = {}
	g = lay_out(&f, &view, &state)
	slot := f32(state.rows.cards[0] + 8)
	testing.expect_value(t, ui.changes_line_rect(g, &view, &state, 0, 2).y, removed.y)
	testing.expect_value(t, ui.changes_line_rect(g, &view, &state, 0, 5).y, padded + slot)
	card := ui.changes_diff_hit(g, &view, &state, removed.x + 20, removed.y + f32(state.rows.line) + 6)
	testing.expect_value(t, card, ui.Changes_Hit{.Comment_Card, 0, 0})

	// With row 2's right cell selected too, the button moves to that cell.
	view.selection = {file = 0, first = 3, last = 4, active = true}
	g = lay_out(&f, &view, &state)
	added := ui.changes_line_rect(g, &view, &state, 0, 4)
	button = ui.changes_comment_button_rect(g, &view, &state)
	testing.expect_value(t, button.y, added.y)
	testing.expect(t, button.x > added.x && button.x + button.width <= added.x + added.width)
}

@(test)
changes_pairs_rebuild_only_for_a_new_diff_or_layout :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	lay_out(&f, &view, &state)
	pairs := &state.rows.pairs
	if !testing.expect(t, len(pairs.pairs) > 0) {return}
	marked := ui.Changes_Pair{42, 42}

	// A comment or a new width lays the stream out again but keeps the table.
	pairs.pairs[0] = marked
	f.comments[0] = {file = 0, first = 0, last = 0, text = "x"}
	view.comments = f.comments[:1]
	lay_out(&f, &view, &state)
	testing.expect_value(t, pairs.pairs[0], marked)
	ui.changes_layout(&state, &view, &f.text, &f.mono, 500, 1)
	testing.expect_value(t, pairs.pairs[0], marked)

	// A new revision or the other layout rebuilds it.
	view.revision += 1
	lay_out(&f, &view, &state)
	testing.expect_value(t, pairs.pairs[0], ui.Changes_Pair{0, 0})
	pairs.pairs[0] = marked
	view.side_by_side = false
	lay_out(&f, &view, &state)
	testing.expect_value(t, pairs.pairs[0], ui.Changes_Pair{0, 0})
}

@(test)
changes_sticky_header_pins_until_the_next_header_pushes_it_up :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)

	for side in ([2]bool{false, true}) {
		view.side_by_side = side
		g := lay_out(&f, &view, &state)
		rows := &state.rows
		header := f32(rows.header)

		// At the top of the stream every header is in its place.
		state.diff_scroll = 0
		file, rect := ui.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, -1)

		// Scrolled into the first file, its header pins to the top of the diff and takes the hits there.
		state.diff_scroll = 40
		file, rect = ui.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 0)
		testing.expect_value(t, rect, render.Rect{g.diff.x, g.diff.y, g.diff.width, header})
		at := centre(rect)
		pinned := ui.changes_diff_hit(g, &view, &state, at.x, at.y)
		testing.expect_value(t, pinned, ui.Changes_Hit{.Sticky_Header, 0, 0})
		below := ui.changes_diff_hit(g, &view, &state, at.x, rect.y + header + 1)
		testing.expect(t, below.part != .Sticky_Header)

		// The end of the file's body pushes it up as the next header arrives.
		end := rows.tops[1] - rows.gap
		state.diff_scroll = rows.tops[1] - 10
		file, rect = ui.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 0)
		testing.expect_value(t, rect.y, g.diff.y + 10 - f32(rows.gap) - header)
		// One pixel of it is left at the body's last row; its border falls in the gap, above the next header.
		state.diff_scroll = end - 1
		file, rect = ui.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 0)
		testing.expect_value(t, rect.y + rect.height, g.diff.y + 1)
		next_header := g.diff.y + f32(rows.tops[1] - state.diff_scroll)
		testing.expect(t, rect.y + rect.height + 1 <= next_header)
		// Once only the gap after the body is left, nothing sticks; then the second file's header does.
		state.diff_scroll = rows.tops[1] - rows.gap / 2
		file, _ = ui.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, -1)
		state.diff_scroll = rows.tops[1] + 5
		file, rect = ui.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 1)
		testing.expect_value(t, rect.y, g.diff.y)
	}

	// A collapsed file has no body to stick over.
	collapsed := [2]bool{true, false}
	view.collapsed = collapsed[:]
	g := lay_out(&f, &view, &state)
	state.diff_scroll = 5
	file, _ := ui.changes_sticky_header(&state, &view, g)
	testing.expect_value(t, file, -1)
	in_place := ui.changes_diff_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 2)
	testing.expect_value(t, in_place, ui.Changes_Hit{.File_Header, 0, 0})
}

// A layer draws its rects before its text, so the pinned header must sit in a later layer than the stream
// or the lines under it show through its fill.
@(test)
changes_sticky_header_draws_in_a_layer_above_the_stream :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	side_by_side_use(&f, &view)
	view.side_by_side = false
	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	// A short pane, so the draw keeps the scroll inside the first file.
	g := ui.changes_geometry({0, 0, 900, 150}, 1, &view, &f.text)
	ui.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	state.diff_scroll = 40
	sticky, rect := ui.changes_sticky_header(&state, &view, g)
	if !testing.expect_value(t, sticky, 0) {return}

	theme: ui.Theme
	theme.text = {1, 1, 1, 1}
	theme.pane = {0.1, 0.2, 0.3, 1}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, render.push_layer(&list, g.area), render.Error.None)
	status, _ := ui.changes_draw(&list, &f.text, &f.mono, &theme, g, &view, &state, 1, {-1, -1}, 0)
	testing.expect_value(t, status, render.Build_Status.Ok)

	fill := -1
	for r, i in list.rects {
		if r.color == theme.pane && r.rect == rect {fill = i}
	}
	if !testing.expect(t, fill >= 0) {return}
	layer := -1
	for l, i in list.layers {
		if fill >= l.rect_start && fill < l.rect_start + l.rect_count {layer = i}
	}
	if !testing.expect(t, layer > 0) {return}
	pinned := list.layers[layer]
	testing.expect_value(t, pinned.clip, g.diff)
	// The stream's text went into earlier layers; the header's own text is in this one.
	testing.expect_value(t, pinned.rect_start, fill)
	stream := 0
	for l in list.layers[:layer] {stream += l.glyph_count}
	testing.expect(t, stream > 0)
	testing.expect(t, pinned.glyph_count > 0)
}

@(private = "file")
hex :: proc(value: u32, alpha: u32 = 0xff) -> render.Color {
	channel :: proc(value: u32, shift: u32) -> f32 {return f32(value >> shift & 0xff) / 255}
	return {channel(value, 16), channel(value, 8), channel(value, 0), f32(alpha) / 255}
}

@(private = "file")
count_colour :: proc(list: ^render.Draw_List, row: render.Rect, ink: render.Color) -> int {
	count := 0
	for glyph in list.glyphs {
		inside := glyph.rect.y >= row.y && glyph.rect.y < row.y + row.height
		if inside && glyph.color == ink {count += 1}
	}
	return count
}

// Tokyo Night Moon's comment colour on an added row measures 1.25:1; the diff raises it to the minimum.
@(test)
changes_code_text_keeps_the_minimum_contrast :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Diff_Fixture
	view: ui.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)

	// The context line "ab" is a string; the added line's "ab" after its tab is a comment.
	context_spans := [?]syntax.Span{{0, 2, .String}}
	added_spans := [?]syntax.Span{{1, 3, .Comment}}
	file_lines := [?][]syntax.Span{context_spans[:], nil, added_spans[:]}
	highlights := [?]syntax.File_Lines{{lines = file_lines[:]}}
	view.highlights = highlights[:]
	theme: ui.Theme
	theme.pane = hex(0x222436)
	theme.diff_added = hex(0xc3e88d, 0x24)
	theme.text = hex(0xc8d3f5)
	theme.palette[8] = hex(0x444a73)
	theme.palette[2] = hex(0xc3e88d)
	a := theme.diff_added.a
	added := theme.diff_added * a + theme.pane * (1 - a)
	added.a = 1
	testing.expect(t, colour.contrast_ratio(theme.palette[8], added) < 1.5)

	state: ui.Changes_State
	defer ui.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	draw :: proc(
		t: ^testing.T,
		list: ^render.Draw_List,
		f: ^Diff_Fixture,
		theme: ^ui.Theme,
		g: ui.Changes_Geometry,
		view: ^ui.Changes_View,
		state: ^ui.Changes_State,
	) {
		render.draw_list_reset(list)
		testing.expect_value(t, render.push_layer(list, g.area), render.Error.None)
		status, _ := ui.changes_draw(list, &f.text, &f.mono, theme, g, view, state, 1, {-1, -1}, 0)
		testing.expect_value(t, status, render.Build_Status.Ok)
	}
	added_row := ui.changes_line_rect(g, &view, &state, 0, 2)
	context_row := ui.changes_line_rect(g, &view, &state, 0, 0)

	view.minimum_contrast = 4.5
	draw(t, &list, &f, &theme, g, &view, &state)
	comment := state.inks.table[.Added][8]
	testing.expect(t, colour.contrast_ratio(comment, added) >= 4.45)
	testing.expect_value(t, count_colour(&list, added_row, comment), 2)
	testing.expect_value(t, count_colour(&list, added_row, theme.palette[8]), 0)
	// A colour already past the ratio keeps the theme's value.
	testing.expect_value(t, state.inks.table[.Context][2], theme.palette[2])
	testing.expect_value(t, count_colour(&list, context_row, theme.palette[2]), 2)

	// The same theme and ratio draw again without rebuilding the table.
	builds := state.inks.builds
	draw(t, &list, &f, &theme, g, &view, &state)
	testing.expect_value(t, state.inks.builds, builds)

	// A ratio of one keeps the theme's exact colours.
	view.minimum_contrast = 1
	draw(t, &list, &f, &theme, g, &view, &state)
	testing.expect_value(t, state.inks.builds, builds + 1)
	testing.expect_value(t, count_colour(&list, added_row, theme.palette[8]), 2)
}
