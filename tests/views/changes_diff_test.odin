package views_test

import "cosmos:colour"
import "cosmos:font"
import "cosmos:glyphs"
import "cosmos:render"
import "aio:syntax"
import "aio:turns"
import "aio:views"
import "core:math"
import "core:strings"
import "core:testing"
import "cosmos:textedit"
import "cosmos:ui"

@(private = "file")
Diff_Fixture :: struct {
	fonts:      ^font.System,
	text, mono: ui.Text,
	lines:      [3]turns.Diff_Line,
	hunks:      [1]turns.Hunk,
	files:      [1]turns.Diff_File,
	comments:   [2]views.Changes_Comment_View,
	area:       ui.Text_Area,
	buffer:     textedit.Buffer,
	side_lines: [10]turns.Diff_Line,
	ends:       [4]turns.Diff_Line,
	side_hunks: [2]turns.Hunk,
	side_files: [2]turns.Diff_File,
}

// One file with one hunk: a context, a removed and an added line, in a git scope so the diff spans the
// pane. Nothing is selected or edited.
@(private = "file")
diff_fixture_make :: proc(t: ^testing.T, f: ^Diff_Fixture, view: ^views.Changes_View) -> bool {
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
		editor   = &f.area,
		buffer   = &f.buffer,
		revision = 1,
	}
	return true
}

@(private = "file")
diff_fixture_destroy :: proc(f: ^Diff_Fixture) {
	textedit.destroy(&f.buffer)
	ui.text_area_destroy(&f.area)
	font.system_destroy(f.fonts)
}

@(private = "file")
lay_out :: proc(f: ^Diff_Fixture, view: ^views.Changes_View, state: ^views.Changes_State) -> views.Changes_Geometry {
	g := views.changes_geometry({0, 0, 900, 600}, 1, view, &f.text)
	views.changes_layout(state, view, &f.text, &f.mono, g.diff.width, 1)
	return g
}

// Two files for the side-by-side layout. The first: a context line, a replace run of two removed and three
// added lines, a context line, a lone added line, a context line and a lone removed line. The second: a
// changed last line without a newline on either side.
@(private = "file")
side_by_side_use :: proc(f: ^Diff_Fixture, view: ^views.Changes_View) {
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
	view: views.Changes_View
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
	theme: views.Theme
	theme.text = {1, 1, 1, 1}
	theme.palette[5] = {1, 0, 0, 1}
	theme.palette[2] = {0, 1, 0, 1}
	theme.palette[3] = {0, 0, 1, 1}
	theme.palette[1] = {1, 1, 0, 1}

	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	// The pane opens a layer before it draws; the view draws into it.
	testing.expect_value(t, render.push_layer(&list, g.area), render.Error.None)
	status, _ := views.changes_draw(&list, &f.text, &f.mono, &theme, g, &view, &state, 1, {-1, -1}, 0)
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
	removed := views.changes_line_rect(g, &view, &state, 0, 1)
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
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	g := lay_out(&f, &view, &state)
	plain := state.rows.total
	added := views.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect(t, added.height > 0)

	// A comment on the first two lines puts its card between them and the added line, without a new revision.
	f.comments[0] = {file = 0, first = 0, last = 1, text = "Rename this"}
	view.comments = f.comments[:1]
	g = lay_out(&f, &view, &state)
	if !testing.expect_value(t, len(state.rows.cards), 2) {return}
	card := state.rows.cards[0]
	testing.expect(t, card >= 28)
	testing.expect_value(t, state.rows.cards[1], 0)
	// A card keeps 6 above it for its notch and 8 below it.
	testing.expect_value(t, state.rows.total, plain + card + 14)
	moved := views.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, moved.y, added.y + f32(card + 14))
	testing.expect_value(t, views.changes_line_rect(g, &view, &state, 0, 1).y,
		views.changes_line_rect(g, &view, &state, 0, 0).y + f32(state.rows.line))

	// A longer text wraps onto more lines and grows the card.
	long := "This comment is long enough that it has to wrap onto a second line in a card this narrow. "
	f.comments[0].text = long
	views.changes_layout(&state, &view, &f.text, &f.mono, 300, 1)
	testing.expect(t, state.rows.cards[0] > card)

	// Writing a new comment under the selection adds the editor's card: a header, the tools, a text area at
	// least three lines tall and a footer.
	f.comments[0].text = "Rename this"
	view.selection = {file = 0, first = 2, last = 2, active = true}
	view.editing = 1
	g = lay_out(&f, &view, &state)
	rect, shown := views.changes_card_rect(g, &view, &state, 1)
	testing.expect(t, shown)
	area := int(math.round(ui.text_area_height(&f.area, &f.buffer, &f.text, rect.width - 16, 1, 3, 12)))
	editor := 32 + 28 + 8 + 32 + area
	testing.expect_value(t, state.rows.cards[1], editor)
	testing.expect_value(t, state.rows.total, plain + card + 14 + editor + 14)

	// The card's height follows the text: more lines grow it, until the text area stops at twelve.
	before := state.rows.cards[1]
	testing.expect(t, textedit.reset(&f.buffer, "one\ntwo\nthree\nfour\nfive\nsix"))
	g = lay_out(&f, &view, &state)
	grown := state.rows.cards[1]
	testing.expect(t, grown > before)
	testing.expect(t, textedit.reset(&f.buffer, strings.repeat("line\n", 40, context.temp_allocator)))
	g = lay_out(&f, &view, &state)
	testing.expect(t, state.rows.cards[1] > grown)
	rect, _ = views.changes_card_rect(g, &view, &state, 1)
	capped := int(math.round(ui.text_area_height(&f.area, &f.buffer, &f.text, rect.width - 16, 1, 12, 12)))
	testing.expect_value(t, state.rows.cards[1], 32 + 28 + 8 + 32 + capped)

	// A detached comment moves to the "Not in this diff" group at the end.
	view.editing = -1
	f.comments[0].detached = true
	g = lay_out(&f, &view, &state)
	testing.expect_value(t, state.rows.detached, state.rows.header + card + 14 + state.rows.gap)
	testing.expect_value(t, state.rows.total, plain + state.rows.detached)
	testing.expect_value(t, views.changes_line_rect(g, &view, &state, 0, 2).y, added.y)
}

