package ui_test

import "aio:font"
import "aio:glyphs"
import "aio:render"
import "aio:ui"
import "core:testing"

@(private = "file")
Note_Fixture :: struct {
	fonts:      ^font.System,
	cache:      glyphs.Cache,
	text, mono: ui.Text,
	device:     ^render.Device,
}

@(private = "file")
note_fixture_make :: proc(t: ^testing.T, f: ^Note_Fixture) -> bool {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return false}
	f.device = device
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {
		render.device_destroy(device)
		return false
	}
	glyphs.init(&f.cache, f.fonts, device)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &f.cache, 13)) {
		glyphs.destroy(&f.cache)
		font.system_destroy(f.fonts)
		render.device_destroy(device)
		return false
	}
	f.mono = ui.text_mono(&f.text, f.text.family)
	return true
}

@(private = "file")
note_fixture_destroy :: proc(f: ^Note_Fixture) {
	glyphs.destroy(&f.cache)
	font.system_destroy(f.fonts)
	render.device_destroy(f.device)
}

@(test)
note_blocks_split_paragraphs_fences_and_suggestions :: proc(t: ^testing.T) {
	blocks :: proc(source: string) -> (found: [8]ui.Note_Block, count: int) {
		scan := ui.Note_Scan {
			rest = source,
		}
		for block in ui.note_block_next(&scan) {
			if count == len(found) {break}
			found[count] = block
			count += 1
		}
		return
	}

	// Text around fences stays as written, and a fence's body loses only the line break before its close.
	found, count := blocks("Intro\n```odin\nx := 1\n```\nMid\n```suggestion\ny := 2\nz := 3\n```\nEnd")
	if !testing.expect_value(t, count, 5) {return}
	testing.expect_value(t, found[0], ui.Note_Block{.Paragraph, "Intro\n", ""})
	testing.expect_value(t, found[1], ui.Note_Block{.Code, "x := 1", "odin"})
	testing.expect_value(t, found[2], ui.Note_Block{.Paragraph, "\nMid\n", ""})
	testing.expect_value(t, found[3], ui.Note_Block{.Suggestion, "y := 2\nz := 3", "suggestion"})
	testing.expect_value(t, found[4], ui.Note_Block{.Paragraph, "\nEnd", ""})

	// The rest of the opening line is dropped, a fence at the very start has nothing before it, and an
	// empty block is one with no lines.
	found, count = blocks("```ts note\nlet a\n```")
	if !testing.expect_value(t, count, 1) {return}
	testing.expect_value(t, found[0], ui.Note_Block{.Code, "let a", "ts"})
	found, count = blocks("```suggestion\n```")
	if !testing.expect_value(t, count, 1) {return}
	testing.expect_value(t, found[0], ui.Note_Block{.Suggestion, "", "suggestion"})

	// A fence that never closes, or never ends its opening line, is text.
	found, count = blocks("Open ```odin\nx := 1")
	if !testing.expect_value(t, count, 1) {return}
	testing.expect_value(t, found[0], ui.Note_Block{.Paragraph, "Open ```odin\nx := 1", ""})
	found, count = blocks("Just ``` here")
	if !testing.expect_value(t, count, 1) {return}
	testing.expect_value(t, found[0].kind, ui.Note_Block_Kind.Paragraph)
	_, count = blocks("")
	testing.expect_value(t, count, 0)
}

