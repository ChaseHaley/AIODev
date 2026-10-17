package term_test

import "core:fmt"
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
	settled := term.Search_Summary{active = true, complete = true, total = 111, selected = -1}
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
