package ui_test

import "cosmos:caret"
import "cosmos:font"
import "cosmos:glyphs"
import "aio:markdown"
import "cosmos:render"
import "aio:ui"
import "core:testing"
import "core:time"

@(private = "file")
Area_Fixture :: struct {
	fonts:  ^font.System,
	text:   ui.Text,
	buffer: markdown.Edit_Buffer,
	area:   ui.Text_Area,
}

@(private = "file")
area_start :: proc(t: ^testing.T, f: ^Area_Fixture, source: string, cache: ^glyphs.Cache = nil) -> bool {
	err: font.Error
	f.fonts, err = font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, cache, 16)) {return false}
	return testing.expect(t, markdown.edit_buffer_init(&f.buffer, source))
}

@(private = "file")
area_stop :: proc(f: ^Area_Fixture) {
	ui.text_area_destroy(&f.area)
	markdown.edit_buffer_destroy(&f.buffer)
	font.system_destroy(f.fonts)
}

// A box, at a scale of one, whose text is `columns` letters 'a' wide and half a letter over, so a run
// of that many fits a line and one more does not.
@(private = "file")
area_width :: proc(f: ^Area_Fixture, columns: f32) -> f32 {
	return (columns + 0.5) * ui.text_width(&f.text, "a") + 2 * ui.CONTROL_INSET
}

// A box whose text is as wide as `sample` and half a letter more, so that text fits a line and one more
// letter does not.
@(private = "file")
area_width_of :: proc(f: ^Area_Fixture, sample: string) -> f32 {
	return ui.text_width(&f.text, sample) + 0.5 * ui.text_width(&f.text, "a") + 2 * ui.CONTROL_INSET
}

@(private = "file")
area_box :: proc(f: ^Area_Fixture, width: f32, min_lines, max_lines: int) -> ui.Text_Area_Box {
	height := ui.text_area_height(&f.area, &f.buffer, &f.text, width, 1, min_lines, max_lines)
	return {area = &f.area, buffer = &f.buffer, text = &f.text, rect = {10, 20, width, height}, scale = 1}
}

@(private = "file")
line_texts :: proc(f: ^Area_Fixture, width: f32) -> []string {
	lines := ui.text_area_lines(&f.area, &f.buffer, &f.text, width, 1)
	out := make([]string, len(lines), context.temp_allocator)
	source := markdown.edit_string(&f.buffer)
	for line, i in lines {out[i] = source[line.start:line.end]}
	return out
}

@(private = "file")
expect_lines :: proc(t: ^testing.T, got: []string, want: []string, loc := #caller_location) {
	if !testing.expect_value(t, len(got), len(want), loc) {return}
	for line, i in want {testing.expect_value(t, got[i], line, loc)}
}

@(test)
a_long_word_breaks_inside_itself_at_the_box_width :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aaaaaaaaaa") {return}
	defer area_stop(&f)
	expect_lines(t, line_texts(&f, area_width(&f, 4)), {"aaaa", "aaaa", "aa"})
}

@(test)
wrapped_lines_keep_their_trailing_spaces :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aa aa  aa") {return}
	defer area_stop(&f)
	width := area_width_of(&f, "aa aa")
	expect_lines(t, line_texts(&f, width), {"aa aa  ", "aa"})
	// Every byte belongs to exactly one line, and a wrapped line ends where the next begins.
	lines := ui.text_area_lines(&f.area, &f.buffer, &f.text, width, 1)
	testing.expect_value(t, lines[0].start, 0)
	for i in 1 ..< len(lines) {testing.expect_value(t, lines[i].start, lines[i - 1].end)}
	testing.expect_value(t, lines[len(lines) - 1].end, len(f.buffer.text))
}