@(test)
changes_diff_hit_finds_lines_buttons_and_cards :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	f.comments[0] = {file = 0, first = 0, last = 0, text = "Why?"}
	view.comments = f.comments[:1]
	view.send = {count = 1, target = "claude", can_send = true}
	g := lay_out(&f, &view, &state)
	rows := &state.rows

	header := views.changes_diff_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 5)
	testing.expect_value(t, header, views.Changes_Hit{.File_Header, 0, 0})

	// The numbers and the sign pick the line; the code text starts a text selection.
	row := views.changes_line_rect(g, &view, &state, 0, 2)
	gutter := views.changes_diff_hit(g, &view, &state, row.x + 2, row.y + 2)
	testing.expect_value(t, gutter, views.Changes_Hit{.Gutter, 0, 2})
	text := views.changes_diff_hit(g, &view, &state, row.x + row.width / 2, row.y + row.height - 1)
	testing.expect_value(t, text, views.Changes_Hit{.Line, 0, 2})
	_, column, _ := views.changes_line_code(g, &view, &state, &f.mono, 0, 2)
	edge := views.changes_diff_hit(g, &view, &state, column.text_x - 1, row.y + 2)
	testing.expect_value(t, edge, views.Changes_Hit{.Gutter, 0, 2})
	edge = views.changes_diff_hit(g, &view, &state, column.text_x, row.y + 2)
	testing.expect_value(t, edge, views.Changes_Hit{.Line, 0, 2})

	// The hunk header's select button sits at its right end; the rest of the row is the diff.
	hunk_y := g.diff.y + f32(rows.header) + f32(rows.hunk) / 2
	right := g.diff.x + g.diff.width - 8 - 4 - f32(rows.hunk) / 2
	button := views.changes_diff_hit(g, &view, &state, right, hunk_y)
	testing.expect_value(t, button, views.Changes_Hit{.Hunk_Select, 0, 0})
	rest := views.changes_diff_hit(g, &view, &state, g.diff.x + 50, hunk_y)
	testing.expect_value(t, rest, views.Changes_Hit{.Diff, 0, 0})

	// The saved card starts at the code column, a notch's room under the line, and ends 12 from the right.
	// Edit and Remove sit at its top right; the rest of it is the card.
	first := views.changes_line_rect(g, &view, &state, 0, 0)
	card, on_stream := views.changes_card_rect(g, &view, &state, 0)
	testing.expect(t, on_stream)
	testing.expect_value(t, card.y, first.y + first.height + 6)
	_, first_column, _ := views.changes_line_code(g, &view, &state, &f.mono, 0, 0)
	testing.expect(t, abs(card.x - first_column.text_x) <= 0.5)
	testing.expect(t, abs(card.x + card.width - (g.diff.x + g.diff.width - 12)) < 0.01)
	on_card := views.changes_diff_hit(g, &view, &state, card.x + 20, card.y + card.height / 2)
	testing.expect_value(t, on_card, views.Changes_Hit{.Comment_Card, 0, 0})
	edit, remove := views.changes_note_actions(card, 1)
	testing.expect_value(t, remove, render.Rect{card.x + card.width - 3 - 22, card.y + 3, 22, 22})
	testing.expect_value(t, edit.x + edit.width + 1, remove.x)
	at := centre(edit)
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{.Comment_Edit, 0, 0})
	at = centre(remove)
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{.Comment_Remove, 0, 0})

	// Editing swaps the card for the editor: its tools, text area and buttons answer to the pointer, the rest
	// of it is the card, and a plain comment has no tag to take off.
	view.editing = 0
	g = lay_out(&f, &view, &state)
	parts, editing := views.changes_editor_of(g, &view, &state)
	testing.expect(t, editing)
	testing.expect_value(t, parts.card.x, card.x)
	testing.expect_value(t, parts.untag, render.Rect{})
	buttons := [?]struct {
		rect: render.Rect,
		part: views.Changes_Part,
	}{{parts.bold, .Editor_Bold}, {parts.code, .Editor_Code}, {parts.block, .Editor_Block},
		{parts.suggest, .Editor_Suggest}, {parts.cancel, .Editor_Cancel}, {parts.save, .Editor_Save},
		{parts.area, .Comment_Editor}}
	for button in buttons {
		at = centre(button.rect)
		testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{button.part, 0, 0})
	}
	at = centre(parts.header)
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{.Comment_Card, 0, 0})
	box, shown := views.changes_editor_box(g, &view, &state, &f.text)
	testing.expect(t, shown)
	testing.expect_value(t, box.rect, parts.area)
	testing.expect_value(t, parts.area.height, parts.card.height - 100)

	// A label's tag comes with its ×, which turns the note into a comment.
	f.comments[0].kind, f.comments[0].label_name, f.comments[0].label_colour = .Label, "Clarify", "blue"
	view.draft = .Label
	g = lay_out(&f, &view, &state)
	parts, _ = views.changes_editor_of(g, &view, &state)
	testing.expect(t, parts.tag.width > 0 && parts.untag.width > 0)
	testing.expect(t, parts.untag.x + parts.untag.width <= parts.tag.x + parts.tag.width)
	at = centre(parts.untag)
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{.Editor_Untag, 0, 0})
	view.editing = -1
	view.draft = .Comment
	g = lay_out(&f, &view, &state)

	// The send bar's buttons.
	send, copy, discard := views.changes_send_rects(g, &view)
	rects := [?]render.Rect{send, copy, discard}
	bar_parts := [?]views.Changes_Part{.Send, .Copy, .Discard}
	for rect, i in rects {
		p := centre(rect)
		hit := views.changes_diff_hit(g, &view, &state, p.x, p.y)
		testing.expect_value(t, hit, views.Changes_Hit{bar_parts[i], 0, 0})
	}
	testing.expect(t, send.x + send.width < copy.x && copy.x + copy.width < discard.x)
	testing.expect(t, discard.x + discard.width <= g.send_bar.x + g.send_bar.width)
	bare := views.changes_diff_hit(g, &view, &state, g.send_bar.x + 20, g.send_bar.y + 20)
	testing.expect_value(t, bare, views.Changes_Hit{})
}

