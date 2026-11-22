package ui_test

import "cosmos:font"
import "aio:markdown"
import "cosmos:render"
import "aio:ui"
import "core:fmt"
import "core:strings"
import "core:testing"

@(private = "file")
Fixture :: struct {
	fonts:   ^font.System,
	text:    ui.Text,
	doc:     markdown.Document,
	view:    ui.Markdown_View,
	outline: ui.Markdown_Outline,
	g:       ui.Markdown_Geometry,
}

// Lays the source out on a page at `area`, with its outline measured.
@(private = "file")
fixture_init :: proc(t: ^testing.T, f: ^Fixture, source: string, area: render.Rect) -> bool {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return false}
	f.fonts = fonts
	if !testing.expect(t, ui.text_init(&f.text, fonts, nil, 14)) {return false}
	if !testing.expect(t, markdown.parse(source, &f.doc)) {return false}
	f.g = ui.markdown_geometry(area, 1)
	ui.markdown_view_fit(&f.view, &f.doc, 1, &f.text, f.text.family, f.g.width, 1)
	ui.markdown_outline_sync(&f.outline, &f.view, &f.doc)
	return true
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	ui.markdown_outline_destroy(&f.outline)
	ui.markdown_view_destroy(&f.view)
	markdown.document_destroy(&f.doc)
	if f.fonts != nil {font.system_destroy(f.fonts)}
}

// Wide enough that the bars stay clear of the 720 DIP text column.
@(private = "file")
WIDE_PAGE :: render.Rect{0, 0, 1000, 800}

// `count` sections, each a heading of `level` and a paragraph.
@(private = "file")
sections :: proc(count: int, level := 2) -> string {
	b := strings.builder_make(context.temp_allocator)
	marks := strings.repeat("#", level, context.temp_allocator)
	for i in 0 ..< count {fmt.sbprintf(&b, "%s Section %d\n\nText of section %d.\n\n", marks, i, i)}
	return strings.to_string(b)
}

@(test)
bars_shorten_with_depth_below_the_shallowest_heading :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "## Two\n\n### Three\n\n#### Four\n\n##### Five\n\n###### Six\n\n## Two again\n"
	if !fixture_init(t, &f, source, WIDE_PAGE) {return}
	column, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
	if !testing.expect(t, shown) {return}
	testing.expect_value(t, column.count, 6)
	widths: [6]f32
	for &width, bar in widths {width = ui.markdown_outline_bar_rect(&f.outline, column, bar, 1).width}
	// Level 2 is the document's shallowest, so it takes the longest bar.
	testing.expect_value(t, widths, [6]f32{14, 11, 8, 5, 5, 14})
	first := ui.markdown_outline_bar_rect(&f.outline, column, 0, 1)
	second := ui.markdown_outline_bar_rect(&f.outline, column, 1, 1)
	testing.expect_value(t, first.x, second.x)
	testing.expect_value(t, second.y - first.y, f32(8))
	testing.expect_value(t, first.height, f32(2))
	testing.expect(t, first.x + first.width < f.g.left, "the bars stay clear of the text column")
}

@(test)
the_outline_hides_without_headings_and_stays_clear_of_the_column :: proc(t: ^testing.T) {
	{
		f: Fixture
		defer fixture_destroy(&f)
		if !fixture_init(t, &f, "Just a paragraph.\n\nAnd another.\n", WIDE_PAGE) {return}
		_, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
		testing.expect(t, !shown, "a document without headings has no outline")
	}
	{
		f: Fixture
		defer fixture_destroy(&f)
		// A narrow page keeps the outline's margin beside its column, so the bars still show, clear of it.
		if !fixture_init(t, &f, sections(3), {0, 0, 760, 800}) {return}
		column, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
		testing.expect(t, shown, "a narrow page keeps its outline")
		testing.expect(t, column.left + 14 <= f.g.left, "the bars stand clear of the text")
	}
}

@(test)
many_headings_compress_the_bars_then_sample_them :: proc(t: ^testing.T) {
	{
		f: Fixture
		defer fixture_destroy(&f)
		// 120 bars at 8 DIPs would overflow the 768 DIPs between the page margins.
		if !fixture_init(t, &f, sections(120), WIDE_PAGE) {return}
		column, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
		if !testing.expect(t, shown) {return}
		testing.expect_value(t, column.count, 120)
		testing.expect_value(t, column.pitch, f32(6.4))
		testing.expect(t, column.top >= WIDE_PAGE.y && column.top + 120 * column.pitch <= WIDE_PAGE.height)
	}
	{
		f: Fixture
		defer fixture_destroy(&f)
		if !fixture_init(t, &f, sections(400), WIDE_PAGE) {return}
		column, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
		if !testing.expect(t, shown) {return}
		testing.expect_value(t, column.pitch, f32(4))
		testing.expect_value(t, column.count, 192)
		// The bars span the whole document, and every heading belongs to the bar at or before it.
		testing.expect_value(t, ui.markdown_outline_bar_heading(&f.outline, column, 0), 0)
		last := ui.markdown_outline_bar_heading(&f.outline, column, column.count - 1)
		testing.expect(t, last > 390, fmt.tprintf("the last bar stands for heading %d", last))
		testing.expect_value(t, ui.markdown_outline_heading_bar(&f.outline, column, 0), 0)
		testing.expect_value(t, ui.markdown_outline_heading_bar(&f.outline, column, 399), column.count - 1)
		for heading in 0 ..< 400 {
			bar := ui.markdown_outline_heading_bar(&f.outline, column, heading)
			if ui.markdown_outline_bar_heading(&f.outline, column, bar) > heading {
				testing.expectf(t, false, "heading %d maps to bar %d, which starts after it", heading, bar)
				break
			}
		}
	}
}