@(test)
hard_breaks_and_empty_lines_are_kept :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aa\n\naa\n") {return}
	defer area_stop(&f)
	width := area_width(&f, 8)
	expect_lines(t, line_texts(&f, width), {"aa", "", "aa", ""})
	lines := ui.text_area_lines(&f.area, &f.buffer, &f.text, width, 1)
	// A line ended by a break stops before it, and the next starts after it.
	testing.expect_value(t, lines[0], ui.Text_Area_Line{0, 2})
	testing.expect_value(t, lines[1], ui.Text_Area_Line{3, 3})
	testing.expect_value(t, lines[2], ui.Text_Area_Line{4, 6})
	testing.expect_value(t, lines[3], ui.Text_Area_Line{7, 7})
}

@(test)
a_crlf_break_ends_a_line_like_a_newline :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aa\r\naa") {return}
	defer area_stop(&f)
	width := area_width(&f, 8)
	expect_lines(t, line_texts(&f, width), {"aa", "aa"})
	lines := ui.text_area_lines(&f.area, &f.buffer, &f.text, width, 1)
	testing.expect_value(t, lines[1].start, 4)
}

@(test)
an_empty_text_is_one_empty_line :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "") {return}
	defer area_stop(&f)
	expect_lines(t, line_texts(&f, area_width(&f, 4)), {""})
}

@(test)
the_wrap_follows_the_text_and_the_width :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aaaaaa") {return}
	defer area_stop(&f)
	expect_lines(t, line_texts(&f, area_width(&f, 4)), {"aaaa", "aa"})
	expect_lines(t, line_texts(&f, area_width(&f, 3)), {"aaa", "aaa"})
	testing.expect(t, markdown.edit_insert(&f.buffer, "aa"))
	expect_lines(t, line_texts(&f, area_width(&f, 3)), {"aaa", "aaa", "aa"})
}

@(test)
the_height_follows_the_lines_between_its_limits :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "") {return}
	defer area_stop(&f)
	width := area_width(&f, 8)
	one := ui.text_area_height(&f.area, &f.buffer, &f.text, width, 1, 1, 4)
	two_minimum := ui.text_area_height(&f.area, &f.buffer, &f.text, width, 1, 2, 4)
	line := ui.text_styled(&f.text, .Body).line_height
	testing.expect_value(t, two_minimum - one, line)
	testing.expect(t, markdown.edit_insert(&f.buffer, "a\na\na"))
	testing.expect_value(t, ui.text_area_height(&f.area, &f.buffer, &f.text, width, 1, 1, 4) - one, 2 * line)
	testing.expect(t, markdown.edit_insert(&f.buffer, "\na\na\na"))
	// Past the most lines the box stops growing and the text scrolls inside it.
	testing.expect_value(t, ui.text_area_height(&f.area, &f.buffer, &f.text, width, 1, 1, 4) - one, 3 * line)
}

@(test)
offsets_and_caret_rects_round_trip_at_every_offset :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aa aé aaaaaaaa\n\naa aa a  \naaa") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 5), 1, 10)
	line := ui.text_styled(&f.text, .Body).line_height
	for offset in 0 ..= len(f.buffer.text) {
		if markdown.edit_clamp(&f.buffer, offset) != offset {continue}
		rect := ui.text_area_caret_rect(box, offset)
		testing.expect_value(t, rect.height, line)
		testing.expect_value(t, ui.text_area_offset_at(box, rect.x, rect.y + line / 2), offset)
	}
	// Points outside the text land on its nearest edge.
	testing.expect_value(t, ui.text_area_offset_at(box, -100, -100), 0)
	testing.expect_value(t, ui.text_area_offset_at(box, 5000, 5000), len(f.buffer.text))
}

@(test)
the_end_of_a_wrapped_line_stays_on_that_line :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aa aa aa") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width_of(&f, "aa aa"), 1, 10)
	first := ui.text_area_caret_rect(box, 0)
	// Far right of the first line is before its last space, not the start of the next line.
	at := ui.text_area_offset_at(box, first.x + 1000, first.y + 1)
	testing.expect_value(t, at, 5)
	testing.expect_value(t, ui.text_area_caret_rect(box, at).y, first.y)
	testing.expect(t, ui.text_area_caret_rect(box, 6).y > first.y)
}

