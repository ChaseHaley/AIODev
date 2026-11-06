package markdown_test

import "aio:line_match"
import "aio:markdown"
import "core:testing"
import "core:time"

@(private = "file")
Fixture :: struct {
	doc:    markdown.Document,
	search: markdown.Search,
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
	markdown.search_destroy(&f.search)
	markdown.document_destroy(&f.doc)
}

@(private = "file")
settle :: proc(f: ^Fixture) {
	for markdown.search_pending(&f.search) {markdown.search_update(&f.search, &f.doc, time.Second)}
}

@(private = "file")
found :: proc(t: ^testing.T, f: ^Fixture, source, needle: string, options: line_match.Options = {}) -> int {
	if !testing.expect(t, markdown.parse(source, &f.doc)) {return -1}
	markdown.search_set(&f.search, needle, options)
	settle(f)
	return len(f.search.matches)
}

@(private = "file")
matched :: proc(f: ^Fixture, index: int) -> string {
	match := f.search.matches[index]
	return string(f.doc.text[match.start:match.end])
}

@(test)
literal_text_ignores_ascii_case_by_default :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "Target, TARGET and target\n", "tArGeT"), 3)
	testing.expect_value(t, matched(&f, 1), "TARGET")
}

@(test)
case_sensitive_text_matches_exactly :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "Target, TARGET and target\n", "target", {case_sensitive = true}), 1)
}

@(test)
folding_leaves_other_scripts_alone :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "Ünder ünder under\n", "ÜNDER"), 1)
	testing.expect_value(t, matched(&f, 0), "Ünder")
}

@(test)
matches_are_taken_left_to_right_without_overlap :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "aaaaa\n", "aa"), 2)
}

@(test)
expressions_anchor_to_each_line :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	source := "line one\n\n```\nline two\nline three\n```\n"
	testing.expect_value(t, found(t, &f, source, `^line t`, {regex = true}), 2)
	markdown.search_set(&f.search, `two$`, {regex = true})
	settle(&f)
	testing.expect_value(t, matched(&f, 0), "two")
}

@(test)
empty_expression_matches_do_not_stop_the_line :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "baab\n", "a*", {regex = true}), 1)
	testing.expect_value(t, matched(&f, 0), "aa")
}

@(test)
an_invalid_expression_stays_active_and_finds_nothing :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "text (here)\n", "(", {regex = true}), 0)
	testing.expect(t, f.search.active && f.search.invalid)
	testing.expect(t, !markdown.search_pending(&f.search))
	testing.expect(t, !markdown.search_select(&f.search, true))
}

@(test)
matches_read_through_inline_styles_and_soft_breaks_but_not_hard_ones :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "one **bold** two\nthree\\\nfour\n", "one bold two three"), 1)
	markdown.search_set(&f.search, "three four")
	settle(&f)
	testing.expect_value(t, len(f.search.matches), 0)
}

@(test)
list_markers_are_found_as_they_read :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "1. Export\n2. Import\n", "2. Imp"), 1)
}

@(test)
stepping_starts_at_the_end_going_up_and_wraps_both_ways :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "a\n\na\n\na\n", "a"), 3)
	testing.expect_value(t, f.search.selected, -1)
	for expected in ([?]int{2, 1, 0, 2}) {
		testing.expect(t, markdown.search_select(&f.search, true))
		testing.expect_value(t, f.search.selected, expected)
	}
	testing.expect(t, markdown.search_select(&f.search, false))
	testing.expect_value(t, f.search.selected, 0)
}

@(test)
a_small_budget_finishes_over_several_steps_with_the_same_matches :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	if !testing.expect(t, markdown.parse("a\n\nb\n\na\n\nb\n\na\n", &f.doc)) {return}
	markdown.search_set(&f.search, "a")
	steps := 0
	for markdown.search_pending(&f.search) {
		markdown.search_update(&f.search, &f.doc, 0)
		steps += 1
	}
	testing.expect(t, steps > 1)
	testing.expect_value(t, len(f.search.matches), 3)
}

@(test)
a_reload_keeps_the_selection_on_the_same_or_next_match :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "aa\n\nab\n\nac\n", "a"), 4)
	testing.expect(t, markdown.search_select(&f.search, false))
	testing.expect(t, markdown.search_select(&f.search, false))
	testing.expect(t, markdown.search_select(&f.search, false))
	testing.expect_value(t, f.search.selected, 2)
	markdown.document_destroy(&f.doc)
	if !testing.expect(t, markdown.parse("aa\n\nxx\n\nac\n", &f.doc)) {return}
	markdown.search_restart(&f.search)
	testing.expect(t, markdown.search_pending(&f.search))
	settle(&f)
	testing.expect_value(t, len(f.search.matches), 3)
	testing.expect_value(t, f.search.selected, 2)
	testing.expect_value(t, matched(&f, f.search.selected), "a")
	markdown.document_destroy(&f.doc)
	if !testing.expect(t, markdown.parse("aa\n", &f.doc)) {return}
	markdown.search_restart(&f.search)
	settle(&f)
	testing.expect_value(t, f.search.selected, 1)
	markdown.document_destroy(&f.doc)
	if !testing.expect(t, markdown.parse("none\n", &f.doc)) {return}
	markdown.search_restart(&f.search)
	settle(&f)
	testing.expect_value(t, f.search.selected, -1)
}

@(test)
an_empty_needle_ends_the_search :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "text\n", "text"), 1)
	markdown.search_set(&f.search, "")
	testing.expect(t, !f.search.active)
	testing.expect_value(t, len(f.search.matches), 0)
	testing.expect(t, !markdown.search_pending(&f.search))
}