@(test)
the_strip_and_panel_rows_hit_what_they_show :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, sections(5), WIDE_PAGE) {return}
	column, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
	if !testing.expect(t, shown) {return}
	third := ui.markdown_outline_bar_rect(&f.outline, column, 2, 1)
	// The strip is wider than the bars, so a point right of a short bar still finds it.
	testing.expect_value(t, ui.markdown_outline_bar_at(column, third.x + third.width + 5, third.y + 1), 2)
	testing.expect_value(t, ui.markdown_outline_bar_at(column, column.strip.x - 1, third.y + 1), -1)

	panel := ui.markdown_outline_panel(&f.outline, &f.doc, column, f.g.area, &f.text, 1)
	testing.expect_value(t, panel.rect.x, column.strip.x + column.strip.width)
	testing.expect(t, !ui.markdown_outline_scrollable(panel))
	for row in 0 ..< 5 {
		r := ui.markdown_outline_row_rect(&f.outline, panel, row, 1)
		hit, inside := ui.markdown_outline_row_at(&f.outline, panel, r.x + 2, r.y + r.height / 2, 1)
		testing.expect(t, inside)
		testing.expect_value(t, hit, row)
	}
	padding, inside := ui.markdown_outline_row_at(&f.outline, panel, panel.rect.x + 4, panel.rect.y + 1, 1)
	testing.expect(t, inside && padding == -1, "the panel's padding is on the panel but on no row")
	_, inside = ui.markdown_outline_row_at(&f.outline, panel, panel.rect.x - 1, panel.rect.y + 10, 1)
	testing.expect(t, !inside)
}

@(test)
a_tall_panel_scrolls_its_rows :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, sections(60), WIDE_PAGE) {return}
	column, shown := ui.markdown_outline_column(&f.outline, f.g, 1)
	if !testing.expect(t, shown) {return}
	panel := ui.markdown_outline_panel(&f.outline, &f.doc, column, f.g.area, &f.text, 1)
	testing.expect(t, ui.markdown_outline_scrollable(panel))
	testing.expect(t, panel.rect.y >= WIDE_PAGE.y && panel.rect.y + panel.rect.height <= WIDE_PAGE.height)
	testing.expect(t, !ui.markdown_outline_wheel(&f.outline, panel, 1, 1), "the rows start at the top")
	testing.expect(t, ui.markdown_outline_wheel(&f.outline, panel, -3, 1))
	r := ui.markdown_outline_row_rect(&f.outline, panel, 3, 1)
	testing.expect_value(t, r.y, panel.rect.y + 4)
	ui.markdown_outline_reveal(&f.outline, panel, 59, 1)
	last := ui.markdown_outline_row_rect(&f.outline, panel, 59, 1)
	testing.expect_value(t, last.y + last.height, panel.rect.y + panel.rect.height - 4)
}

@(test)
the_current_heading_is_the_last_one_scrolled_to :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, sections(40), WIDE_PAGE) {return}
	testing.expect_value(t, ui.markdown_outline_current(&f.outline, &f.view), 0)
	visible := int(WIDE_PAGE.height)
	testing.expect(t, ui.markdown_scroll_to_offset(&f.view, f.outline.headings[7].start, visible))
	testing.expect_value(t, ui.markdown_outline_current(&f.outline, &f.view), 7)
	testing.expect(t, ui.markdown_scroll_by(&f.view, -1, visible))
	testing.expect_value(t, ui.markdown_outline_current(&f.outline, &f.view), 7)
	testing.expect(t, ui.markdown_scroll_by(&f.view, -20, visible))
	testing.expect_value(t, ui.markdown_outline_current(&f.outline, &f.view), 6)
}

@(test)
the_outline_follows_a_new_layout :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !fixture_init(t, &f, sections(3), WIDE_PAGE) {return}
	text, start := markdown.block_text(&f.doc, f.doc.blocks[2])
	testing.expect_value(t, text, "Section 1")
	testing.expect_value(t, f.outline.headings[1].start, start)
	before := f.outline.headings[2].top
	ui.markdown_view_fit(&f.view, &f.doc, 1, &f.text, f.text.family, 60, 1)
	ui.markdown_outline_sync(&f.outline, &f.view, &f.doc)
	testing.expect(t, f.outline.headings[2].top > before, "a narrower layout wraps, moving the headings down")
}