@(test)
up_and_down_keep_the_column_across_short_lines :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aaaaaaaa\na\naaaaaaaa") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 10)
	markdown.edit_move(&f.buffer, 6)
	ui.text_area_vertical(box, 1, 0, false)
	testing.expect_value(t, f.buffer.caret, 10)
	ui.text_area_vertical(box, 1, 0, false)
	testing.expect_value(t, f.buffer.caret, 17)
	ui.text_area_vertical(box, -1, 0, false)
	testing.expect_value(t, f.buffer.caret, 10)
	ui.text_area_vertical(box, -1, 0, false)
	testing.expect_value(t, f.buffer.caret, 6)
	// Another way of moving forgets the column: from the start of the short line, down is to the start.
	markdown.edit_move(&f.buffer, 9)
	ui.text_area_vertical(box, 1, 0, false)
	testing.expect_value(t, f.buffer.caret, 11)
}

@(test)
up_and_down_past_the_ends_go_to_the_ends_and_extend_on_request :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aa\naa") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 10)
	markdown.edit_move(&f.buffer, 4)
	ui.text_area_vertical(box, 1, 0, false)
	testing.expect_value(t, f.buffer.caret, 5)
	ui.text_area_vertical(box, -1, 0, true)
	ui.text_area_vertical(box, -1, 0, true)
	testing.expect_value(t, f.buffer.caret, 0)
	testing.expect_value(t, f.buffer.anchor, 5)
	testing.expect_value(t, markdown.edit_selected_text(&f.buffer), "aa\naa")
}

@(test)
moving_by_pages_keeps_a_line_of_context :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "a\na\na\na\na\na\na\na\na\na") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 4)
	markdown.edit_move(&f.buffer, 0)
	ui.text_area_vertical(box, 0, 1, false)
	// A box of four lines pages by three.
	testing.expect_value(t, f.buffer.caret, 6)
}

@(test)
scrolling_keeps_the_caret_in_the_box :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "a\na\na\na\na\na\na\na\na\na") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 3)
	line := ui.text_styled(&f.text, .Body).line_height
	inside :: proc(t: ^testing.T, box: ui.Text_Area_Box, offset: int) {
		rect := ui.text_area_caret_rect(box, offset)
		testing.expect(t, rect.y >= box.rect.y && rect.y + rect.height <= box.rect.y + box.rect.height,
			"the caret must be inside the box")
	}
	markdown.edit_move(&f.buffer, 0)
	for _ in 0 ..< 9 {
		ui.text_area_vertical(box, 1, 0, false)
		inside(t, box, f.buffer.caret)
	}
	testing.expect_value(t, f.area.scroll, 7 * line)
	for _ in 0 ..< 9 {
		ui.text_area_vertical(box, -1, 0, false)
		inside(t, box, f.buffer.caret)
	}
	testing.expect_value(t, f.area.scroll, f32(0))
	// Typing at the end reveals the caret too, and wheel scrolling stays where it is put.
	markdown.edit_move(&f.buffer, len(f.buffer.text))
	testing.expect(t, markdown.edit_insert(&f.buffer, "\nb"))
	ui.text_area_reveal(box)
	inside(t, box, f.buffer.caret)
	testing.expect(t, ui.text_area_scroll(box, -2 * line))
	scrolled := f.area.scroll
	ui.text_area_reveal(box)
	testing.expect_value(t, f.area.scroll, scrolled)
	testing.expect(t, ui.text_area_scroll(box, -1000))
	testing.expect_value(t, f.area.scroll, f32(0))
	testing.expect(t, !ui.text_area_scroll(box, -1))
}