@(test)
changes_send_bar_height_follows_the_comment_count :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	testing.expect_value(t, views.changes_send_bar_height(&view, 1), f32(0))
	without := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, without.send_bar.height, f32(0))
	send, _, _ := views.changes_send_rects(without, &view)
	testing.expect_value(t, send, render.Rect{})

	view.send.count = 3
	testing.expect_value(t, views.changes_send_bar_height(&view, 1), f32(40))
	testing.expect_value(t, views.changes_send_bar_height(&view, 2), f32(80))
	with := views.changes_geometry({0, 0, 900, 600}, 1, &view, &f.text)
	testing.expect_value(t, with.send_bar, render.Rect{0, 560, 900, 40})
	testing.expect_value(t, with.diff.height, without.diff.height - 40)
}

@(test)
changes_pairs_share_rows_side_by_side :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	lay_out(&f, &view, &state)
	pairs := &state.rows.pairs
	testing.expect(t, pairs.side_by_side)
	// Context fills both cells; the replace run shares rows and pads the shorter side; lone runs get blank
	// cells; a No_Newline marker stays on the side it follows.
	want := [?]views.Changes_Pair {
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
		testing.expect_value(t, pairs.pairs[3], views.Changes_Pair{3, 3})
		testing.expect_value(t, pairs.pairs[11], views.Changes_Pair{1, 1})
	}
	testing.expect_value(t, rows.tops[1], rows.header + rows.hunk + 10 * rows.line + rows.gap)
}

