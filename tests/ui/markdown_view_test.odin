package ui_test

import "aio:font"
import "aio:glyphs"
import "aio:markdown"
import "aio:render"
import "aio:settings"
import "aio:ui"
import "core:math"
import "core:strings"
import "core:testing"

@(private = "file")
Fixture :: struct {
	fonts: ^font.System,
	text:  ui.Text,
	doc:   markdown.Document,
	view:  ui.Markdown_View,
}

@(private = "file")
fixture_init :: proc(t: ^testing.T, f: ^Fixture, source: string) -> bool {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	f.fonts = fonts
	if !testing.expect(t, ui.text_init(&f.text, fonts, nil, 14)) {return false}
	return testing.expect(t, markdown.parse(source, &f.doc))
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	ui.markdown_view_destroy(&f.view)
	markdown.document_destroy(&f.doc)
	if f.fonts != nil {font.system_destroy(f.fonts)}
}

@(private = "file")
fit :: proc(f: ^Fixture, width: f32, revision: u64 = 1, style := ui.MARKDOWN_STYLE_DEFAULT) {
	ui.markdown_view_fit(&f.view, &f.doc, revision, &f.text, f.text.family, width, 1, nil, style)
}

// The top and height of the line showing text offset `offset`.
@(private = "file")
line_of :: proc(f: ^Fixture, offset: int) -> (top, height: f32) {
	rect, _, found := ui.markdown_caret_at(&f.view, &f.doc, offset)
	if !found {return -1, -1}
	return rect.y, rect.height
}

// Where `s` first shows in the document's text, which is what offsets count.
@(private = "file")
text_index :: proc(f: ^Fixture, s: string) -> int {
	return strings.index(string(f.doc.text[:]), s)
}

@(private = "file")
WIDE_AREA :: render.Rect{0, 0, 1000, 800}

@(test)
narrow_columns_wrap_onto_more_lines :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "# Title\n\nA paragraph that is long enough to wrap when the column becomes narrow, certainly.\n"
	if !fixture_init(t, &f, source) {return}
	fit(&f, 700)
	wide := ui.markdown_total(&f.view)
	fit(&f, 120)
	testing.expect(t, ui.markdown_total(&f.view) > wide)
}

@(test)
any_width_lays_out_every_block_kind :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "# H\n\ntext `code` **b** *i* ~~s~~ [l](https://a.example)\n\n- a\n  - b\n- [x] c\n\n> q\n\n" +
		"| a | b |\n|:--|--:|\n| one | two three four |\n\n```\ncode\n\n\tmore\n```\n\n---\n\n1. x\n"
	if !fixture_init(t, &f, source) {return}
	for width in ([?]f32{1, 7, 40, 90, 300, 720}) {
		fit(&f, width)
		testing.expect(t, ui.markdown_total(&f.view) > 0)
	}
}

@(test)
fitting_again_with_the_same_inputs_keeps_the_layout :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "Short.\n") {return}
	fit(&f, 500)
	height := f.view.height
	f.view.height = -1
	fit(&f, 500)
	testing.expect_value(t, f.view.height, f32(-1))
	fit(&f, 500, 2)
	testing.expect_value(t, f.view.height, height)
	f.view.height = -1
	fit(&f, 400, 2)
	testing.expect_value(t, f.view.height, height)
}

@(test)
offsets_select_the_text_under_a_drag :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "first paragraph\n\nsecond paragraph\n") {return}
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	line := f32(ui.markdown_line(&f.view))
	y := g.top + line / 2
	testing.expect_value(t, ui.markdown_offset_at(&f.view, &f.doc, g, g.left - 50, y), 0)
	ui.markdown_select_at(&f.view, 0, false)
	far := ui.markdown_offset_at(&f.view, &f.doc, g, g.left + g.width, y + line * 3)
	ui.markdown_select_at(&f.view, far, true)
	testing.expect_value(t, ui.markdown_selected_text(&f.view, &f.doc), "first paragraph\n\nsecond paragraph")
	// A shifted press keeps the anchor where the drag left the head.
	ui.markdown_select_at(&f.view, f.view.head, false)
	ui.markdown_select_at(&f.view, 6, true)
	testing.expect_value(t, ui.markdown_selected_text(&f.view, &f.doc), "paragraph\n\nsecond paragraph")
	ui.markdown_selection_clear(&f.view)
	testing.expect_value(t, ui.markdown_selected_text(&f.view, &f.doc), "")
}