@(test)
a_new_width_reveals_the_caret_again_even_at_the_same_height :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "a\na\na\na\na\na\na\na\na\na") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 3)
	markdown.edit_move(&f.buffer, len(f.buffer.text))
	ui.text_area_reveal(box)
	bottom := f.area.scroll
	testing.expect(t, bottom > 0)
	// The wheel leaves the text where it puts it for as long as the box is as it was.
	testing.expect(t, ui.text_area_scroll(box, -1000))
	ui.text_area_reveal(box)
	testing.expect_value(t, f.area.scroll, f32(0))
	// A box of another width, as after a resize, shows the caret again though it is as tall as before.
	narrower := area_box(&f, area_width(&f, 19), 1, 3)
	testing.expect_value(t, narrower.rect.height, box.rect.height)
	ui.text_area_reveal(narrower)
	testing.expect_value(t, f.area.scroll, bottom)
}

@(test)
a_tab_is_four_spaces_wide_in_the_caret_the_pointer_and_the_wrap :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "\ta\t\tb") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 40), 1, 5)
	space := ui.text_width(&f.text, " ")
	letter := ui.text_width(&f.text, "a")
	zero := ui.text_area_caret_rect(box, 0)
	testing.expect_value(t, ui.text_area_caret_rect(box, 1).x - zero.x, 4 * space)
	testing.expect_value(t, ui.text_area_caret_rect(box, 2).x - zero.x, 4 * space + letter)
	testing.expect_value(t, ui.text_area_caret_rect(box, 4).x - zero.x, 12 * space + letter)
	// Either half of a tab puts the caret on the boundary beside it.
	testing.expect_value(t, ui.text_area_offset_at(box, zero.x + 1.5 * space, zero.y + 1), 0)
	testing.expect_value(t, ui.text_area_offset_at(box, zero.x + 2.5 * space, zero.y + 1), 1)
	for offset in 0 ..= len(f.buffer.text) {
		rect := ui.text_area_caret_rect(box, offset)
		testing.expect_value(t, ui.text_area_offset_at(box, rect.x, rect.y + rect.height / 2), offset)
	}
	// Tabs take room in the wrap: a line of them is cut where four-space tabs run out of the box.
	f2: Area_Fixture
	if !area_start(t, &f2, "\t\t\t\tx") {return}
	defer area_stop(&f2)
	narrow := 8 * ui.text_width(&f2.text, " ") + 2 * ui.CONTROL_INSET + 0.5 * ui.text_width(&f2.text, " ")
	lines := ui.text_area_lines(&f2.area, &f2.buffer, &f2.text, narrow, 1)
	testing.expect(t, len(lines) > 1, "tabs have a width, so the line wraps")
}

@(test)
the_pointer_places_the_caret_and_drags_a_selection :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aaaa\nbbbb\ncccc") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 10)
	line := ui.text_styled(&f.text, .Body).line_height
	start := ui.text_area_caret_rect(box, 1)
	end := ui.text_area_caret_rect(box, 12)
	testing.expect(t, !ui.text_area_pointer(box, end.x, end.y, false, false), "a move needs a press first")
	testing.expect(t, ui.text_area_pointer(box, start.x, start.y + line / 2, true, false))
	testing.expect_value(t, f.buffer.caret, 1)
	testing.expect(t, ui.text_area_pointer(box, end.x, end.y + line / 2, false, false))
	testing.expect_value(t, markdown.edit_selected_text(&f.buffer), "aaa\nbbbb\ncc")
	testing.expect(t, ui.text_area_release(&f.area))
	testing.expect(t, !ui.text_area_release(&f.area))
	testing.expect(t, !ui.text_area_pointer(box, start.x, start.y, false, false))
}

