package ui_test

import "aio:font"
import "aio:markdown"
import "aio:render"
import "aio:ui"
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
fit :: proc(f: ^Fixture, width: f32, revision: u64 = 1) {
	ui.markdown_view_fit(&f.view, &f.doc, revision, &f.text, f.text.family, width, 1)
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
	f.view.anchor = 0
	f.view.head = ui.markdown_offset_at(&f.view, &f.doc, g, g.left + g.width, y + line * 3)
	testing.expect_value(t, ui.markdown_selected_text(&f.view, &f.doc), "first paragraph\n\nsecond paragraph")
	f.view.anchor, f.view.head = f.view.head, 6
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
the_column_centers_and_never_overflows_a_narrow_pane :: proc(t: ^testing.T) {
	wide := ui.markdown_geometry({0, 40, 2000, 800}, 1)
	testing.expect_value(t, wide.width, f32(720))
	testing.expect_value(t, wide.left, f32(640))
	narrow := ui.markdown_geometry({0, 40, 200, 800}, 2)
	testing.expect_value(t, narrow.width, f32(104))
	gone := ui.markdown_geometry({0, 40, 10, 800}, 1)
	testing.expect_value(t, gone.width, f32(0))
}