@(test)
changes_diff_side_by_side_hits_and_rects_per_half :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	inner := g.diff.width - 16

	// The replace row: the removed line in the left cell, the added line in the right one.
	left := views.changes_line_rect(g, &view, &state, 0, 1)
	right := views.changes_line_rect(g, &view, &state, 0, 3)
	testing.expect_value(t, left.y, right.y)
	testing.expect_value(t, left.x, g.diff.x + 8)
	testing.expect(t, left.x + left.width < right.x)
	testing.expect_value(t, right.x + right.width, g.diff.x + 8 + inner)
	at := centre(left)
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{.Line, 0, 1})
	at = centre(right)
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, at.y), views.Changes_Hit{.Line, 0, 3})

	// A context line fills the row, and both halves hit it: the numbers by the cell's left edge, the text
	// further right.
	context_row := views.changes_line_rect(g, &view, &state, 0, 0)
	testing.expect_value(t, context_row.width, inner)
	testing.expect_value(t, context_row.y, left.y - f32(state.rows.line))
	y := context_row.y + 2
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, left.x + 4, y), views.Changes_Hit{.Gutter, 0, 0})
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, right.x + 4, y), views.Changes_Hit{.Gutter, 0, 0})
	testing.expect_value(t, views.changes_diff_hit(g, &view, &state, at.x, y), views.Changes_Hit{.Line, 0, 0})

	// Blank cells: left of the third added line, right of the lone removed line.
	padded := views.changes_line_rect(g, &view, &state, 0, 5)
	testing.expect_value(t, padded.x, right.x)
	blank := views.changes_diff_hit(g, &view, &state, left.x + 4, padded.y + 2)
	testing.expect_value(t, blank, views.Changes_Hit{.Diff, 0, 0})
	lone := views.changes_line_rect(g, &view, &state, 0, 9)
	testing.expect_value(t, lone.x, left.x)
	lone_right := views.changes_diff_hit(g, &view, &state, at.x, lone.y + 2)
	testing.expect_value(t, lone_right, views.Changes_Hit{.Diff, 0, 0})
	lone_left := views.changes_diff_hit(g, &view, &state, left.x + 4, lone.y + 2)
	testing.expect_value(t, lone_left, views.Changes_Hit{.Gutter, 0, 9})

	// The No_Newline markers share the row under the changed line and are not lines to select.
	marker := views.changes_line_rect(g, &view, &state, 1, 1)
	testing.expect_value(t, marker.y, views.changes_line_rect(g, &view, &state, 1, 3).y)
	on_marker := views.changes_diff_hit(g, &view, &state, left.x + 4, marker.y + 2)
	testing.expect_value(t, on_marker, views.Changes_Hit{.Diff, 1, 0})

	// A card goes under the row that holds the comment's last line, from the left cell's code column across
	// both halves.
	f.comments[0] = {file = 0, first = 3, last = 3, text = "Why?"}
	view.comments = f.comments[:1]
	g = lay_out(&f, &view, &state)
	slot := f32(state.rows.cards[0] + 14)
	below := views.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, below.y, left.y + f32(state.rows.line) + slot)
	testing.expect_value(t, views.changes_line_rect(g, &view, &state, 0, 1).y, left.y)
	card_y := left.y + f32(state.rows.line) + 6 + 2
	card_rect, _ := views.changes_card_rect(g, &view, &state, 0)
	card_left := views.changes_diff_hit(g, &view, &state, card_rect.x + 20, card_y)
	testing.expect_value(t, card_left, views.Changes_Hit{.Comment_Card, 0, 0})
	testing.expect(t, card_rect.x > left.x && card_rect.x < at.x)
	card_right := views.changes_diff_hit(g, &view, &state, at.x, card_y)
	testing.expect_value(t, card_right, views.Changes_Hit{.Comment_Card, 0, 0})
}

@(test)
changes_diff_file_top_scrolls_to_a_file_in_both_layouts :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	tops: [2]int
	for side, i in ([2]bool{false, true}) {
		view.side_by_side = side
		lay_out(&f, &view, &state)
		tops[i] = state.rows.tops[1]
		testing.expect_value(t, views.changes_diff_file_top(&state, &view, 1), tops[i])
		testing.expect_value(t, views.changes_diff_file_top(&state, &view, 0), 0)
		state.diff_scroll = tops[i]
		testing.expect_value(t, views.changes_top_file(&state, &view), 1)
		state.diff_scroll = tops[i] - 1
		testing.expect_value(t, views.changes_top_file(&state, &view), 0)
		// No such file keeps the scroll.
		testing.expect_value(t, views.changes_diff_file_top(&state, &view, 5), tops[i] - 1)
		state.diff_scroll = 0
	}
	// Side by side, the replace run takes fewer rows, so the second file starts higher.
	testing.expect(t, tops[1] < tops[0])
	view.notice = .No_Changes
	view.revision += 1
	lay_out(&f, &view, &state)
	testing.expect_value(t, views.changes_top_file(&state, &view), -1)
}

@(test)
changes_side_by_side_cards_sit_under_the_lowest_selected_row :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	// Lines 0-3 are the context line, both removed lines and the first added one. The last of them, the
	// added line, is in row 1, but the second removed line is in row 2 below it, which a new note goes under.
	view.selection = {file = 0, first = 0, last = 3, active = true}
	g := lay_out(&f, &view, &state)
	removed := views.changes_line_rect(g, &view, &state, 0, 2)
	testing.expect_value(t, state.rows.pairs.selection_row, 2)
	padded := views.changes_line_rect(g, &view, &state, 0, 5).y

	// A comment on those lines sits under row 2: row 3 moves down, row 2 stays.
	f.comments[0] = {file = 0, first = 0, last = 3, text = "Why?"}
	view.comments = f.comments[:1]
	view.selection = {}
	g = lay_out(&f, &view, &state)
	slot := f32(state.rows.cards[0] + 14)
	testing.expect_value(t, views.changes_line_rect(g, &view, &state, 0, 2).y, removed.y)
	testing.expect_value(t, views.changes_line_rect(g, &view, &state, 0, 5).y, padded + slot)
	card_rect, _ := views.changes_card_rect(g, &view, &state, 0)
	card := views.changes_diff_hit(g, &view, &state, card_rect.x + 20, removed.y + f32(state.rows.line) + 6 + 2)
	testing.expect_value(t, card, views.Changes_Hit{.Comment_Card, 0, 0})

	// Lines 3 and 4 are in rows 1 and 2, and the lower one is where a new note goes.
	view.selection = {file = 0, first = 3, last = 4, active = true}
	g = lay_out(&f, &view, &state)
	testing.expect_value(t, state.rows.pairs.selection_row, 2)
}

