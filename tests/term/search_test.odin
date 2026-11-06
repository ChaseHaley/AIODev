package term_test

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"
import "aio:ghostty"
import "aio:term"

LINES_200 :: "cmd.exe /d /c \"for /l %i in (1,1,200) do @echo LINE_%i\""

settle_search :: proc(t: ^testing.T, s: ^term.Session) -> term.Search_Summary {
	started := time.tick_now()
	for term.search_pending(s) && time.tick_since(started) < 10 * time.Second {
		term.search_update(s)
	}
	testing.expect(t, !term.search_pending(s))
	return term.search_summary(s)
}

selected_highlight :: proc(highlights: []term.Highlight) -> (term.Highlight, bool) {
	for h in highlights {
		if h.selected {
			return h, true
		}
	}
	return {}, false
}

viewport_up :: proc(s: ^term.Session) -> u64 {
	bar, _ := term.scrollbar(s)
	return bar.total - (bar.offset + bar.len)
}

@(test)
search_walks_scrollback_matches :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, LINES_200, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, exited, "exit") || !await(t, s, shows, "LINE_200") {
		return
	}
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), ghostty.Result.Success) {
		return
	}
	defer ghostty.render_state_free(state)
	highlights := make([dynamic]term.Highlight)
	defer delete(highlights)

	testing.expect_value(t, term.search_summary(s), term.Search_Summary{selected = -1})
	testing.expect(t, !term.search_select(s, true))
	term.search_set_needle(s, "line_1")
	summary := settle_search(t, s)
	settled := term.Search_Summary{progress = .Complete, total = 111, selected = -1}
	testing.expect_value(t, summary, settled)
	term.search_set_needle(s, "77")
	summary = settle_search(t, s)
	testing.expect_value(t, summary.total, 2)

	testing.expect(t, term.search_select(s, true))
	testing.expect_value(t, term.search_summary(s).selected, 0)
	testing.expect_value(t, viewport_up(s), 0)
	testing.expect(t, term.capture(s, state, &highlights))
	testing.expect_value(t, len(highlights), 2)
	newest, found := selected_highlight(highlights[:])
	testing.expect(t, found)
	testing.expect_value(t, newest.first, 6)
	testing.expect_value(t, newest.last, 7)

	testing.expect(t, term.search_select(s, true))
	testing.expect_value(t, term.search_summary(s).selected, 1)
	testing.expect(t, viewport_up(s) > 0)
	testing.expect(t, term.capture(s, state, &highlights))
	oldest, oldest_found := selected_highlight(highlights[:])
	testing.expect(t, oldest_found)
	testing.expect_value(t, oldest.first, 5)
	testing.expect_value(t, oldest.last, 6)
	bar, _ := term.scrollbar(s)
	testing.expect_value(t, u64(oldest.row) + bar.offset, 76)

	testing.expect(t, term.search_select(s, true))
	testing.expect_value(t, term.search_summary(s).selected, 0)
	testing.expect(t, term.search_select(s, false))
	testing.expect_value(t, term.search_summary(s).selected, 1)

	term.search_set_needle(s, "")
	testing.expect_value(t, term.search_summary(s), term.Search_Summary{selected = -1})
	testing.expect(t, !term.search_pending(s))
	testing.expect(t, term.capture(s, state, &highlights))
	testing.expect_value(t, len(highlights), 0)
}

