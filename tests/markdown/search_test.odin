package markdown_test

import "aio:line_match"
import "aio:markdown"
import "base:runtime"
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
	testing.expect_value(t, f.search.phase, markdown.Search_Phase.Invalid)
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
stepping_starts_at_either_end_and_wraps_both_ways :: proc(t: ^testing.T) {
	f: Fixture
	defer fixture_destroy(&f)
	testing.expect_value(t, found(t, &f, "a\n\na\n\na\n", "a"), 3)
	testing.expect_value(t, f.search.selected, -1)
	for expected in ([?]int{0, 1, 2, 0}) {
		testing.expect(t, markdown.search_select(&f.search, false))
		testing.expect_value(t, f.search.selected, expected)
	}
	testing.expect(t, markdown.search_select(&f.search, true))
	testing.expect_value(t, f.search.selected, 2)
	markdown.search_set(&f.search, "a")
	settle(&f)
	testing.expect(t, markdown.search_select(&f.search, true))
	testing.expect_value(t, f.search.selected, 2)
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
	testing.expect_value(t, f.search.phase, markdown.Search_Phase.Off)
	testing.expect_value(t, len(f.search.matches), 0)
	testing.expect(t, !markdown.search_pending(&f.search))
}

@(private = "file")
Fail_Allocator :: struct {
	backing:   runtime.Allocator,
	remaining: int,
}

@(private = "file")
fail_allocation :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]u8, runtime.Allocator_Error) {
	a := (^Fail_Allocator)(data)
	if size > 0 && (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		if a.remaining == 0 {return nil, .Out_Of_Memory}
		a.remaining -= 1
	}
	return a.backing.procedure(a.backing.data, mode, size, alignment, old_memory, old_size, location)
}

// Running out of memory ends the search in a state the find bar reports, rather than switching the search
// off or presenting the matches stored so far as all of them.
@(test)
running_out_of_memory_fails_the_search :: proc(t: ^testing.T) {
	context.logger = {}
	f: Fixture
	defer fixture_destroy(&f)
	if !testing.expect(t, markdown.parse("a\n\na\n", &f.doc)) {return}
	a := Fail_Allocator{context.allocator, 0}
	context.allocator = {fail_allocation, &a}

	// The needle cannot be copied.
	markdown.search_set(&f.search, "a")
	testing.expect_value(t, f.search.phase, markdown.Search_Phase.Failed)
	testing.expect(t, !markdown.search_pending(&f.search))
	testing.expect(t, !markdown.search_select(&f.search, false))

	// The pass cannot store a match.
	a.remaining = -1
	markdown.search_set(&f.search, "a")
	a.remaining = 0
	settle(&f)
	testing.expect_value(t, f.search.phase, markdown.Search_Phase.Failed)
	testing.expect_value(t, len(f.search.matches), 0)
	testing.expect(t, !markdown.search_select(&f.search, false))

	// The next needle searches again.
	a.remaining = -1
	markdown.search_set(&f.search, "a")
	settle(&f)
	testing.expect_value(t, f.search.phase, markdown.Search_Phase.Complete)
	testing.expect_value(t, len(f.search.matches), 2)
}