@(test)
wrapping_the_selection_selects_what_it_wrapped_and_undoes_in_one_step :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "hello world") {return}
	defer area_stop(&f)
	b := &f.buffer
	b.anchor, b.caret = 6, 11
	testing.expect(t, ui.text_area_wrap_selection(b, "**", "**", "bold"))
	testing.expect_value(t, markdown.edit_string(b), "hello **world**")
	testing.expect_value(t, markdown.edit_selected_text(b), "world")
	testing.expect(t, markdown.edit_undo(b))
	testing.expect_value(t, markdown.edit_string(b), "hello world")
	testing.expect_value(t, markdown.edit_selected_text(b), "world")
	testing.expect(t, markdown.edit_redo(b))
	testing.expect_value(t, markdown.edit_string(b), "hello **world**")
}

@(test)
wrapping_nothing_wraps_the_placeholder :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "") {return}
	defer area_stop(&f)
	b := &f.buffer
	testing.expect(t, ui.text_area_wrap_selection(b, "`", "`", "code"))
	testing.expect_value(t, markdown.edit_string(b), "`code`")
	testing.expect_value(t, markdown.edit_selected_text(b), "code")
	// Typing replaces the placeholder, which is the point of selecting it.
	testing.expect(t, markdown.edit_insert(b, "x"))
	testing.expect_value(t, markdown.edit_string(b), "`x`")
	testing.expect(t, markdown.edit_undo(b))
	testing.expect(t, markdown.edit_undo(b))
	testing.expect_value(t, markdown.edit_string(b), "")
}

@(test)
inserting_a_block_goes_on_lines_of_its_own_and_selects_the_body :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "see this") {return}
	defer area_stop(&f)
	b := &f.buffer
	markdown.edit_move(b, len(b.text))
	testing.expect(t, ui.text_area_insert_block(b, "odin", "x := 1"))
	testing.expect_value(t, markdown.edit_string(b), "see this\n```odin\nx := 1\n```\n")
	testing.expect_value(t, markdown.edit_selected_text(b), "x := 1")
	testing.expect(t, markdown.edit_undo(b))
	testing.expect_value(t, markdown.edit_string(b), "see this")
	testing.expect(t, markdown.edit_redo(b))
	testing.expect_value(t, markdown.edit_string(b), "see this\n```odin\nx := 1\n```\n")
}

@(test)
a_block_needs_no_lead_at_a_line_start_and_replaces_the_selection :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "") {return}
	defer area_stop(&f)
	b := &f.buffer
	testing.expect(t, ui.text_area_insert_block(b, "suggestion", ""))
	testing.expect_value(t, markdown.edit_string(b), "```suggestion\n\n```\n")
	testing.expect_value(t, markdown.edit_selected_text(b), "")
	testing.expect_value(t, b.caret, 14)
	testing.expect(t, markdown.edit_undo(b))
	testing.expect_value(t, markdown.edit_string(b), "")
	testing.expect(t, markdown.edit_insert(b, "one\ntwo"))
	b.anchor, b.caret = 4, 7
	testing.expect(t, ui.text_area_insert_block(b, "go", "two"))
	testing.expect_value(t, markdown.edit_string(b), "one\n```go\ntwo\n```\n")
	testing.expect_value(t, markdown.edit_selected_text(b), "two")
	testing.expect(t, markdown.edit_undo(b))
	testing.expect_value(t, markdown.edit_string(b), "one\ntwo")
}

