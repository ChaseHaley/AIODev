package markdown_test

import "aio:markdown"
import "core:strings"
import "core:testing"

@(private)
span_text :: proc(doc: ^markdown.Document, span: markdown.Span) -> string {
	return string(doc.text[span.start:span.end])
}

@(private)
block_text :: proc(doc: ^markdown.Document, block: markdown.Block) -> string {
	if block.span_count == 0 {return ""}
	first := doc.spans[block.first_span]
	last := doc.spans[block.first_span + block.span_count - 1]
	return string(doc.text[first.start:last.end])
}

@(test)
headings_keep_their_level_without_the_syntax :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("# One\n\n### Three\n", &doc))
	testing.expect_value(t, len(doc.blocks), 2)
	testing.expect_value(t, doc.blocks[0].kind, markdown.Block_Kind.Heading)
	testing.expect_value(t, doc.blocks[0].level, 1)
	testing.expect_value(t, doc.blocks[1].level, 3)
	testing.expect_value(t, block_text(&doc, doc.blocks[1]), "Three")
}

@(test)
inline_styles_nest_and_split_into_spans :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("plain **bold *both*** `code` ~~gone~~", &doc))
	styles := map[string]markdown.Style{}
	defer delete(styles)
	for span in doc.spans {styles[span_text(&doc, span)] = span.style}
	testing.expect_value(t, styles["plain "], markdown.Style{})
	testing.expect_value(t, styles["bold "], markdown.Style{.Strong})
	testing.expect_value(t, styles["both"], markdown.Style{.Strong, .Emphasis})
	testing.expect_value(t, styles["code"], markdown.Style{.Code})
	testing.expect_value(t, styles["gone"], markdown.Style{.Strike})
}

@(test)
soft_breaks_read_as_spaces_and_hard_breaks_stay :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("one\r\ntwo  \r\nthree", &doc))
	testing.expect_value(t, string(doc.text[:]), "one two\nthree")
	testing.expect_value(t, len(doc.blocks), 1)
}

@(test)
code_blocks_keep_lines_and_drop_the_last_newline :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("```odin\na :: 1\n  b :: 2\n```\n\nafter", &doc))
	testing.expect_value(t, doc.blocks[0].kind, markdown.Block_Kind.Code)
	testing.expect_value(t, block_text(&doc, doc.blocks[0]), "a :: 1\n  b :: 2")
	testing.expect_value(t, string(doc.text[:]), "a :: 1\n  b :: 2\n\nafter")
}

@(test)
tight_lists_carry_markers_and_depth :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("- one\n  - nested\n- two\n\n3. three\n4. four\n", &doc))
	testing.expect_value(t, len(doc.blocks), 5)
	testing.expect_value(t, doc.blocks[0].list_depth, 1)
	testing.expect_value(t, doc.blocks[1].list_depth, 2)
	testing.expect_value(t, block_text(&doc, doc.blocks[1]), "nested")
	testing.expect(t, !doc.blocks[0].tight)
	testing.expect(t, doc.blocks[1].tight)
	testing.expect(t, doc.blocks[2].tight)
	testing.expect(t, !doc.blocks[3].tight)
	marker := doc.blocks[3]
	testing.expect_value(t, string(doc.text[marker.marker_start:marker.marker_end]), "3.")
	marker = doc.blocks[4]
	testing.expect_value(t, string(doc.text[marker.marker_start:marker.marker_end]), "4.")
	testing.expect_value(t, string(doc.text[:]), "• one\n• nested\n• two\n\n3. three\n4. four")
}

@(test)
loose_list_items_are_not_tight_and_only_first_block_has_the_marker :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("- one\n\n  more\n\n- two\n", &doc))
	testing.expect_value(t, len(doc.blocks), 3)
	testing.expect(t, !doc.blocks[0].tight)
	testing.expect(t, doc.blocks[0].marker_end > doc.blocks[0].marker_start)
	testing.expect_value(t, doc.blocks[1].marker_end, 0)
	testing.expect(t, doc.blocks[2].marker_end > doc.blocks[2].marker_start)
}

@(test)
empty_list_items_still_show_a_marker :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("-\n- two\n", &doc))
	testing.expect_value(t, len(doc.blocks), 2)
	testing.expect(t, doc.blocks[0].marker_end > doc.blocks[0].marker_start)
}

