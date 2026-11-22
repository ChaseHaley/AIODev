package markdown_test

import "aio:markdown"
import "core:strings"
import "core:testing"
import "cosmos:textedit"

@(private = "file")
Live_Fixture :: struct {
	live: markdown.Live,
	doc:  markdown.Document,
}

@(private = "file")
live_fixture_destroy :: proc(f: ^Live_Fixture) {
	markdown.live_destroy(&f.live)
	markdown.document_destroy(&f.doc)
}

// The text each block shows, one per line.
@(private = "file")
shown_lines :: proc(doc: ^markdown.Document) -> string {
	out := strings.builder_make(context.temp_allocator)
	for block, index in doc.blocks {
		if index > 0 {strings.write_byte(&out, '\n')}
		for span in doc.spans[block.first_span:][:block.span_count] {
			strings.write_string(&out, string(doc.text[span.start:span.end]))
		}
	}
	return strings.to_string(out)
}

@(private = "file")
SOURCE :: "# Title\n\nSome **bold** and [a link](x.md).\n- [ ] task\n- item\n\n```odin\ncode here\n```\n"

@(test)
only_the_caret_line_shows_its_markup :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	caret := strings.index(SOURCE, "bold")
	testing.expect(t, markdown.live_build(&f.live, SOURCE, caret, caret, &f.doc))
	testing.expect(t, f.doc.live)
	testing.expect_value(
		t,
		shown_lines(&f.doc),
		"Title\n\nSome **bold** and [a link](x.md).\ntask\nitem\n\nodin\ncode here\n\n",
	)
	title := f.doc.blocks[0]
	testing.expect_value(t, title.kind, markdown.Block_Kind.Heading)
	testing.expect_value(t, title.level, 1)
	task := f.doc.blocks[3]
	testing.expect_value(t, task.task, markdown.Task.Open)
	source := SOURCE
	testing.expect_value(t, source[task.task_source], ' ')
	testing.expect_value(t, f.doc.blocks[7].kind, markdown.Block_Kind.Code)
	// The caret's line keeps its text styled and its markup muted.
	for span in f.doc.spans {
		text := string(f.doc.text[span.start:span.end])
		if text == "**" {testing.expect(t, .Markup in span.style)}
		if text == "bold" && span.source == caret {testing.expect(t, .Strong in span.style)}
	}
}

@(test)
moving_the_caret_reveals_its_new_line_instead :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	caret := strings.index(SOURCE, "Title")
	testing.expect(t, markdown.live_build(&f.live, SOURCE, caret, caret, &f.doc))
	lines := strings.split(shown_lines(&f.doc), "\n", context.temp_allocator)
	testing.expect_value(t, lines[0], "# Title")
	testing.expect_value(t, lines[2], "Some bold and a link.")
}

@(test)
offsets_on_a_source_line_map_exactly_and_hidden_markup_maps_to_the_next_text :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	line := strings.index(SOURCE, "Some")
	testing.expect(t, markdown.live_build(&f.live, SOURCE, line, line, &f.doc))
	for source in line ..< line + len("Some **bold** and [a link](x.md).") {
		testing.expect_value(t, markdown.live_source(&f.doc, markdown.live_display(&f.doc, source)), source)
	}
	// On the rendered heading, the hidden "# " leads to the heading's text.
	display := markdown.live_display(&f.doc, 0)
	testing.expect_value(t, markdown.live_source(&f.doc, display), strings.index(SOURCE, "Title"))
}

@(test)
tables_and_frontmatter_render_whole_until_the_caret_enters :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	source := "---\ntitle: Note\n---\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter"
	end := len(source)
	testing.expect(t, markdown.live_build(&f.live, source, end, end, &f.doc))
	testing.expect_value(t, len(f.doc.tables), 2)
	testing.expect(t, f.doc.tables[0].properties)
	testing.expect_value(t, shown_lines(&f.doc), "title\nNote\na\nb\n1\n2\n\nafter")
	inside := strings.index(source, "| 1")
	testing.expect(t, markdown.live_build(&f.live, source, inside, inside, &f.doc))
	testing.expect_value(t, len(f.doc.tables), 1)
	testing.expect_value(t, shown_lines(&f.doc), "title\nNote\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter")
	testing.expect(t, markdown.live_build(&f.live, source, 5, 5, &f.doc))
	testing.expect(t, strings.has_prefix(shown_lines(&f.doc), "---\ntitle: Note\n---\na\nb"))
}