@(test)
changes_pairs_rebuild_only_for_a_new_diff_or_layout :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	lay_out(&f, &view, &state)
	pairs := &state.rows.pairs
	if !testing.expect(t, len(pairs.pairs) > 0) {return}
	marked := views.Changes_Pair{42, 42}

	// A comment or a new width lays the stream out again but keeps the table.
	pairs.pairs[0] = marked
	f.comments[0] = {file = 0, first = 0, last = 0, text = "x"}
	view.comments = f.comments[:1]
	lay_out(&f, &view, &state)
	testing.expect_value(t, pairs.pairs[0], marked)
	views.changes_layout(&state, &view, &f.text, &f.mono, 500, 1)
	testing.expect_value(t, pairs.pairs[0], marked)

	// A new revision or the other layout rebuilds it.
	view.revision += 1
	lay_out(&f, &view, &state)
	testing.expect_value(t, pairs.pairs[0], views.Changes_Pair{0, 0})
	pairs.pairs[0] = marked
	view.side_by_side = false
	lay_out(&f, &view, &state)
	testing.expect_value(t, pairs.pairs[0], views.Changes_Pair{0, 0})
}

@(test)
changes_sticky_header_pins_until_the_next_header_pushes_it_up :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	side_by_side_use(&f, &view)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)

	for side in ([2]bool{false, true}) {
		view.side_by_side = side
		g := lay_out(&f, &view, &state)
		rows := &state.rows
		header := f32(rows.header)

		// At the top of the stream every header is in its place.
		state.diff_scroll = 0
		file, rect := views.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, -1)

		// Scrolled into the first file, its header pins to the top of the diff and takes the hits there.
		state.diff_scroll = 40
		file, rect = views.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 0)
		testing.expect_value(t, rect, render.Rect{g.diff.x, g.diff.y, g.diff.width, header})
		at := centre(rect)
		pinned := views.changes_diff_hit(g, &view, &state, at.x, at.y)
		testing.expect_value(t, pinned, views.Changes_Hit{.Sticky_Header, 0, 0})
		below := views.changes_diff_hit(g, &view, &state, at.x, rect.y + header + 1)
		testing.expect(t, below.part != .Sticky_Header)

		// The end of the file's body pushes it up as the next header arrives.
		end := rows.tops[1] - rows.gap
		state.diff_scroll = rows.tops[1] - 10
		file, rect = views.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 0)
		testing.expect_value(t, rect.y, g.diff.y + 10 - f32(rows.gap) - header)
		// One pixel of it is left at the body's last row; its border falls in the gap, above the next header.
		state.diff_scroll = end - 1
		file, rect = views.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 0)
		testing.expect_value(t, rect.y + rect.height, g.diff.y + 1)
		next_header := g.diff.y + f32(rows.tops[1] - state.diff_scroll)
		testing.expect(t, rect.y + rect.height + 1 <= next_header)
		// Once only the gap after the body is left, nothing sticks; then the second file's header does.
		state.diff_scroll = rows.tops[1] - rows.gap / 2
		file, _ = views.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, -1)
		state.diff_scroll = rows.tops[1] + 5
		file, rect = views.changes_sticky_header(&state, &view, g)
		testing.expect_value(t, file, 1)
		testing.expect_value(t, rect.y, g.diff.y)
	}

	// A collapsed file has no body to stick over.
	collapsed := [2]bool{true, false}
	view.collapsed = collapsed[:]
	g := lay_out(&f, &view, &state)
	state.diff_scroll = 5
	file, _ := views.changes_sticky_header(&state, &view, g)
	testing.expect_value(t, file, -1)
	in_place := views.changes_diff_hit(g, &view, &state, g.diff.x + 50, g.diff.y + 2)
	testing.expect_value(t, in_place, views.Changes_Hit{.File_Header, 0, 0})
}

// A layer draws its rects before its text, so the pinned header must sit in a later layer than the stream
// or the lines under it show through its fill.
@(test)
changes_sticky_header_draws_in_a_layer_above_the_stream :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	side_by_side_use(&f, &view)
	view.side_by_side = false
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	// A short pane, so the draw keeps the scroll inside the first file.
	g := views.changes_geometry({0, 0, 900, 150}, 1, &view, &f.text)
	views.changes_layout(&state, &view, &f.text, &f.mono, g.diff.width, 1)
	state.diff_scroll = 40
	sticky, rect := views.changes_sticky_header(&state, &view, g)
	if !testing.expect_value(t, sticky, 0) {return}

	theme: views.Theme
	theme.text = {1, 1, 1, 1}
	theme.pane = {0.1, 0.2, 0.3, 1}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, render.push_layer(&list, g.area), render.Error.None)
	status, _ := views.changes_draw(&list, &f.text, &f.mono, &theme, g, &view, &state, 1, {-1, -1}, 0)
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
	view: views.Changes_View
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
	theme: views.Theme
	theme.pane = hex(0x222436)
	theme.diff_added = hex(0xc3e88d, 0x24)
	theme.text = hex(0xc8d3f5)
	theme.palette[8] = hex(0x444a73)
	theme.palette[2] = hex(0xc3e88d)
	a := theme.diff_added.a
	added := theme.diff_added * a + theme.pane * (1 - a)
	added.a = 1
	testing.expect(t, colour.contrast_ratio(theme.palette[8], added) < 1.5)

	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	draw :: proc(
		t: ^testing.T,
		list: ^render.Draw_List,
		f: ^Diff_Fixture,
		theme: ^views.Theme,
		g: views.Changes_Geometry,
		view: ^views.Changes_View,
		state: ^views.Changes_State,
	) {
		render.draw_list_reset(list)
		testing.expect_value(t, render.push_layer(list, g.area), render.Error.None)
		status, _ := views.changes_draw(list, &f.text, &f.mono, theme, g, view, state, 1, {-1, -1}, 0)
		testing.expect_value(t, status, render.Build_Status.Ok)
	}
	added_row := views.changes_line_rect(g, &view, &state, 0, 2)
	context_row := views.changes_line_rect(g, &view, &state, 0, 0)

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