@(test)
search_matches_case_and_expressions :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, LINES_200, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, exited, "exit") || !await(t, s, shows, "LINE_200") {
		return
	}
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), ghostty.Result.Success) {
		return
	}
	defer ghostty.render_state_free(state)
	highlights := make([dynamic]term.Highlight)
	defer delete(highlights)
	exact := term.Search_Options{case_sensitive = true}
	pattern := term.Search_Options{regex = true}

	term.search_set_needle(s, "LINE_1", exact)
	testing.expect_value(t, settle_search(t, s).total, 111)
	term.search_set_needle(s, "line_1", exact)
	testing.expect_value(t, settle_search(t, s).total, 0)
	term.search_set_needle(s, `line_1\d$`, pattern)
	testing.expect_value(t, settle_search(t, s).total, 10)
	term.search_set_needle(s, `line_1\d$`, {case_sensitive = true, regex = true})
	testing.expect_value(t, settle_search(t, s).total, 0)
	term.search_set_needle(s, `LINE_[0-9][0-9][0-9]`, pattern)
	testing.expect_value(t, settle_search(t, s).total, 101)
	// Empty matches are skipped without stalling, and the scan still finds the non-empty ones.
	term.search_set_needle(s, "7*", pattern)
	testing.expect_value(t, settle_search(t, s).total, 38)

	term.search_set_needle(s, "(", pattern)
	summary := term.search_summary(s)
	testing.expect_value(t, summary.progress, term.Search_Progress.Invalid)
	testing.expect(t, !term.search_pending(s))
	testing.expect(t, !term.search_select(s, true))

	term.search_set_needle(s, "LINE_77$", pattern)
	testing.expect_value(t, settle_search(t, s).total, 1)
	testing.expect(t, term.search_select(s, true))
	testing.expect_value(t, term.search_summary(s).selected, 0)
	testing.expect(t, viewport_up(s) > 0)
	settle_search(t, s)
	testing.expect_value(t, term.search_summary(s).selected, 0)
	testing.expect(t, term.capture(s, state, &highlights))
	selected, found := selected_highlight(highlights[:])
	testing.expect(t, found)
	testing.expect_value(t, selected.first, 0)
	testing.expect_value(t, selected.last, 6)
	bar, _ := term.scrollbar(s)
	testing.expect_value(t, u64(selected.row) + bar.offset, 76)

	// Returning to the default mode hands the search back to libghostty.
	term.search_set_needle(s, "line_77")
	testing.expect_value(t, settle_search(t, s).total, 1)
	term.search_set_needle(s, "")
	testing.expect_value(t, term.search_summary(s), term.Search_Summary{selected = -1})
	testing.expect(t, term.capture(s, state, &highlights))
	testing.expect_value(t, len(highlights), 0)
}

// Running out of memory ends the search in a state the find bar reports, rather than switching the
// search off or presenting what a pass had read as the complete result.
@(test)
search_reports_out_of_memory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 60 * time.Second)
	context.logger = {}
	a := Failing_Allocator{context.allocator, -1}
	wakes: Wakes
	s, err := term.create(config(LINES_200), {on_wake, &wakes}, mem.Allocator{fail_allocation, &a})
	if !testing.expect_value(t, err, term.Error.None) {
		return
	}
	defer term.destroy(s)
	if !await(t, s, exited, "exit") || !await(t, s, shows, "LINE_200") {
		return
	}
	state: ghostty.Render_State
	if !testing.expect_value(t, ghostty.render_state_new(nil, &state), ghostty.Result.Success) {
		return
	}
	defer ghostty.render_state_free(state)
	highlights := make([dynamic]term.Highlight)
	defer delete(highlights)
	pattern := term.Search_Options{regex = true}
	failed := term.Search_Summary{progress = .Failed, selected = -1}

	// The needle cannot be copied.
	a.remaining = 0
	term.search_set_needle(s, "LINE_7", pattern)
	a.remaining = -1
	testing.expect_value(t, term.search_summary(s), failed)
	testing.expect(t, !term.search_pending(s))
	testing.expect(t, !term.search_select(s, true))

	// The first pass cannot keep the text it reads.
	term.search_set_needle(s, "LINE_7", pattern)
	a.remaining = 0
	term.search_update(s)
	a.remaining = -1
	testing.expect_value(t, term.search_summary(s), failed)
	testing.expect(t, !term.search_pending(s))
	testing.expect(t, term.capture(s, state, &highlights))
	testing.expect_value(t, len(highlights), 0)

	// The next needle searches again.
	term.search_set_needle(s, "LINE_7", pattern)
	summary := settle_search(t, s)
	testing.expect_value(t, summary.progress, term.Search_Progress.Complete)
	testing.expect(t, summary.total > 0)
}