@(test)
offsets_follow_scrolling :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := strings.repeat("paragraph\n\n", 60, context.temp_allocator)
	if !fixture_init(t, &f, source) {return}
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	at_top := ui.markdown_offset_at(&f.view, &f.doc, g, g.left, g.top + 2)
	testing.expect(t, ui.markdown_scroll_by(&f.view, 500, 800))
	testing.expect(t, ui.markdown_offset_at(&f.view, &f.doc, g, g.left, g.top + 2) > at_top)
}

@(test)
links_are_found_only_on_their_own_text :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "[link](https://a.example) and plain text\n") {return}
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	y := g.top + f32(ui.markdown_line(&f.view)) / 2
	testing.expect_value(t, ui.markdown_link_at(&f.view, g, g.left + 5, y), 0)
	testing.expect_value(t, ui.markdown_link_at(&f.view, g, g.left + 200, y), -1)
	testing.expect_value(t, ui.markdown_link_at(&f.view, g, g.left + 5, y + 200), -1)
}

@(test)
table_cells_are_selected_and_hit_by_column :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "| left | [right](https://a.example) |\n|---|---|\n| one | two |\n") {return}
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	y := g.top + f32(ui.markdown_line(&f.view)) / 2
	testing.expect_value(t, ui.markdown_link_at(&f.view, g, g.left + 12, y), -1)
	found := false
	for x := g.left; x < g.left + 200; x += 4 {found ||= ui.markdown_link_at(&f.view, g, x, y) == 0}
	testing.expect(t, found)
	f.view.anchor = 0
	f.view.head = ui.markdown_offset_at(&f.view, &f.doc, g, g.left + g.width, g.top + 400)
	testing.expect_value(t, ui.markdown_selected_text(&f.view, &f.doc), "left\tright\none\ttwo")
}

@(test)
scrolling_stops_at_both_ends :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := strings.repeat("paragraph\n\n", 60, context.temp_allocator)
	if !fixture_init(t, &f, source) {return}
	fit(&f, 500)
	testing.expect(t, !ui.markdown_scroll_by(&f.view, -10, 300))
	testing.expect(t, ui.markdown_scroll_by(&f.view, 1 << 30, 300))
	testing.expect_value(t, f.view.scroll, ui.markdown_total(&f.view) - 300)
	testing.expect(t, ui.markdown_scroll_by(&f.view, -(1 << 30), 300))
	testing.expect_value(t, f.view.scroll, 0)
	short: Fixture
	defer fixture_destroy(&short)
	if !fixture_init(t, &short, "one line") {return}
	fit(&short, 500)
	testing.expect(t, !ui.markdown_scroll_by(&short.view, 100, 800))
}

@(test)
revealing_centers_a_range_out_of_view_and_leaves_one_in_view :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := strings.concatenate({strings.repeat("paragraph\n\n", 60, context.temp_allocator), "needle\n"}, context.temp_allocator)
	if !fixture_init(t, &f, source) {return}
	fit(&f, 500)
	start := strings.index(string(f.doc.text[:]), "needle")
	first_word := 0
	testing.expect(t, !ui.markdown_reveal(&f.view, first_word, first_word + 9, 300))
	testing.expect_value(t, f.view.scroll, 0)
	testing.expect(t, ui.markdown_reveal(&f.view, start, start + 6, 300))
	testing.expect(t, f.view.scroll > 0)
	// The end of the document cannot reach the middle, so scrolling stops at its limit.
	testing.expect_value(t, f.view.scroll, ui.markdown_total(&f.view) - 300)
	testing.expect(t, !ui.markdown_reveal(&f.view, start, start + 6, 300))
	middle := strings.index(string(f.doc.text[:]), "paragraph") + 11 * 30
	testing.expect(t, ui.markdown_reveal(&f.view, middle, middle + 9, 300))
	scrolled := f.view.scroll
	testing.expect(t, scrolled > 0 && scrolled < ui.markdown_total(&f.view) - 300)
	testing.expect(t, !ui.markdown_reveal(&f.view, middle, middle + 9, 300))
	testing.expect_value(t, f.view.scroll, scrolled)
}

@(test)
revealing_a_range_with_no_text_changes_nothing :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "short\n") {return}
	testing.expect(t, !ui.markdown_reveal(&f.view, 0, 5, 300))
	fit(&f, 500)
	testing.expect(t, !ui.markdown_reveal(&f.view, 900, 905, 300))
}