@(test)
changes_diff_aligns_replacements_and_tints_only_edited_tokens :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)
	patch := `diff --git a/sample.odin b/sample.odin
@@ -1,2 +1,3 @@
-set_theme(blue, 15)
-render_title("left")
+enable_logging()
+set_theme(green, 82)
+render_title("right")
`
	d, ok := turns.diff_parse(patch)
	if !testing.expect(t, ok) {return}
	defer turns.diff_destroy(&d)
	turns.diff_refine(&d)
	view.files = d.files
	theme := views.Theme {
		pane = hex(0x222436), text = hex(0xc8d3f5), diff_added = hex(0xc3e88d, 0x24),
		diff_removed = hex(0xff757f, 0x24),
	}
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	layouts := [?]bool{false, true}
	for side_by_side in layouts {
		view.side_by_side = side_by_side
		g := lay_out(&f, &view, &state)
		old := views.changes_line_rect(g, &view, &state, 0, 0)
		inserted := views.changes_line_rect(g, &view, &state, 0, 2)
		row, column, found := views.changes_line_code(g, &view, &state, &f.mono, 0, 3)
		if !testing.expect(t, found) {return}
		if side_by_side {
			testing.expect_value(t, row.y, old.y)
			testing.expect(t, row.x > old.x && inserted.y < row.y)
		} else {
			testing.expect(t, old.y < inserted.y && inserted.y < row.y)
		}

		render.draw_list_reset(&list)
		testing.expect_value(t, render.push_layer(&list, g.area), render.Error.None)
		status, _ := views.changes_draw(&list, &f.text, &f.mono, &theme, g, &view, &state, 1, {-1, -1}, 0)
		testing.expect_value(t, status, render.Build_Status.Ok)
		starts := [?]string{"set_theme(", "set_theme(green, "}
		words := [?]string{"green", "82"}
		seen := 0
		for item in list.rects {
			c := item.color
			if c.r != theme.diff_added.r || c.g != theme.diff_added.g || c.b != theme.diff_added.b ||
			   c.a <= theme.diff_added.a {continue}
			testing.expect(t, item.rect.y != inserted.y, "an inserted line should get only the row tint")
			if item.rect.y != row.y {continue}
			if !testing.expect(t, seen < len(words)) {return}
			x := column.text_x + ui.text_width(&f.mono, starts[seen])
			testing.expect(t, abs(item.rect.x - x) < 0.05)
			testing.expect(t, abs(item.rect.width - ui.text_width(&f.mono, words[seen])) < 0.05)
			seen += 1
		}
		testing.expect_value(t, seen, len(words))
	}
}

// The offset and x mappings follow what paint_text draws: a tab is four spaces from the pen, a rune with no
// glyph takes no room, and only the runes that start inside the room count.
@(test)
changes_code_offsets_follow_the_painters_rules :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	_, found := font.glyph_lookup(f.fonts, f.mono.family, .Regular, '\x01')
	if !testing.expect(t, !found) {return}
	advance := ui.text_width(&f.mono, "a")
	after := ui.text_width(&f.mono, "b")
	space := ui.text_width(&f.mono, " ")
	tab := 4 * space
	room := f32(1000)
	text := "a\t\x01b"

	testing.expect_value(t, views.code_x_of(&f.mono, text, room, 0), 0)
	testing.expect_value(t, views.code_x_of(&f.mono, text, room, 1), advance)
	testing.expect_value(t, views.code_x_of(&f.mono, text, room, 2), advance + tab)
	testing.expect_value(t, views.code_x_of(&f.mono, text, room, 3), advance + tab)
	testing.expect_value(t, views.code_x_of(&f.mono, text, room, 4), advance + tab + after)

	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, -5), 0)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance * 0.4), 0)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance * 0.6), 1)
	// Either half of the tab snaps to the boundary on its side.
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance + space), 1)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance + 3 * space), 2)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance + tab + 1), 3)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, 10000), 4)

	// Offsets map to x and back. The rune without a glyph shares its x with the "b" after it, so that x
	// reads as the later offset.
	for offset in ([?]int{0, 1, 3, 4}) {
		x := views.code_x_of(&f.mono, text, room, offset)
		testing.expect_value(t, views.code_offset_at(&f.mono, text, room, x), offset)
	}
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance + tab), 3)

	// The room ends the visible text: the tab starts inside it, the "b" after it does not, and a boundary
	// beyond it is at the room's edge.
	narrow := advance + space
	testing.expect_value(t, views.code_offset_at(&f.mono, text, narrow, 10000), 2)
	testing.expect_value(t, views.code_x_of(&f.mono, text, narrow, 4), narrow)

	// Scrolled, the text starts at the first rune the scroll reaches: the tab, past "a".
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, 0, advance), 1)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, -20, advance), 1)
	testing.expect(t, abs(views.code_x_of(&f.mono, text, room, 4, advance) - (tab + after)) < 0.01)
	testing.expect_value(t, views.code_x_of(&f.mono, text, room, 0, advance), 0)
}