@(test)
search_follows_new_output :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /q /k prompt $G", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, ">") {
		return
	}
	term.search_set_needle(s, "FRESH_OUTPUT")
	testing.expect_value(t, settle_search(t, s).total, 0)
	testing.expect(t, term.send_text(s, "echo FRESH_%OS%_OUTPUT\r"))
	if !await(t, s, shows, "FRESH_Windows_NT_OUTPUT") {
		return
	}
	term.search_set_needle(s, "fresh_windows_nt_output")
	testing.expect_value(t, settle_search(t, s).total, 1)
	testing.expect(t, term.send_text(s, "echo FRESH_%OS%_OUTPUT\r"))
	deadline := time.tick_now()
	for time.tick_since(deadline) < 10 * time.Second && settle_search(t, s).total < 2 {
		time.sleep(10 * time.Millisecond)
	}
	testing.expect_value(t, term.search_summary(s).total, 2)
}

@(test)
selection_drag_autoscrolls_history :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, LINES_200, &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, exited, "exit") || !await(t, s, shows, "LINE_200") {
		return
	}
	g := config("").geometry
	before, _ := term.scrollbar(s)
	anchor_x, anchor_y := f32(g.cell_width) * 20, f32(g.cell_height) * 5.5
	term.selection_press(s, anchor_x, anchor_y, 1_000)
	term.selection_drag(s, 1, f32(g.cell_height) * 2.5)
	testing.expect_value(t, term.selection_autoscroll(s), term.Autoscroll.None)
	term.selection_drag(s, 1, -4)
	testing.expect_value(t, term.selection_autoscroll(s), term.Autoscroll.Up)
	for _ in 0 ..< 4 {
		term.selection_autoscroll_tick(s, 1, -4)
	}
	after, _ := term.scrollbar(s)
	testing.expect_value(t, after.offset, before.offset - 4)
	term.selection_release(s, 1, -4)
	testing.expect_value(t, term.selection_autoscroll(s), term.Autoscroll.None)
	text, selected := term.selection_text(s, context.temp_allocator)
	testing.expect(t, selected)
	first := fmt.tprintf("LINE_%d", after.offset + 1)
	anchor := fmt.tprintf("LINE_%d", before.offset + 6)
	testing.expectf(t, strings.has_prefix(text, first), "selection %q starts at %s", text, first)
	testing.expectf(t, strings.contains(text, anchor), "selection %q reaches %s", text, anchor)
	term.selection_autoscroll_tick(s, 1, -4)
	unchanged, _ := term.scrollbar(s)
	testing.expect_value(t, unchanged.offset, after.offset)
}

@(test)
scrollback_lines_bound_history :: proc(t: ^testing.T) {
	wakes: Wakes
	s := start(t, "cmd.exe /d /q /k prompt $G", &wakes)
	if s == nil {
		return
	}
	defer term.destroy(s)
	if !await(t, s, shows, ">") {
		return
	}
	// libghostty frees history a page at a time, so the retained count swings around the limit by up to a
	// page (measured: 489 to 809 rows at 1000 lines, 137 to 457 at 200, with 100 columns).
	PAGE_SLACK :: 600
	batches := [?]struct {
		limit: int,
		marker: string,
	}{{1000, "FIRST"}, {1000, "SECOND"}, {200, "THIRD"}, {200, "FOURTH"}}
	for batch in batches {
		term.configure(s, batch.limit, .Block, false)
		command := fmt.tprintf("for /l %%i in (1,1,3000) do @echo %s_%%i\r", batch.marker)
		testing.expect(t, term.send_text(s, command))
		if !await(t, s, shows, fmt.tprintf("%s_3000", batch.marker)) {
			return
		}
		bar, _ := term.scrollbar(s)
		limit := u64(batch.limit + PAGE_SLACK)
		testing.expectf(t, bar.total <= limit, "%s retained %d rows over %d", batch.marker, bar.total, limit)
	}
}