@(test)
a_text_area_draws_its_selection_caret_and_only_the_lines_in_view :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Area_Fixture
	cache: glyphs.Cache
	if !area_start(t, &f, "a\na\na\na\na\na\na\na", &cache) {return}
	defer area_stop(&f)
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	theme := ui.Theme {
		text   = {1, 1, 1, 1},
		muted  = {0.5, 0.5, 0.5, 1},
		text_selection = {0, 1, 0, 1},
		accent = {0.25, 0.5, 1, 1},
		border = {0.2, 0.2, 0.2, 1},
	}
	box := area_box(&f, area_width(&f, 20), 1, 3)
	f.buffer.anchor, f.buffer.caret = 0, 3
	_ = render.push_layer(&list, {0, 0, 800, 400})
	testing.expect_value(t, ui.text_area_draw(box, &list, theme, true, "Write a comment"), render.Build_Status.Ok)
	selections := 0
	for instance in list.rects {
		if instance.color == theme.text_selection {selections += 1}
	}
	// "a\na" selected over two lines: one rect for each, the first widened by the line break.
	testing.expect_value(t, selections, 2)
	testing.expect_value(t, len(list.glyphs), 3)

	// Scrolled to the end, the lines in view are the last three.
	render.draw_list_reset(&list)
	markdown.edit_move(&f.buffer, len(f.buffer.text))
	_ = render.push_layer(&list, {0, 0, 800, 400})
	testing.expect_value(t, ui.text_area_draw(box, &list, theme, true, ""), render.Build_Status.Ok)
	testing.expect_value(t, len(list.glyphs), 3)

	// An empty text shows the placeholder.
	render.draw_list_reset(&list)
	testing.expect(t, markdown.edit_replace(&f.buffer, 0, len(f.buffer.text), ""))
	_ = render.push_layer(&list, {0, 0, 800, 400})
	testing.expect_value(t, ui.text_area_draw(box, &list, theme, false, "Hi"), render.Build_Status.Ok)
	testing.expect_value(t, len(list.glyphs), 2)
}

// The note editor's caret is the window's: it claims it, follows cursor.style (a block redraws the
// character under it in the cursor text colour) and fills its selection like every other surface.
@(test)
a_text_area_claims_the_caret_and_draws_its_shape_and_selection :: proc(t: ^testing.T) {
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	f: Area_Fixture
	cache: glyphs.Cache
	if !area_start(t, &f, "abc def", &cache) {return}
	defer area_stop(&f)
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	carets: ui.Carets
	f.text.carets = &carets
	carets.style = {shape = .Block, stroke = 1}
	cursor, cursor_text, selection, selected_text := render.Color{1, 0, 0, 1}, render.Color{0, 0, 1, 1},
		render.Color{0, 1, 0, 1}, render.Color{1, 1, 0, 1}
	theme := ui.Theme {
		text = {1, 1, 1, 1}, muted = {0.5, 0.5, 0.5, 1}, border = {0.2, 0.2, 0.2, 1},
		caret = cursor, caret_text = cursor_text, text_selection = selection, text_selection_text = selected_text,
	}
	box := area_box(&f, area_width(&f, 20), 1, 3)
	draw :: proc(t: ^testing.T, box: ui.Text_Area_Box, list: ^render.Draw_List, carets: ^ui.Carets, theme: ui.Theme) {
		render.draw_list_reset(list)
		ui.carets_begin(carets, {}, render.frame_time_at(time.tick_add({}, time.Second)))
		_ = render.push_layer(list, {0, 0, 800, 400})
		testing.expect_value(t, ui.text_area_draw(box, list, theme, true, ""), render.Build_Status.Ok)
	}
	count :: proc(list: ^render.Draw_List, color: render.Color) -> (rects, glyphs: int) {
		for instance in list.rects {
			if instance.color == color {rects += 1}
		}
		for glyph in list.glyphs {
			if glyph.color == color {glyphs += 1}
		}
		return
	}

	f.buffer.anchor, f.buffer.caret = 1, 1
	draw(t, box, &list, &carets, theme)
	testing.expect(t, carets.claim.present && carets.claim.owner == ui.caret_owner_of(&f.area.caret))
	testing.expect_value(t, carets.claim.paint.shape, caret.Shape.Block)
	block, redrawn := count(&list, cursor)
	testing.expect_value(t, block, 1)
	_, text_glyphs := count(&list, cursor_text)
	testing.expect(t, text_glyphs > 0 && redrawn == 0, "the character under the block draws in the cursor text colour")
	testing.expect_value(t, carets.claim.paint.target.width, ui.text_width(&f.text, "b"))

	f.buffer.anchor, f.buffer.caret = 0, 3
	draw(t, box, &list, &carets, theme)
	fills, _ := count(&list, selection)
	testing.expect(t, fills >= 1, "the selection is filled with the theme's selection colour")
	_, ink := count(&list, selected_text)
	testing.expect(t, ink > 0, "selected text takes the selection text colour")
}

