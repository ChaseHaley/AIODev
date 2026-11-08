package term

import "aio:ghostty"
import "aio:search"
import "base:runtime"
import "core:log"
import "core:sync"
import "core:time"

// What the session's search is doing; nil is no search. One value names the backend, so libghostty and
// the row scanner never hold a needle at the same time.
Search_State :: union {
	Literal_Search,
	Pattern_Phase,
	Search_Failed,
}

// libghostty's incremental search holds the needle and its matches.
Literal_Search :: struct {
	// The terminal generation the search last read.
	fed: u64,
}

// The search could not start or went on without memory. It holds no needle and no matches.
Search_Failed :: struct {}

// A run of matched cells on one viewport row; columns are inclusive.
Highlight :: struct {
	row, first, last: int,
	selected:         bool,
}

// Starts a search of the session's scrollback and screens; an empty needle ends it. Literal text without
// case sensitivity uses libghostty's incremental search; other options use the row scanner. This and the
// passes in pattern_update are the only writers of s.search_state.
search_set_needle :: proc(s: ^Session, needle: string, options: search.Options = {}) {
	literal := len(needle) > 0 && options == {}
	switch _ in s.search_state {
	case Literal_Search:
		// A new needle replaces the old one. A failed clear leaves a needle that nothing feeds or reads.
		if !literal {_ = ghostty_set_needle(s, "")}
	case Pattern_Phase:
		pattern_clear(&s.pattern)
	case Search_Failed:
	case:
		if len(needle) == 0 {return}
	}
	switch {
	case len(needle) == 0:
		s.search_state = nil
	case literal:
		s.search_state = Search_Failed{}
		if ghostty_set_needle(s, needle) {s.search_state = Literal_Search{generation(s)}}
	case:
		s.search_state = pattern_set(s, needle, options)
	}
	mark_changed(s)
}

@(private, require_results)
ghostty_set_needle :: proc(s: ^Session, needle: string) -> bool {
	value := ghostty.String{raw_data(needle), uint(len(needle))}
	sync.mutex_lock(&s.mutex)
	result := ghostty.search_set(s.search, .Needle, len(needle) > 0 ? &value : nil)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: setting the search text failed: %v", result)
	}
	return result == .Success
}

// Whether search_update has work: the search is still catching up or the terminal changed
// since it last looked.
search_pending :: proc(s: ^Session) -> bool {
	switch state in s.search_state {
	case Literal_Search:
		status: ghostty.Search_Status
		if ghostty.search_get(s.search, .Status, &status) != .Success {
			return false
		}
		return status != .Complete || generation(s) != state.fed
	case Pattern_Phase:
		return pattern_pending(s, state)
	case Search_Failed:
	}
	return false
}

// Advances the search for a bounded time. The terminal lock is held only while the search reads the terminal.
search_update :: proc(s: ^Session) {
	switch &state in s.search_state {
	case Literal_Search:
		state.fed = generation(s)
		ghostty_update(s)
	case Pattern_Phase:
		pattern_update(s, state, search.STEP_BUDGET)
	case Search_Failed:
	}
}

@(private)
ghostty_update :: proc(s: ^Session) {
	start := time.tick_now()
	if !search_feed(s) {
		return
	}
	for time.tick_since(start) < search.STEP_BUDGET {
		status: ghostty.Search_Status
		if result := ghostty.search_tick(s.search, &status); result != .Success {
			log.errorf("term: advancing the search failed: %v", result)
			return
		}
		switch status {
		case .Complete:
			return
		case .Feed_Required:
			if !search_feed(s) {
				return
			}
		case .Running:
		}
	}
}

@(private)
search_feed :: proc(s: ^Session) -> bool {
	sync.mutex_lock(&s.mutex)
	result := ghostty.search_feed(s.search)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: feeding the search failed: %v", result)
	}
	return result == .Success
}

// Selects the next older match, or the next newer one, wrapping at either end, and scrolls it into view.
// Older matches sit higher on screen. Returns false when there is nothing to select.
search_select :: proc(s: ^Session, older: bool) -> bool {
	switch _ in s.search_state {
	case Literal_Search:
		return ghostty_select(s, older)
	case Pattern_Phase:
		return pattern_select(s, older)
	case Search_Failed:
	}
	return false
}

@(private)
ghostty_select :: proc(s: ^Session, older: bool) -> bool {
	sync.mutex_lock(&s.mutex)
	result := ghostty.search_set(s.search, older ? .Select_Next : .Select_Prev, nil)
	sync.mutex_unlock(&s.mutex)
	if result != .Success && result != .No_Value {
		log.errorf("term: selecting a search match failed: %v", result)
	}
	mark_changed(s)
	return result == .Success
}

