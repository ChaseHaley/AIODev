package term

import "aio:ghostty"
import "base:runtime"
import "core:log"
import "core:sync"
import "core:time"

@(private)
SEARCH_STEP_BUDGET :: 2 * time.Millisecond

Search_Summary :: struct {
	active, complete: bool,
	total:            int,
	// Position of the selected match counting from the newest, or -1 when none is selected.
	selected:         int,
}

// A run of matched cells on one viewport row; columns are inclusive.
Highlight :: struct {
	row, first, last: int,
	selected:         bool,
}

// Starts a search of the session's scrollback and screens; an empty needle ends it.
search_set_needle :: proc(s: ^Session, needle: string) {
	value := ghostty.String{raw_data(needle), uint(len(needle))}
	sync.mutex_lock(&s.mutex)
	result := ghostty.search_set(s.search, .Needle, len(needle) > 0 ? &value : nil)
	sync.mutex_unlock(&s.mutex)
	if result != .Success {
		log.errorf("term: setting the search text failed: %v", result)
		return
	}
	s.search_active = len(needle) > 0
	mark_changed(s)
}

// Whether search_update has work: the search is still catching up or the terminal changed
// since it last looked.
search_pending :: proc(s: ^Session) -> bool {
	if !s.search_active {
		return false
	}
	status: ghostty.Search_Status
	if ghostty.search_get(s.search, .Status, &status) != .Success {
		return false
	}
	return status != .Complete || generation(s) != s.search_fed
}

// Advances the search for a bounded time. The terminal lock is held only while the search reads the terminal.
search_update :: proc(s: ^Session) {
	if !s.search_active {
		return
	}
	s.search_fed = generation(s)
	start := time.tick_now()
	if !search_feed(s) {
		return
	}
	for time.tick_since(start) < SEARCH_STEP_BUDGET {
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
// Returns false when there is nothing to select.
search_select :: proc(s: ^Session, older: bool) -> bool {
	if !s.search_active {
		return false
	}
	sync.mutex_lock(&s.mutex)
	result := ghostty.search_set(s.search, older ? .Select_Next : .Select_Prev, nil)
	sync.mutex_unlock(&s.mutex)
	if result != .Success && result != .No_Value {
		log.errorf("term: selecting a search match failed: %v", result)
	}
	mark_changed(s)
	return result == .Success
}

search_summary :: proc(s: ^Session) -> Search_Summary {
	summary := Search_Summary {
		selected = -1,
	}
	if !s.search_active {
		return summary
	}
	summary.active = true
	status: ghostty.Search_Status
	total, index: uint
	if ghostty.search_get(s.search, .Status, &status) == .Success {
		summary.complete = status == .Complete
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
	if !s.search_active {
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
