package ui_test

import "aio:font"
import "aio:glyphs"
import "aio:markdown"
import "aio:render"
import "aio:ui"
import "core:testing"
import fixtures "../fixtures"

// A page drawn into a list, to read the colours of what it drew.
@(private = "file")
Page :: struct {
	fonts:  ^font.System,
	cache:  glyphs.Cache,
	device: ^render.Device,
	text:  ui.Text,
	doc:   markdown.Document,
	view:  ui.Markdown_View,
	live:  markdown.Live,
	list:  render.Draw_List,
	g:     ui.Markdown_Geometry,
}

@(private = "file")
page_init :: proc(t: ^testing.T, p: ^Page, source: string, live := false, from := 0, to := 0) -> bool {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	p.fonts = fonts
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return false}
	p.device = device
	glyphs.init(&p.cache, fonts, device)
	if !testing.expect(t, ui.text_init(&p.text, fonts, &p.cache, 14)) {return false}
	p.list = render.draw_list_init()
	if live {
		if !testing.expect(t, markdown.live_build(&p.live, source, from, to, &p.doc)) {return false}
	} else if !testing.expect(t, markdown.parse(source, &p.doc)) {
		return false
	}
	p.g = ui.markdown_geometry({0, 0, 1000, 800}, 1)
	ui.markdown_view_fit(&p.view, &p.doc, 1, &p.text, p.text.family, p.g.width, 1)
	return true
}

@(private = "file")
page_destroy :: proc(p: ^Page) {
	render.draw_list_destroy(&p.list)
	ui.markdown_view_destroy(&p.view)
	markdown.document_destroy(&p.doc)
	markdown.live_destroy(&p.live)
	if p.fonts != nil {
		glyphs.destroy(&p.cache)
		render.device_destroy(p.device)
		font.system_destroy(p.fonts)
	}
}

@(private = "file")
page_draw :: proc(t: ^testing.T, p: ^Page, theme: ui.Theme) -> bool {
	render.draw_list_reset(&p.list)
	return testing.expect_value(
		t,
		ui.markdown_draw(&p.view, &p.doc, p.g, &p.list, &p.text, theme),
		render.Build_Status.Ok,
	)
}

@(private = "file")
glyphs_in :: proc(p: ^Page, color: render.Color) -> (count: int) {
	for glyph in p.list.glyphs {if glyph.color == color {count += 1}}
	return
}

@(private = "file")
rects_in :: proc(p: ^Page, color: render.Color) -> (count: int, first: render.Rect_Instance) {
	for rect in p.list.rects {
		if rect.color != color {continue}
		if count == 0 {first = rect}
		count += 1
	}
	return
}

@(private = "file")
RED :: render.Color{1, 0, 0, 1}
@(private = "file")
GREEN :: render.Color{0, 1, 0, 1}
@(private = "file")
BLUE :: render.Color{0, 0, 1, 1}
@(private = "file")
YELLOW :: render.Color{1, 1, 0, 1}
@(private = "file")
CYAN :: render.Color{0, 1, 1, 1}
@(private = "file")
MAGENTA :: render.Color{1, 0, 1, 1}
@(private = "file")
ORANGE :: render.Color{1, 0.5, 0, 1}
@(private = "file")
GREY :: render.Color{0.5, 0.5, 0.5, 1}
@(private = "file")
PINK :: render.Color{1, 0.5, 0.5, 1}
@(private = "file")
LIME :: render.Color{0.5, 1, 0.5, 1}
@(private = "file")
SKY :: render.Color{0.5, 0.5, 1, 1}

@(test)
the_shipped_defaults_draw_with_the_shared_colors_only :: proc(t: ^testing.T) {
	p: Page
	defer page_destroy(&p)
	source := "# Title\n\nPlain **bold** `code` [link](https://a.example)\n\n> quoted\n\n- item\n- [x] done\n\n" +
		"| h1 | h2 |\n|----|----|\n| a  | b  |\n"
	if !page_init(t, &p, source) {return}
	for id in ([?]string{"studio-dark", "studio-light", "dracula"}) {
		theme := ui.theme_from(fixtures.shipped_theme(id), fixtures.default_interface())
		if !page_draw(t, &p, theme) {return}
		// Only text, secondary text and the accent colour text; none of the bands are drawn.
		other := 0
		for glyph in p.list.glyphs {
			if glyph.color != theme.text && glyph.color != theme.muted && glyph.color != theme.accent &&
			   glyph.color != theme.accent_text {other += 1}
		}
		testing.expect_value(t, other, 0)
		testing.expect_value(t, glyphs_in(&p, theme.accent), 4)
		fills, _ := rects_in(&p, theme.code_background)
		testing.expect_value(t, fills, 1)
		// The quote's bar and the two rules of the table, and the checked box in the accent.
		lines, _ := rects_in(&p, theme.border)
		testing.expect_value(t, lines, 3)
		boxes, _ := rects_in(&p, theme.accent)
		testing.expect_value(t, boxes, 1)
	}
}