@(test)
a_press_never_lands_between_a_letter_and_its_combining_mark :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	// "é" as an e (byte 0) and U+0301 (bytes 1-2), then "x" at byte 3.
	text := "e\u0301x"
	advance := ui.text_width(&f.mono, "e")
	room := f32(1000)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance * 0.4), 0)
	// The right half of the letter is the boundary after its mark, not the one between them.
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance * 0.6), 3)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, advance + 0.1), 3)
	testing.expect_value(t, views.code_offset_at(&f.mono, text, room, 10000), len(text))
	// A multi-byte letter is one boundary too, so the offsets stay on rune starts.
	wide := "éx"
	testing.expect_value(t, views.code_offset_at(&f.mono, wide, room, ui.text_width(&f.mono, "é") * 0.6), 2)
}

// The code column is one geometry for both layouts: two number columns in a unified row, one in a cell,
// the sign after them and the text out to the cell's edge.
@(test)
changes_line_code_places_numbers_sign_and_text :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	g := lay_out(&f, &view, &state)
	digit := ui.text_width(&f.mono, "0")

	row := views.changes_line_rect(g, &view, &state, 0, 2)
	cell, column, ok := views.changes_line_code(g, &view, &state, &f.mono, 0, 2)
	if !testing.expect(t, ok) {return}
	testing.expect_value(t, cell, row)
	testing.expect_value(t, column.old_x, row.x + 8)
	testing.expect_value(t, column.new_x, column.old_x + digit + 8)
	testing.expect_value(t, column.sign_x, column.new_x + digit + 8)
	testing.expect_value(t, column.text_x, column.sign_x + digit + 4)
	testing.expect_value(t, column.text_x + column.width, row.x + row.width)
	testing.expect_value(t, views.code_column(row, digit, digit, 1, true), column)

	// Side by side a cell has one number column, and each half of the row has its own column.
	side_by_side_use(&f, &view)
	g = lay_out(&f, &view, &state)
	_, left, left_ok := views.changes_line_code(g, &view, &state, &f.mono, 0, 1)
	right_cell, right, right_ok := views.changes_line_code(g, &view, &state, &f.mono, 0, 3)
	if !testing.expect(t, left_ok && right_ok) {return}
	testing.expect_value(t, left.new_x, left.old_x)
	testing.expect_value(t, right.new_x, right.old_x)
	testing.expect_value(t, right.old_x, right_cell.x + 8)
	testing.expect_value(t, right.sign_x, right.old_x + digit + 8)
	testing.expect(t, right.old_x > left.text_x + left.width)
	testing.expect_value(t, right.text_x + right.width, right_cell.x + right_cell.width)

	// A line that is not in the diff has no column.
	_, _, missing := views.changes_line_code(g, &view, &state, &f.mono, 0, 99)
	testing.expect(t, !missing)
}

// A run tints and marks part of a line and takes the selected inks; text outside it keeps the line's.
@(test)
changes_code_runs_mark_part_of_a_line :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 13)) {return}
	f.mono = ui.text_mono(&f.text, f.text.family)

	plain, selected: [views.CHANGES_INKS]render.Color
	plain[views.CHANGES_INK_TEXT] = {1, 0, 0, 1}
	selected[views.CHANGES_INK_TEXT] = {0, 1, 0, 1}
	tint := render.Color{0, 0, 1, 0.5}
	line := views.Code_Line {
		text          = "abc",
		runs          = []views.Code_Run{{start = 1, end = 2, tint = tint, underline = {1, 1, 0, 1}, strike = {1, 0, 1, 1},
			selected = true}},
		x             = 100,
		width         = 500,
		top           = 20,
		height        = 16,
		baseline      = 32,
		scale         = 1,
		inks          = &plain,
		selected_inks = &selected,
		plain         = views.CHANGES_INK_TEXT,
	}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, render.push_layer(&list, {0, 0, 800, 600}), render.Error.None)
	testing.expect_value(t, views.code_line_draw(&list, &f.mono, line), render.Build_Status.Ok)

	if !testing.expect_value(t, len(list.glyphs), 3) {return}
	testing.expect_value(t, list.glyphs[0].color, plain[views.CHANGES_INK_TEXT])
	testing.expect_value(t, list.glyphs[1].color, selected[views.CHANGES_INK_TEXT])
	testing.expect_value(t, list.glyphs[2].color, plain[views.CHANGES_INK_TEXT])

	// The run spans exactly the second glyph's cell: a tint over the row, a line under it and one through it.
	advance := ui.text_width(&f.mono, "a")
	second := ui.text_width(&f.mono, "b")
	if !testing.expect_value(t, len(list.rects), 3) {return}
	tops := [?]f32{20, 20 + 16 - 2, 20 + 7}
	heights := [?]f32{16, 2, 2}
	for rect, i in list.rects {
		testing.expect_value(t, rect.rect.x, 100 + advance)
		testing.expect_value(t, rect.rect.y, tops[i])
		testing.expect_value(t, rect.rect.height, heights[i])
		testing.expect(t, abs(rect.rect.width - second) < 0.01)
	}
	testing.expect_value(t, list.rects[0].color, tint)

	// A run that reaches the end of the line closes there, and a run past the room is cut at it.
	render.draw_list_reset(&list)
	testing.expect_value(t, render.push_layer(&list, {0, 0, 800, 600}), render.Error.None)
	line.runs = []views.Code_Run{{start = 2, end = 99, tint = tint}}
	line.width = advance + second + 3
	testing.expect_value(t, views.code_line_draw(&list, &f.mono, line), render.Build_Status.Ok)
	if !testing.expect_value(t, len(list.rects), 1) {return}
	testing.expect_value(t, list.rects[0].rect.x, 100 + advance + second)
	testing.expect_value(t, list.rects[0].rect.width, f32(3))
}