@(test)
items_without_text_still_show_their_marker :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	source := "- one\n\t- [x] \n- \n\nend"
	testing.expect(t, markdown.live_build(&f.live, source, len(source), len(source), &f.doc))
	nested := f.doc.blocks[1]
	testing.expect_value(t, nested.task, markdown.Task.Done)
	testing.expect_value(t, nested.list_depth, 2)
	testing.expect_value(t, source[nested.task_source], 'x')
	bare := f.doc.blocks[2]
	testing.expect_value(t, string(f.doc.text[bare.marker_start:bare.marker_end]), "•")
	testing.expect_value(t, bare.list_depth, 1)
}

@(private = "file")
buffer_of :: proc(t: ^testing.T, text: string, caret: int) -> textedit.Buffer {
	b: textedit.Buffer
	testing.expect(t, textedit.init(&b, text))
	textedit.move(&b, caret)
	return b
}

@(test)
typing_undoes_a_word_at_a_time_and_redoes :: proc(t: ^testing.T) {
	b := buffer_of(t, "", 0)
	defer textedit.destroy(&b)
	for c in ([?]string{"a", "b", " ", "c", "d"}) {testing.expect(t, textedit.insert(&b, c, true))}
	testing.expect_value(t, textedit.to_string(&b), "ab cd")
	testing.expect(t, textedit.undo(&b))
	testing.expect_value(t, textedit.to_string(&b), "ab")
	testing.expect(t, textedit.undo(&b))
	testing.expect_value(t, textedit.to_string(&b), "")
	testing.expect(t, textedit.redo(&b))
	testing.expect_value(t, textedit.to_string(&b), "ab")
	testing.expect_value(t, b.caret, 2)
}

@(test)
backspace_runs_join_and_crlf_is_one_character :: proc(t: ^testing.T) {
	b := buffer_of(t, "one\r\ntwo", 8)
	defer textedit.destroy(&b)
	for _ in 0 ..< 4 {testing.expect(t, textedit.erase(&b, false, false))}
	testing.expect_value(t, textedit.to_string(&b), "one")
	testing.expect(t, textedit.undo(&b))
	testing.expect_value(t, textedit.to_string(&b), "one\r\ntwo")
	testing.expect_value(t, textedit.clamp_offset(&b, 4), 3)
}

@(test)
enter_continues_lists_and_quotes_and_ends_an_empty_item :: proc(t: ^testing.T) {
	cases := [?]struct {
		before, after: string,
	} {
		{"- [x] done", "- [x] done\n- [ ] "},
		{"  3) third", "  3) third\n  4) "},
		{"> quoted", "> quoted\n> "},
		{"- ", ""},
		{"plain", "plain\n"},
	}
	for c in cases {
		b := buffer_of(t, c.before, len(c.before))
		testing.expect(t, markdown.edit_newline(&b))
		testing.expect_value(t, textedit.to_string(&b), c.after)
		testing.expect_value(t, b.caret, len(c.after))
		textedit.destroy(&b)
	}
	crlf := buffer_of(t, "a\r\n- b", 6)
	defer textedit.destroy(&crlf)
	testing.expect(t, markdown.edit_newline(&crlf))
	testing.expect_value(t, textedit.to_string(&crlf), "a\r\n- b\r\n- ")
}

@(test)
tab_indents_selected_lines_and_shift_tab_outdents :: proc(t: ^testing.T) {
	b := buffer_of(t, "- a\n- b\nc", 0)
	defer textedit.destroy(&b)
	textedit.move(&b, 6, true)
	testing.expect(t, markdown.edit_indent(&b, false))
	testing.expect_value(t, textedit.to_string(&b), "\t- a\n\t- b\nc")
	testing.expect_value(t, textedit.selected_text(&b), "\t- a\n\t- ")
	testing.expect(t, markdown.edit_indent(&b, true))
	testing.expect_value(t, textedit.to_string(&b), "- a\n- b\nc")
	plain := buffer_of(t, "word", 4)
	defer textedit.destroy(&plain)
	testing.expect(t, markdown.edit_indent(&plain, false))
	testing.expect_value(t, textedit.to_string(&plain), "word\t")
}