@(test)
each_element_takes_its_own_text_colour_and_none_keeps_the_text_around :: proc(t: ^testing.T) {
	p: Page
	defer page_destroy(&p)
	if !page_init(t, &p, "plain **bold** [link](https://a.example) `code`\n\n## Head\n\n> quote **qb**\n") {return}
	theme: ui.Theme
	m := &theme.markdown
	m.fallback = GREY
	m.paragraph.text = RED
	m.strong.text = GREEN
	m.link.text = BLUE
	m.inline_code.text = YELLOW
	m.headings[1].text = CYAN
	m.quote.text = MAGENTA
	if !page_draw(t, &p, theme) {return}
	testing.expect_value(t, glyphs_in(&p, RED), 5)
	// Strong wins over the quote it sits in.
	testing.expect_value(t, glyphs_in(&p, GREEN), 4 + 2)
	testing.expect_value(t, glyphs_in(&p, BLUE), 4)
	testing.expect_value(t, glyphs_in(&p, YELLOW), 4)
	testing.expect_value(t, glyphs_in(&p, CYAN), 4)
	testing.expect_value(t, glyphs_in(&p, MAGENTA), 5)

	// With strong's colour none, bold words keep the colour of the text around them.
	m.strong.text = {}
	if !page_draw(t, &p, theme) {return}
	testing.expect_value(t, glyphs_in(&p, GREEN), 0)
	testing.expect_value(t, glyphs_in(&p, RED), 5 + 4)
	testing.expect_value(t, glyphs_in(&p, MAGENTA), 5 + 2)

	// A heading's own colour beats the quote's; with none it takes the paragraph's.
	m.headings[1].text = {}
	m.paragraph.text = {}
	if !page_draw(t, &p, theme) {return}
	testing.expect_value(t, glyphs_in(&p, CYAN), 0)
	testing.expect_value(t, glyphs_in(&p, GREY), 5 + 4 + 4)
}

@(test)
a_background_draws_behind_its_element_and_none_draws_nothing :: proc(t: ^testing.T) {
	p: Page
	defer page_destroy(&p)
	source := "## Head\n\ntext **bold** `code`\n\n> q\n\n- li\n\n| a | b |\n|---|---|\n| c | d |\n\n```\nblock\n```\n"
	if !page_init(t, &p, source) {return}
	theme: ui.Theme
	m := &theme.markdown
	m.headings[1].background = RED
	m.strong.background = GREEN
	m.paragraph.background = BLUE
	m.quote.background = YELLOW
	m.list.background = CYAN
	m.table_header.background = MAGENTA
	m.table_cell.background = ORANGE
	m.code_block.background = GREY
	m.inline_code.background = PINK
	m.link.background = LIME
	if !page_draw(t, &p, theme) {return}
	// Paragraphs: the text, the quote's and the list item's.
	Fill :: struct {
		color: render.Color,
		count: int,
	}
	expected := [?]Fill{{RED, 1}, {GREEN, 1}, {BLUE, 3}, {YELLOW, 1}, {CYAN, 1}, {MAGENTA, 1}, {ORANGE, 1}}
	for fill in expected {
		count, _ := rects_in(&p, fill.color)
		testing.expectf(t, count == fill.count, "%v: %d fills, not %d", fill.color, count, fill.count)
	}
	for fill in ([?]Fill{{GREY, 1}, {PINK, 1}, {LIME, 0}}) {
		count, _ := rects_in(&p, fill.color)
		testing.expectf(t, count == fill.count, "%v: %d fills, not %d", fill.color, count, fill.count)
	}
	// The heading's band runs 8 DIP past the text on each side, rounded like a control.
	_, heading := rects_in(&p, RED)
	testing.expect_value(t, heading.rect.x, p.g.left - 8)
	testing.expect_value(t, heading.rect.width, p.g.width + 16)
	testing.expect_value(t, heading.radius, 4)

	m^ = {}
	m.fallback = GREY
	if !page_draw(t, &p, theme) {return}
	testing.expect_value(t, len(p.list.rects), 0)
}

@(test)
a_line_shown_as_source_keeps_its_element_and_markup_has_colours_of_its_own :: proc(t: ^testing.T) {
	p: Page
	defer page_destroy(&p)
	// The caret is in the heading, so it shows as source; the paragraph below renders. The file ends with no
	// newline, so there is no empty last line to take a band of its own.
	if !page_init(t, &p, "# Head\ntext", live = true, from = 2, to = 2) {return}
	theme: ui.Theme
	m := &theme.markdown
	m.fallback = GREY
	m.markup.text = MAGENTA
	m.markup.background = SKY
	m.headings[0].text = CYAN
	m.headings[0].background = RED
	m.paragraph.background = BLUE
	if !page_draw(t, &p, theme) {return}
	testing.expect_value(t, glyphs_in(&p, MAGENTA), 1)
	testing.expect_value(t, glyphs_in(&p, CYAN), 4)
	// The editor's lines are flush, so their bands are square and no wider than the text's column.
	count, heading := rects_in(&p, RED)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, heading.rect.x, p.g.left)
	testing.expect_value(t, heading.rect.width, p.g.width)
	testing.expect_value(t, heading.radius, 0)
	paragraphs, _ := rects_in(&p, BLUE)
	testing.expect_value(t, paragraphs, 1)
	markup, _ := rects_in(&p, SKY)
	testing.expect_value(t, markup, 1)
}

@(test)
the_checkbox_takes_its_box_and_tick_colours :: proc(t: ^testing.T) {
	p: Page
	defer page_destroy(&p)
	if !page_init(t, &p, "- [x] done\n- [ ] open\n") {return}
	theme: ui.Theme
	m := &theme.markdown
	m.task_done = RED
	m.task_open = GREEN
	m.task_check = BLUE
	if !page_draw(t, &p, theme) {return}
	done, _ := rects_in(&p, RED)
	open, _ := rects_in(&p, GREEN)
	testing.expect_value(t, done, 1)
	testing.expect_value(t, open, 1)
}
