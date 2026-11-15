package ui_test

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
	testing.expect_value(t, ui.changes_diff_hit(g, &view, &state, at.x, at.y), ui.Changes_Hit{.Comment_Button, 0, 2})

	// The send bar's buttons.
	send, copy, discard := ui.changes_send_rects(g, &view)
	rects := [?]render.Rect{send, copy, discard}
	parts := [?]ui.Changes_Part{.Send, .Copy, .Discard}
	for rect, i in rects {
		p := centre(rect)
		testing.expect_value(t, ui.changes_diff_hit(g, &view, &state, p.x, p.y), ui.Changes_Hit{parts[i], 0, 0})
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