// What the find bar shows, counted from the newest match up (search.Order.Newest_First, the zero value).
search_summary :: proc(s: ^Session) -> search.Summary {
	switch phase in s.search_state {
	case Literal_Search:
		return ghostty_summary(s)
	case Pattern_Phase:
		return pattern_summary(&s.pattern, phase)
	case Search_Failed:
		return {progress = .Failed, selected = -1}
	}
	return {selected = -1}
}

@(private)
ghostty_summary :: proc(s: ^Session) -> search.Summary {
	summary := search.Summary {
		progress = .Searching,
		selected = -1,
	}
	status: ghostty.Search_Status
	total, index: uint
	if ghostty.search_get(s.search, .Status, &status) == .Success && status == .Complete {
		summary.progress = .Complete
	}
	if ghostty.search_get(s.search, .Total_Matches, &total) == .Success {
		summary.total = int(total)
	}
	if ghostty.search_get(s.search, .Selected_Index, &index) == .Success {
		summary.selected = int(index)
	}
	return summary
}

// Replaces `out` with the viewport's matches, the selected match last. The caller holds the mutex.
// Matches are snapshots that a terminal write invalidates, so they are fed, read, and converted in one hold.
@(private)
collect_highlights :: proc(s: ^Session, out: ^[dynamic]Highlight) {
	clear(out)
	if _, pattern := s.search_state.(Pattern_Phase); pattern {
		pattern_highlights(s, out)
		return
	}
	if _, literal := s.search_state.(Literal_Search); !literal {
		return
	}
	if result := ghostty.search_feed(s.search); result != .Success {
		log.errorf("term: feeding the search failed: %v", result)
		return
	}
	buffer := ghostty.Selection_Buffer{raw_data(s.search_matches), uint(len(s.search_matches)), 0}
	result := ghostty.search_get(s.search, .Viewport_Matches, &buffer)
	if result == .Out_Of_Space {
		previous := len(s.search_matches)
		if runtime.resize_dynamic_array(&s.search_matches, int(buffer.len)) != nil {
			return
		}
		for &match in s.search_matches[previous:] {
			match = ghostty.sized(ghostty.Selection)
		}
		buffer = {raw_data(s.search_matches), uint(len(s.search_matches)), 0}
		result = ghostty.search_get(s.search, .Viewport_Matches, &buffer)
	}
	if result != .Success {
		log.errorf("term: reading search matches failed: %v", result)
		return
	}
	for &match in s.search_matches[:buffer.len] {
		if !append_highlight(s, &match, false, out) {
			return
		}
	}
	selected := ghostty.sized(ghostty.Selection)
	if ghostty.search_get(s.search, .Selected_Match, &selected) == .Success {
		append_highlight(s, &selected, true, out)
	}
}

// Splits a match into per-row runs clipped to the viewport. A match that crosses the top or bottom edge
// converts on one end only, which places the other end beyond that edge.
@(private)
append_highlight :: proc(
	s: ^Session,
	match: ^ghostty.Selection,
	selected: bool,
	out: ^[dynamic]Highlight,
) -> bool {
	last_column, last_row := int(s.geometry.columns) - 1, int(s.geometry.rows) - 1
	start, end: ghostty.Point_Coordinate
	has_start :=
		ghostty.terminal_point_from_grid_ref(s.terminal, &match.start, .Viewport, &start) ==
		.Success
	has_end :=
		ghostty.terminal_point_from_grid_ref(s.terminal, &match.end, .Viewport, &end) == .Success
	if !has_start && !has_end {
		return true
	}
	if !has_start {
		start = {}
	}
	if !has_end {
		end = {u16(last_column), u32(last_row)}
	} else {
		// Search endpoints refer to the cluster head; its wide spacer is part of the match.
		cell: ghostty.Cell
		width: ghostty.Cell_Wide
		result := ghostty.grid_ref_cell(&match.end, &cell)
		if result == .Success {result = ghostty.cell_get(cell, .Wide, &width)}
		if result != .Success {
			log.errorf("term: reading search endpoint width failed: %v", result)
			return false
		}
		if width == .Wide {end.x = min(end.x + 1, u16(last_column))}
	}
	for row in int(start.y) ..= min(int(end.y), last_row) {
		first := row == int(start.y) ? int(start.x) : 0
		last := row == int(end.y) ? int(end.x) : last_column
		highlight := Highlight{row, first, min(last, last_column), selected}
		if _, err := append(out, highlight); err != nil {
			return false
		}
	}
	return true
}
