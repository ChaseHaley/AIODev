package markdown_test

import "aio:markdown"
import "core:strings"
import "core:testing"

@(private = "file")
selection_buffer :: proc(t: ^testing.T, text: string) -> markdown.Edit_Buffer {
	b: markdown.Edit_Buffer
	testing.expect(t, markdown.edit_buffer_init(&b, text))
	return b
}

@(private = "file")
word_at :: proc(t: ^testing.T, text: string, at: int) -> string {
	b := selection_buffer(t, text)
	defer markdown.edit_buffer_destroy(&b)
	from, to := markdown.edit_word_at(&b, at)
	return text[from:to]
}

@(test)
a_word_is_the_run_of_word_characters_the_caret_touches :: proc(t: ^testing.T) {
	testing.expect_value(t, word_at(t, "foo bar", 1), "foo")
	// The edge between a word and a space takes the word, whichever side of it the caret is on.
	testing.expect_value(t, word_at(t, "foo bar", 3), "foo")
	testing.expect_value(t, word_at(t, "foo bar", 4), "bar")
	testing.expect_value(t, word_at(t, "foo bar", 7), "bar")
	testing.expect_value(t, word_at(t, "foo_bar9 x", 2), "foo_bar9")
}

@(test)
punctuation_and_spaces_select_their_own_run :: proc(t: ^testing.T) {
	testing.expect_value(t, word_at(t, "a,.. b", 2), ",..")
	testing.expect_value(t, word_at(t, "a,.. b", 4), ",..")
	testing.expect_value(t, word_at(t, "a   b", 2), "   ")
	testing.expect_value(t, word_at(t, "tab\t\tend", 4), "\t\t")
	testing.expect_value(t, word_at(t, "x  ", 3), "  ")
}

@(test)
words_follow_unicode_letters_and_other_marks :: proc(t: ^testing.T) {
	text := "héllo wörld 日本語 😀😀 end"
	testing.expect_value(t, word_at(t, text, strings.index(text, "llo")), "héllo")
	testing.expect_value(t, word_at(t, text, strings.index(text, "rld")), "wörld")
	testing.expect_value(t, word_at(t, text, strings.index(text, "本")), "日本語")
	// Emoji are neither letters nor digits, so a run of them is one run of marks.
	testing.expect_value(t, word_at(t, text, strings.index(text, "😀") + 4), "😀😀")
}

@(test)
a_word_stops_at_the_line_ending_and_an_empty_line_selects_nothing :: proc(t: ^testing.T) {
	text := "one\r\ntwo\n\nthree"
	testing.expect_value(t, word_at(t, text, 3), "one")
	// Between the CR and the LF is no place for a caret: it lands before the pair.
	testing.expect_value(t, word_at(t, text, 4), "one")
	testing.expect_value(t, word_at(t, text, 5), "two")
	b := selection_buffer(t, text)
	defer markdown.edit_buffer_destroy(&b)
	empty := strings.index(text, "\n\n") + 1
	from, to := markdown.edit_word_at(&b, empty)
	testing.expect_value(t, from, empty)
	testing.expect_value(t, to, empty)
}

@(test)
no_word_reaches_into_the_byte_order_mark :: proc(t: ^testing.T) {
	b := selection_buffer(t, "\xEF\xBB\xBFfoo bar")
	defer markdown.edit_buffer_destroy(&b)
	from, to := markdown.edit_word_at(&b, 0)
	testing.expect_value(t, from, 3)
	testing.expect_value(t, to, 6)
	from, to = markdown.edit_line_at(&b, 1)
	testing.expect_value(t, from, 3)
	testing.expect_value(t, to, 10)
}

@(test)
a_line_selects_with_its_ending :: proc(t: ^testing.T) {
	text := "one\r\ntwo\nthree"
	b := selection_buffer(t, text)
	defer markdown.edit_buffer_destroy(&b)
	from, to := markdown.edit_line_at(&b, 1)
	testing.expect_value(t, text[from:to], "one\r\n")
	from, to = markdown.edit_line_at(&b, 4)
	testing.expect_value(t, text[from:to], "one\r\n")
	from, to = markdown.edit_line_at(&b, 6)
	testing.expect_value(t, text[from:to], "two\n")
	from, to = markdown.edit_line_at(&b, len(text))
	testing.expect_value(t, text[from:to], "three")
}

@(private = "file")
dragged :: proc(t: ^testing.T, text: string, origin: string, unit: markdown.Edit_Unit, at: int) -> (anchor, caret: int) {
	b := selection_buffer(t, text)
	defer markdown.edit_buffer_destroy(&b)
	from := strings.index(text, origin)
	markdown.edit_select_unit(&b, from, from + len(origin), unit, at)
	return b.anchor, b.caret
}

@(test)
dragging_after_a_double_click_grows_by_whole_words_and_keeps_the_first :: proc(t: ^testing.T) {
	text := "alpha beta gamma"
	anchor, caret := dragged(t, text, "beta", .Word, 13)
	testing.expect_value(t, anchor, 6)
	testing.expect_value(t, caret, 16)
	anchor, caret = dragged(t, text, "beta", .Word, 2)
	testing.expect_value(t, anchor, 10)
	testing.expect_value(t, caret, 0)
	// Back inside the first word the selection is that word again.
	anchor, caret = dragged(t, text, "beta", .Word, 8)
	testing.expect_value(t, anchor, 6)
	testing.expect_value(t, caret, 10)
}

@(test)
dragging_after_a_triple_click_grows_by_whole_lines :: proc(t: ^testing.T) {
	text := "a\nb\nc"
	anchor, caret := dragged(t, text, "b\n", .Line, 0)
	testing.expect_value(t, anchor, 4)
	testing.expect_value(t, caret, 0)
	anchor, caret = dragged(t, text, "b\n", .Line, 4)
	testing.expect_value(t, anchor, 2)
	testing.expect_value(t, caret, 5)
}

@(test)
home_goes_to_the_first_character_and_back_and_to_the_row_before_both :: proc(t: ^testing.T) {
	b := selection_buffer(t, "  indented text\nnext")
	defer markdown.edit_buffer_destroy(&b)
	markdown.edit_move(&b, 9)
	testing.expect_value(t, markdown.edit_home_target(&b, 0), 2)
	markdown.edit_move(&b, 2)
	testing.expect_value(t, markdown.edit_home_target(&b, 0), 0)
	markdown.edit_move(&b, 0)
	testing.expect_value(t, markdown.edit_home_target(&b, 0), 2)
	// On a soft-wrapped line the row's own start comes first; from there the line's rules apply.
	markdown.edit_move(&b, 12)
	testing.expect_value(t, markdown.edit_home_target(&b, 10), 10)
	markdown.edit_move(&b, 10)
	testing.expect_value(t, markdown.edit_home_target(&b, 10), 2)
	blank := selection_buffer(t, "   \nx")
	defer markdown.edit_buffer_destroy(&blank)
	markdown.edit_move(&blank, 3)
	testing.expect_value(t, markdown.edit_home_target(&blank, 0), 0)
}

@(test)
end_goes_to_the_row_end_before_the_line_end :: proc(t: ^testing.T) {
	b := selection_buffer(t, "aaaa bbbb\r\nnext")
	defer markdown.edit_buffer_destroy(&b)
	markdown.edit_move(&b, 1)
	testing.expect_value(t, markdown.edit_end_target(&b, 4), 4)
	markdown.edit_move(&b, 4)
	testing.expect_value(t, markdown.edit_end_target(&b, 4), 9)
	markdown.edit_move(&b, 6)
	testing.expect_value(t, markdown.edit_end_target(&b, 9), 9)
}