@(test)
note_paragraphs_wrap_by_the_width_and_keep_their_styles :: proc(t: ^testing.T) {
	f: Note_Fixture
	if !note_fixture_make(t, &f) {return}
	defer note_fixture_destroy(&f)
	body := ui.text_styled(&f.text, .Body)
	line := body.line_height
	chip := f32(4)

	// One line at a roomy width; the height is the line count times the line height.
	one := ui.note_body_layout(&f.text, &f.mono, "Rename it first.", nil, 400, 1)
	testing.expect_value(t, len(one.rows), 1)
	testing.expect_value(t, one.height, line)
	testing.expect_value(t, one.rows[0].kind, ui.Note_Row_Kind.Text)

	// The same words in a narrow width take more rows, each a line high and none wider than the width.
	narrow := ui.note_body_layout(&f.text, &f.mono, "Rename it first, then run the whole suite again.", nil, 90, 1)
	testing.expect(t, len(narrow.rows) > 2)
	testing.expect_value(t, narrow.height, f32(len(narrow.rows)) * line)
	for row, i in narrow.rows {
		testing.expect_value(t, row.y, f32(i) * line)
		for piece in narrow.pieces[row.first:][:row.count] {testing.expect(t, piece.x + piece.width <= 90.01)}
	}

	// A line break starts a row, and a blank line is a row of its own.
	lines := ui.note_body_layout(&f.text, &f.mono, "a\n\nb", nil, 400, 1)
	testing.expect_value(t, len(lines.rows), 3)
	testing.expect_value(t, lines.rows[1].count, 0)
	// Leading and trailing line breaks of a paragraph do not show.
	trimmed := ui.note_body_layout(&f.text, &f.mono, "\n\nab\n", nil, 400, 1)
	testing.expect_value(t, len(trimmed.rows), 1)

	// Bold words and a code span are their own pieces; the span is one piece, padded for its chip.
	styled := ui.note_body_layout(&f.text, &f.mono, "a **b c** `d e` f", nil, 400, 1)
	if !testing.expect_value(t, len(styled.pieces), 5) {return}
	styles := [?]ui.Note_Style{.Plain, .Bold, .Bold, .Code, .Plain}
	texts := [?]string{"a", "b", "c", "d e", "f"}
	for piece, i in styled.pieces {
		testing.expect_value(t, piece.style, styles[i])
		testing.expect_value(t, piece.text, texts[i])
		if i > 0 {testing.expect(t, piece.x > styled.pieces[i - 1].x)}
	}
	testing.expect_value(t, styled.pieces[3].width, ui.text_width(&f.mono, "d e") + 2 * chip)
	// Markers with no partner are text.
	plain := ui.note_body_layout(&f.text, &f.mono, "a ` b ** c", nil, 400, 1)
	for piece in plain.pieces {testing.expect_value(t, piece.style, ui.Note_Style.Plain)}
	// Code inside bold is a chip too, not backticks drawn in bold.
	inside := ui.note_body_layout(&f.text, &f.mono, "**use `x` now**", nil, 400, 1)
	if !testing.expect_value(t, len(inside.pieces), 3) {return}
	styles_inside := [?]ui.Note_Style{.Bold, .Code, .Bold}
	texts_inside := [?]string{"use", "x", "now"}
	for piece, i in inside.pieces {
		testing.expect_value(t, piece.style, styles_inside[i])
		testing.expect_value(t, piece.text, texts_inside[i])
	}

	// A word wider than the room is cut where it runs out, so no piece passes the edge.
	long := ui.note_body_layout(&f.text, &f.mono, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", nil, 60, 1)
	testing.expect(t, len(long.rows) > 2)
	for piece in long.pieces {testing.expect(t, piece.x + piece.width <= 60.01)}
}

@(test)
note_code_blocks_and_suggestions_lay_out_their_rows :: proc(t: ^testing.T) {
	f: Note_Fixture
	if !note_fixture_make(t, &f) {return}
	defer note_fixture_destroy(&f)
	body := ui.text_styled(&f.text, .Body)
	row := f32(int(f.mono.line_height) + 2)
	pad, gap, head := f32(4), f32(4), f32(24)

	// A paragraph, a gap, then a code block: padding, a row per line, padding.
	code := ui.note_body_layout(&f.text, &f.mono, "Try:\n```odin\na := 1\n\tb := 2\n```", nil, 400, 1)
	if !testing.expect_value(t, len(code.rows), 3) || !testing.expect_value(t, len(code.frames), 1) {return}
	testing.expect_value(t, code.rows[1].kind, ui.Note_Row_Kind.Code)
	testing.expect_value(t, code.rows[1].y, body.line_height + gap + pad)
	testing.expect_value(t, code.rows[1].text, "a := 1")
	testing.expect_value(t, code.rows[2].text, "\tb := 2")
	testing.expect_value(t, code.rows[2].line, 1)
	testing.expect_value(t, code.frames[0].y, body.line_height + gap)
	testing.expect_value(t, code.frames[0].height, pad + 2 * row + pad)
	testing.expect_value(t, code.height, body.line_height + gap + pad + 2 * row + pad)

	// A suggestion is a heading, the replaced lines as removed rows, then its own as added ones.
	original := []string{"old one", "old two"}
	suggestion := ui.note_body_layout(
		&f.text, &f.mono, "```suggestion\nnew one\nnew two\nnew three\n```", original, 400, 1,
	)
	if !testing.expect_value(t, len(suggestion.rows), 6) {return}
	kinds := [?]ui.Note_Row_Kind{.Header, .Removed, .Removed, .Added, .Added, .Added}
	texts := [?]string{"", "old one", "old two", "new one", "new two", "new three"}
	for r, i in suggestion.rows {
		testing.expect_value(t, r.kind, kinds[i])
		testing.expect_value(t, r.text, texts[i])
		testing.expect_value(t, r.frame, 0)
	}
	testing.expect_value(t, suggestion.rows[1].y, head)
	testing.expect_value(t, suggestion.rows[3].y, head + 2 * row)
	testing.expect_value(t, suggestion.rows[3].line, 0)
	testing.expect_value(t, suggestion.rows[5].line, 2)
	testing.expect_value(t, suggestion.height, head + 5 * row + pad)
	testing.expect_value(t, suggestion.frames[0].kind, ui.Note_Block_Kind.Suggestion)

	// Nothing replaced shows only the new lines under the heading; text with no blocks has no frames.
	only_new := ui.note_body_layout(&f.text, &f.mono, "```suggestion\nx\n```", nil, 400, 1)
	testing.expect_value(t, len(only_new.rows), 2)
	none := ui.note_body_layout(&f.text, &f.mono, "just words", nil, 400, 1)
	testing.expect_value(t, len(none.frames), 0)
	empty := ui.note_body_layout(&f.text, &f.mono, "", nil, 400, 1)
	testing.expect_value(t, empty.height, 0)
}

@(test)
note_body_draws_chips_fills_signs_and_syntax_colours :: proc(t: ^testing.T) {
	f: Note_Fixture
	if !note_fixture_make(t, &f) {return}
	defer note_fixture_destroy(&f)
	theme: ui.Theme
	theme.text = {1, 1, 1, 1}
	theme.code_background = {0.1, 0.2, 0.3, 1}
	theme.diff_added = {0, 0.5, 0, 0.25}
	theme.diff_removed = {0.5, 0, 0, 0.25}
	theme.border = {0.4, 0.4, 0.4, 1}
	theme.muted = {0.7, 0.7, 0.7, 1}
	inks: ui.Changes_Inks
	plain := render.Color{0.9, 0.1, 0.1, 1}
	removed_plain := render.Color{0.1, 0.9, 0.1, 1}
	added_plain := render.Color{0.1, 0.1, 0.9, 1}
	removed_sign := render.Color{0.9, 0.9, 0.1, 1}
	added_sign := render.Color{0.1, 0.9, 0.9, 1}
	for background in ui.Changes_Background {
		for i in 0 ..< ui.CHANGES_INKS {inks.table[background][i] = {0.5, 0.5, 0.5, 1}}
	}
	inks.table[.Context][ui.CHANGES_INK_TEXT] = plain
	inks.table[.Removed][ui.CHANGES_INK_TEXT] = removed_plain
	inks.table[.Added][ui.CHANGES_INK_TEXT] = added_plain
	inks.table[.Removed][ui.CHANGES_INK_REMOVED_SIGN] = removed_sign
	inks.table[.Added][ui.CHANGES_INK_ADDED_SIGN] = added_sign

	source := "Use `old` here:\n```suggestion\nnew\n```\nand\n```text\nraw\n```"
	original := []string{"old"}
	layout := ui.note_body_layout(&f.text, &f.mono, source, original, 300, 1)
	ui.note_body_highlight(&layout, .None)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	testing.expect_value(t, render.push_layer(&list, {0, 0, 800, 600}), render.Error.None)
	status := ui.note_body_draw(&list, &f.text, &f.mono, theme, &inks, &layout, {20, 10}, 1, 0, 600)
	testing.expect_value(t, status, render.Build_Status.Ok)

	count :: proc(list: ^render.Draw_List, color: render.Color) -> (n: int) {
		for rect in list.rects {if rect.color == color {n += 1}}
		return
	}
	// The inline code chip and the two frames share the code fill, each frame with an outline.
	testing.expect_value(t, count(&list, theme.code_background), 3)
	testing.expect_value(t, count(&list, theme.border), 2)
	// One removed row and one added row carry the diff's fills, full width of the body.
	for rect in list.rects {
		if rect.color == theme.diff_added || rect.color == theme.diff_removed {
			testing.expect_value(t, rect.rect.x, f32(20))
			testing.expect_value(t, rect.rect.width, f32(300))
		}
	}
	testing.expect_value(t, count(&list, theme.diff_added), 1)
	testing.expect_value(t, count(&list, theme.diff_removed), 1)
	// Signs and code take the inks of the row they are on: "-old", "+new" and the plain "raw".
	glyph_count :: proc(list: ^render.Draw_List, color: render.Color) -> (n: int) {
		for glyph in list.glyphs {if glyph.color == color {n += 1}}
		return
	}
	testing.expect_value(t, glyph_count(&list, removed_sign), 1)
	testing.expect_value(t, glyph_count(&list, added_sign), 1)
	testing.expect_value(t, glyph_count(&list, removed_plain), 3)
	testing.expect_value(t, glyph_count(&list, added_plain), 3)
	testing.expect_value(t, glyph_count(&list, plain), 3)

	// Rows outside the visible range are not drawn.
	render.draw_list_reset(&list)
	testing.expect_value(t, render.push_layer(&list, {0, 0, 800, 600}), render.Error.None)
	status = ui.note_body_draw(&list, &f.text, &f.mono, theme, &inks, &layout, {20, 10}, 1, 1000, 1200)
	testing.expect_value(t, status, render.Build_Status.Ok)
	testing.expect_value(t, len(list.rects), 0)
	testing.expect_value(t, len(list.glyphs), 0)
}