// What a note looks like depends on its kind, its label and the text it covers, so each of them is part of
// the rows' cache key: a change to one lays the stream out again.
@(test)
changes_rows_refresh_when_a_note_changes_kind_label_or_range :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	f.comments[0] = {file = 0, first = 0, last = 1, text = "Rename this"}
	view.comments = f.comments[:1]
	_ = lay_out(&f, &view, &state)
	key := state.rows.comments_key

	changed :: proc(f: ^Diff_Fixture, view: ^views.Changes_View, state: ^views.Changes_State, key: ^u64) -> bool {
		_ = lay_out(f, view, state)
		different := state.rows.comments_key != key^
		key^ = state.rows.comments_key
		return different
	}
	f.comments[0].kind = .Label
	testing.expect(t, changed(&f, &view, &state, &key), "kind")
	f.comments[0].label_name = "Verify this"
	testing.expect(t, changed(&f, &view, &state, &key), "label name")
	f.comments[0].label_colour = "#ff8800"
	testing.expect(t, changed(&f, &view, &state, &key), "label colour")
	f.comments[0].partial = true
	testing.expect(t, changed(&f, &view, &state, &key), "partial")
	f.comments[0].first_offset = 1
	testing.expect(t, changed(&f, &view, &state, &key), "first offset")
	f.comments[0].last_offset = 2
	testing.expect(t, changed(&f, &view, &state, &key), "last offset")
	testing.expect(t, !changed(&f, &view, &state, &key), "nothing changed")

	view.selection = {file = 0, first = 2, last = 2, active = true}
	testing.expect(t, changed(&f, &view, &state, &key), "selection")
	// Where in its line a text selection ends moves nothing in the layout.
	view.selection.partial, view.selection.last_offset = true, 1
	testing.expect(t, !changed(&f, &view, &state, &key), "selection text")
}

@(test)
a_text_drag_step_and_a_keystroke_leave_the_rows_as_they_are :: proc(t: ^testing.T) {
	f: Diff_Fixture
	view: views.Changes_View
	if !diff_fixture_make(t, &f, &view) {return}
	defer diff_fixture_destroy(&f)
	state: views.Changes_State
	defer views.changes_state_destroy(&state)
	f.comments[0] = {file = 0, first = 0, last = 1, text = "Rename this"}
	view.comments = f.comments[:1]
	view.selection = {file = 0, first = 2, last = 2, active = true, partial = true}
	_ = lay_out(&f, &view, &state)
	built := state.rows.built

	// Each step of a text drag moves the end of the selection within its line, and every hover lays the
	// diff out: none of them builds the rows again.
	for offset in 1 ..= 8 {
		view.selection.last_offset = offset
		_ = lay_out(&f, &view, &state)
	}
	testing.expect_value(t, state.rows.built, built)

	// Typing into the editor on that selection builds them only when the card changes height.
	view.editing = 1
	testing.expect(t, textedit.reset(&f.buffer, "a"))
	_ = lay_out(&f, &view, &state)
	built = state.rows.built
	for text in ([?]string{"ab", "abc", "abcd", "abcde"}) {
		testing.expect(t, textedit.reset(&f.buffer, text))
		_ = lay_out(&f, &view, &state)
	}
	testing.expect_value(t, state.rows.built, built)
	testing.expect(t, textedit.reset(&f.buffer, "one\ntwo\nthree\nfour\nfive\nsix"))
	_ = lay_out(&f, &view, &state)
	testing.expect_value(t, state.rows.built, built + 1)
}

@(test)
a_cell_holds_only_its_own_sides_lines :: proc(t: ^testing.T) {
	testing.expect(t, !views.changes_half_has(.Left, .Added))
	testing.expect(t, views.changes_half_has(.Left, .Removed))
	testing.expect(t, views.changes_half_has(.Left, .Context))
	testing.expect(t, !views.changes_half_has(.Right, .Removed))
	testing.expect(t, views.changes_half_has(.Right, .Added))
	testing.expect(t, views.changes_half_has(.Both, .Added))
}