@(test)
task_lists_mark_their_state :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("- [ ] open\n- [x] done\n", &doc))
	testing.expect_value(t, string(doc.text[:]), "☐ open\n☑ done")
	if !testing.expect_value(t, len(doc.blocks), 2) {return}
	testing.expect_value(t, doc.blocks[0].task, markdown.Task.Open)
	testing.expect_value(t, doc.blocks[1].task, markdown.Task.Done)
}

@(test)
quotes_add_depth_to_what_they_hold :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("> outer\n>\n> > inner\n", &doc))
	testing.expect_value(t, doc.blocks[0].quote_depth, 1)
	testing.expect_value(t, doc.blocks[1].quote_depth, 2)
}

@(test)
tables_flatten_to_cells_with_position_and_alignment :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	source := "| a | b | c |\n|:--|:-:|--:|\n| 1 | **2** | 3 |\n"
	testing.expect(t, markdown.parse(source, &doc))
	testing.expect_value(t, len(doc.tables), 1)
	testing.expect_value(t, doc.tables[0].columns, 3)
	testing.expect_value(t, doc.tables[0].rows, 2)
	testing.expect_value(t, len(doc.blocks), 6)
	head, middle := doc.blocks[1], doc.blocks[4]
	testing.expect(t, head.header)
	testing.expect_value(t, head.align, markdown.Align.Center)
	testing.expect_value(t, doc.blocks[2].align, markdown.Align.Right)
	testing.expect(t, !middle.header)
	testing.expect_value(t, middle.row, 1)
	testing.expect_value(t, middle.column, 1)
	testing.expect_value(t, string(doc.text[:]), "a\tb\tc\n1\t2\t3")
}

@(test)
links_keep_their_target_and_decoded_entities :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("[here](https://a.example/?x=1&amp;y=2) and https://b.example", &doc))
	testing.expect_value(t, len(doc.links), 2)
	testing.expect_value(t, doc.links[0], "https://a.example/?x=1&y=2")
	testing.expect_value(t, doc.links[1], "https://b.example")
	testing.expect_value(t, doc.spans[0].link, 0)
	testing.expect(t, .Link in doc.spans[0].style)
	testing.expect_value(t, doc.spans[1].link, markdown.NO_LINK)
}

@(test)
images_show_their_description_and_open_their_source :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("![a chart](chart.png) ![](bare.png)", &doc))
	testing.expect_value(t, string(doc.text[:]), "a chart bare.png")
	testing.expect_value(t, doc.links[0], "chart.png")
	testing.expect_value(t, doc.spans[0].link, 0)
	testing.expect_value(t, doc.links[1], "bare.png")
}

@(test)
raw_html_stays_literal_text :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("<script>alert(1)</script>\n\nwith <b>tag</b>\n", &doc))
	testing.expect_value(t, string(doc.text[:]), "<script>alert(1)</script>\n\nwith <b>tag</b>")
}

@(test)
entities_decode_and_unknown_ones_stay_literal :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("&amp; &#65; &#x42; &notarealentity;", &doc))
	testing.expect_value(t, string(doc.text[:]), "& A B &notarealentity;")
}

@(test)
a_byte_order_mark_is_not_content :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("\xef\xbb\xbf# Title", &doc))
	testing.expect_value(t, doc.blocks[0].kind, markdown.Block_Kind.Heading)
}

@(test)
rules_and_empty_documents_parse :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("", &doc))
	testing.expect_value(t, len(doc.blocks), 0)
	markdown.document_destroy(&doc)
	testing.expect(t, markdown.parse("above\n\n---\n\nbelow", &doc))
	testing.expect_value(t, doc.blocks[1].kind, markdown.Block_Kind.Rule)
}

@(test)
pathological_nesting_and_invalid_bytes_do_not_fail :: proc(t: ^testing.T) {
	doc: markdown.Document
	defer markdown.document_destroy(&doc)
	source := strings.concatenate(
		{strings.repeat("> ", 2000, context.temp_allocator), strings.repeat("[", 5000, context.temp_allocator), "\xff\xfe"},
		context.temp_allocator,
	)
	testing.expect(t, markdown.parse(source, &doc))
	testing.expect_value(t, doc.blocks[0].quote_depth, 2000)
}