@(test)
a_second_and_third_click_select_the_word_and_the_line_and_a_drag_grows_them :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "alpha beta gamma\nnext") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 40), 1, 10)
	line := ui.text_styled(&f.text, .Body).line_height
	beta := ui.text_area_caret_rect(box, 7)
	gamma := ui.text_area_caret_rect(box, 13)
	testing.expect(t, ui.text_area_pointer(box, beta.x + 1, beta.y + line / 2, true, false, 2))
	testing.expect_value(t, markdown.edit_selected_text(&f.buffer), "beta")
	testing.expect(t, ui.text_area_pointer(box, gamma.x + 1, gamma.y + line / 2, false, false))
	testing.expect_value(t, markdown.edit_selected_text(&f.buffer), "beta gamma")
	testing.expect(t, ui.text_area_release(&f.area))
	testing.expect(t, ui.text_area_pointer(box, beta.x + 1, beta.y + line / 2, true, false, 3))
	testing.expect_value(t, markdown.edit_selected_text(&f.buffer), "alpha beta gamma\n")
	testing.expect(t, ui.text_area_release(&f.area))
	// Shift extends from the anchor whatever the count, and a plain press forgets the unit.
	testing.expect(t, ui.text_area_pointer(box, gamma.x + 1, gamma.y + line / 2, true, true, 2))
	testing.expect_value(t, f.buffer.anchor, 0)
	testing.expect_value(t, f.buffer.caret, 13)
	testing.expect(t, ui.text_area_release(&f.area))
	testing.expect(t, ui.text_area_pointer(box, beta.x + 1, beta.y + line / 2, true, false))
	testing.expect(t, ui.text_area_pointer(box, gamma.x + 1, gamma.y + line / 2, false, false))
	testing.expect_value(t, markdown.edit_selected_text(&f.buffer), "eta ga")
}

@(test)
home_and_end_go_to_the_row_first_on_a_wrapped_line :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "aaa bbb ccc ddd") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width_of(&f, "aaa bbb"), 1, 10)
	testing.expect_value(t, len(ui.text_area_lines(&f.area, &f.buffer, &f.text, box.rect.width, 1)), 2)
	markdown.edit_move(&f.buffer, 10)
	ui.text_area_row_edge(box, false, false)
	testing.expect_value(t, f.buffer.caret, 8)
	ui.text_area_row_edge(box, false, false)
	testing.expect_value(t, f.buffer.caret, 0)
	markdown.edit_move(&f.buffer, 2)
	ui.text_area_row_edge(box, true, false)
	testing.expect_value(t, f.buffer.caret, 7)
	ui.text_area_row_edge(box, true, true)
	testing.expect_value(t, f.buffer.caret, 15)
	testing.expect_value(t, f.buffer.anchor, 7)
}

@(test)
scrolling_by_lines_leaves_the_caret_where_it_is :: proc(t: ^testing.T) {
	f: Area_Fixture
	if !area_start(t, &f, "a\na\na\na\na\na\na\na\na\na") {return}
	defer area_stop(&f)
	box := area_box(&f, area_width(&f, 20), 1, 4)
	line := ui.text_styled(&f.text, .Body).line_height
	markdown.edit_move(&f.buffer, 0)
	testing.expect(t, ui.text_area_scroll_lines(box, 2))
	testing.expect_value(t, f.area.scroll, 2 * line)
	testing.expect_value(t, f.buffer.caret, 0)
	testing.expect(t, ui.text_area_scroll_lines(box, -5))
	testing.expect_value(t, f.area.scroll, f32(0))
	testing.expect(t, !ui.text_area_scroll_lines(box, -1))
}