@(test)
matches_draw_in_find_colours_with_the_selected_one_distinct :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "needle and needle, on a line\n") {return}
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	theme: ui.Theme
	matches := [?]markdown.Match{{0, 6}, {11, 17}}
	find := ui.Markdown_Find {
		matches = matches[:],
		selected = 1,
		foreground = {0, 0, 0, 1},
		background = {1, 0, 0, 1},
		selected_background = {0, 1, 0, 1},
	}
	testing.expect_value(t, ui.markdown_draw(&f.view, &f.doc, g, &list, &f.text, theme, find), render.Build_Status.Ok)
	match_rect, selected_rect: render.Rect
	match_count, selected_count := 0, 0
	for rect in list.rects {
		if rect.color == find.background {match_rect = rect.rect; match_count += 1}
		if rect.color == find.selected_background {selected_rect = rect.rect; selected_count += 1}
	}
	testing.expect_value(t, match_count, 1)
	testing.expect_value(t, selected_count, 1)
	testing.expect(t, match_rect.width > 0 && selected_rect.x > match_rect.x + match_rect.width)
	testing.expect_value(t, selected_rect.width, match_rect.width)

	// Nothing active draws nothing extra.
	render.draw_list_reset(&list)
	testing.expect_value(t, ui.markdown_draw(&f.view, &f.doc, g, &list, &f.text, theme), render.Build_Status.Ok)
	for rect in list.rects {
		testing.expect(t, rect.color != find.background && rect.color != find.selected_background)
	}
}

// The view does not keep the pointer: a pane nothing hovers underlines no link, not the first one.
@(test)
only_the_hovered_link_is_underlined :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "[first](https://a.example) and [second](https://b.example)\n") {return}
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	theme: ui.Theme
	theme.accent = {0, 0, 1, 1}
	underlines: [3]int
	lefts: [3]f32
	for hover, i in ([3]int{-1, 0, 1}) {
		render.draw_list_reset(&list)
		result := ui.markdown_draw(&f.view, &f.doc, g, &list, &f.text, theme, {}, hover)
		testing.expect_value(t, result, render.Build_Status.Ok)
		for rect in list.rects {
			if rect.color == theme.accent && rect.rect.height <= 1 {
				underlines[i] += 1
				lefts[i] = rect.rect.x
			}
		}
	}
	testing.expect_value(t, underlines, [3]int{0, 1, 1})
	testing.expect(t, lefts[2] > lefts[1])
}

@(test)
the_column_centers_and_never_overflows_a_narrow_pane :: proc(t: ^testing.T) {
	wide := ui.markdown_geometry({0, 40, 2000, 800}, 1)
	testing.expect_value(t, wide.width, f32(720))
	testing.expect_value(t, wide.left, f32(640))
	// Both sides keep the outline's 38 DIP margin.
	narrow := ui.markdown_geometry({0, 40, 200, 800}, 2)
	testing.expect_value(t, narrow.width, f32(48))
	gone := ui.markdown_geometry({0, 40, 10, 800}, 1)
	testing.expect_value(t, gone.width, f32(0))
}

@(test)
the_text_width_setting_sets_the_column :: proc(t: ^testing.T) {
	testing.expect_value(t, ui.markdown_geometry({0, 40, 2000, 800}, 1, 1000).width, f32(1000))
	testing.expect_value(t, ui.markdown_geometry({0, 40, 2000, 800}, 2, 500).width, f32(1000))
	// Zero fills the pane between the outline's margins.
	full := ui.markdown_geometry({0, 40, 2000, 800}, 1, 0)
	testing.expect_value(t, full.width, f32(2000 - 2 * 38))
	testing.expect_value(t, full.left, f32(38))
}

// The defaults are the settings' defaults, so a file that sets nothing draws as before.
@(test)
the_default_style_is_the_settings_defaults :: proc(t: ^testing.T) {
	defaults, err := settings.defaults()
	if !testing.expect_value(t, err, nil) {return}
	defer settings.destroy(&defaults)
	testing.expect_value(t, ui.markdown_style_from(defaults.markdown, {}, {}, {}), ui.MARKDOWN_STYLE_DEFAULT)
}