@(test)
task_marks_flip_in_place :: proc(t: ^testing.T) {
	text := transmute([]u8)strings.clone("- [ ] a\n- [X] b", context.temp_allocator)
	testing.expect(t, markdown.task_mark_flip(text, 3))
	testing.expect(t, markdown.task_mark_flip(text, 11))
	testing.expect_value(t, string(text), "- [x] a\n- [ ] b")
	testing.expect(t, !markdown.task_mark_flip(text, 0))
}

// The lines of one paragraph with soft line breaks between them show as one block, reading's way, each break
// a space; a hard break, a blank line or another block ends it.
@(test)
soft_breaks_join_a_paragraphs_lines_and_hard_breaks_do_not :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	source := "first line\nsecond *line*\nthird\n\nhard  \nbreak\\\nagain\n\n- item one\n  continues\n- next\n\n> quoted\n> on\n"
	end := len(source)
	testing.expect(t, markdown.live_build(&f.live, source, end, end, &f.doc))
	testing.expect_value(
		t,
		strings.trim_right(shown_lines(&f.doc), "\n"),
		"first line second line third\n\nhard\nbreak\nagain\n\nitem one continues\nnext\n\nquoted on",
	)
	testing.expect_value(t, f.doc.blocks[0].source_start, 0)
	testing.expect_value(t, f.doc.blocks[0].source_end, strings.index(source, "\n\nhard"))
}

@(test)
soft_break_spaces_map_to_the_newline_and_back :: proc(t: ^testing.T) {
	for newline in ([?]string{"\n", "\r\n"}) {
		f: Live_Fixture
		defer live_fixture_destroy(&f)
		source := strings.concatenate({"alpha beta", newline, "gamma delta", newline, newline, "end"}, context.temp_allocator)
		testing.expect(t, markdown.live_build(&f.live, source, len(source), len(source), &f.doc))
		testing.expect_value(t, string(f.doc.text[:f.doc.blocks[0].marker_start + len("alpha beta gamma delta")]), "alpha beta gamma delta")
		wrap := strings.index(source, newline)
		after := wrap + len(newline)
		// The caret before the break is at the first line's end; after it, at the second line's start.
		before_display := markdown.live_display(&f.doc, wrap)
		after_display := markdown.live_display(&f.doc, after)
		testing.expect_value(t, after_display, before_display + 1)
		testing.expect_value(t, markdown.live_source(&f.doc, before_display), wrap)
		testing.expect_value(t, markdown.live_source(&f.doc, after_display), after)
		// Every character of both lines maps exactly.
		for offset in 0 ..< wrap {
			testing.expect_value(t, markdown.live_source(&f.doc, markdown.live_display(&f.doc, offset)), offset)
		}
		for offset in after ..< after + len("gamma delta") {
			testing.expect_value(t, markdown.live_source(&f.doc, markdown.live_display(&f.doc, offset)), offset)
		}
	}
}

// Whether the caret or the selection touches a line of the group shows the whole group as source, still as
// one paragraph: the text does not move as the caret comes and goes.
@(test)
a_revealed_group_shows_its_source_as_one_paragraph :: proc(t: ^testing.T) {
	f: Live_Fixture
	defer live_fixture_destroy(&f)
	source := "one **two**\nthree\n\nafter"
	caret := strings.index(source, "three")
	testing.expect(t, markdown.live_build(&f.live, source, caret, caret, &f.doc))
	testing.expect_value(t, shown_lines(&f.doc), "one **two** three\n\nafter")
	testing.expect_value(t, len(f.doc.blocks), 3)
	for span in f.doc.spans {
		if string(f.doc.text[span.start:span.end]) == "**" {testing.expect(t, .Markup in span.style)}
	}
	testing.expect(t, markdown.live_build(&f.live, source, len(source), len(source), &f.doc))
	testing.expect_value(t, shown_lines(&f.doc), "one two three\n\nafter")
}