@(test)
heading_sizes_follow_the_style_at_every_level :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "# One\n\n## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\nbody\n"
	if !fixture_init(t, &f, source) {return}
	starts: [6]int
	for name, level in ([6]string{"One", "Two", "Three", "Four", "Five", "Six"}) {
		starts[level] = text_index(&f, name)
	}
	body := text_index(&f, "body")
	fit(&f, 700)
	defaults: [6]f32
	for start, level in starts {_, defaults[level] = line_of(&f, start)}
	_, body_height := line_of(&f, body)
	// D-080: H1 to H3 step down, though H3's tighter leading can give it the body's line height, and H4
	// to H6 are bold body text.
	testing.expect(t, defaults[0] > defaults[1] && defaults[1] > defaults[2] && defaults[2] >= body_height)
	testing.expect_value(t, defaults[3], body_height)
	testing.expect_value(t, defaults[5], body_height)
	for level in 0 ..< 6 {
		style := ui.MARKDOWN_STYLE_DEFAULT
		style.headings[level] = 3
		fit(&f, 700, 1, style)
		for start, other in starts {
			_, height := line_of(&f, start)
			if other == level {
				testing.expectf(t, height > defaults[level] && height >= 3 * body_height / 1.5 * 1.2,
					"H%d at 3x: %v from %v", level + 1, height, defaults[level])
			} else {
				testing.expect_value(t, height, defaults[other])
			}
		}
	}
	// The body below moves down with a taller heading above it.
	fit(&f, 700)
	body_top, _ := line_of(&f, body)
	style := ui.MARKDOWN_STYLE_DEFAULT
	style.headings[0] = 3
	fit(&f, 700, 1, style)
	moved, _ := line_of(&f, body)
	testing.expect(t, moved > body_top)
}

@(test)
text_size_line_height_and_spacing_follow_the_style :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "first\n\nsecond\n"
	if !fixture_init(t, &f, source) {return}
	second := text_index(&f, "second")
	fit(&f, 700)
	line := f32(ui.markdown_line(&f.view))
	gap_top, _ := line_of(&f, second)
	testing.expect_value(t, gap_top, line + math.round(line * 0.7))

	style := ui.MARKDOWN_STYLE_DEFAULT
	style.paragraph_spacing = 2
	fit(&f, 700, 1, style)
	wide_top, _ := line_of(&f, second)
	testing.expect_value(t, wide_top, line + 2 * line)
	style.paragraph_spacing = 0
	fit(&f, 700, 1, style)
	flush_top, _ := line_of(&f, second)
	testing.expect_value(t, flush_top, line)

	style = ui.MARKDOWN_STYLE_DEFAULT
	style.line_height = 2.5
	fit(&f, 700, 1, style)
	testing.expect(t, f32(ui.markdown_line(&f.view)) > line)

	// 24 pt is 32 px at 96 DPI, and the line keeps the 1.5 leading.
	style = ui.MARKDOWN_STYLE_DEFAULT
	style.size = 24
	fit(&f, 700, 1, style)
	testing.expect_value(t, ui.markdown_line(&f.view), 48)
}

@(test)
code_size_follows_the_style :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "```\ncode\n```\n"
	if !fixture_init(t, &f, source) {return}
	code := text_index(&f, "code")
	fit(&f, 700)
	_, small := line_of(&f, code)
	style := ui.MARKDOWN_STYLE_DEFAULT
	style.code_size = 1.8
	fit(&f, 700, 1, style)
	_, large := line_of(&f, code)
	testing.expect(t, large > small)
}

@(test)
code_fills_take_the_code_background_token :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, "text `inline`\n\n```\nblock\n```\n") {return}
	device, device_error := render.device_create(.Warp)
	if !testing.expect_value(t, device_error, render.Error.None) {return}
	defer render.device_destroy(device)
	cache: glyphs.Cache
	glyphs.init(&cache, f.fonts, device)
	defer glyphs.destroy(&cache)
	if !testing.expect(t, ui.text_init(&f.text, f.fonts, &cache, 14)) {return}
	list := render.draw_list_init()
	defer render.draw_list_destroy(&list)
	g := ui.markdown_geometry(WIDE_AREA, 1)
	fit(&f, g.width)
	theme: ui.Theme
	theme.code_background = {0.25, 0.5, 0.75, 0.125}
	testing.expect_value(t, ui.markdown_draw(&f.view, &f.doc, g, &list, &f.text, theme), render.Build_Status.Ok)
	fills := 0
	for rect in list.rects {if rect.color == theme.code_background {fills += 1}}
	testing.expect_value(t, fills, 2)
}
