package ghostty_test

import "core:fmt"
import "core:testing"
import "aio:ghostty"

@(test)
search_scrollback :: proc(t: ^testing.T) {
	terminal: ghostty.Terminal
	if !testing.expect_value(t, ghostty.terminal_new(nil, &terminal, 20, 4), SUCCESS) {
		return
	}
	defer ghostty.terminal_free(terminal)
	for i in 0 ..< 30 {
		write(terminal, fmt.tprintf("row %d%s", i, i % 10 == 3 ? " Needle" : ""))
		write(terminal, "\r\n")
	}
	search: ghostty.Search
	if !testing.expect_value(t, ghostty.search_new(nil, &search, terminal), SUCCESS) {
		return
	}
	defer ghostty.search_free(search)
	status: ghostty.Search_Status
	testing.expect_value(t, ghostty.search_get(search, .Status, &status), SUCCESS)
	testing.expect_value(t, status, ghostty.Search_Status.Complete)
	needle := ghostty.String{raw_data(string("needle")), 6}
	testing.expect_value(t, ghostty.search_set(search, .Needle, &needle), SUCCESS)
	testing.expect_value(t, ghostty.search_run(search), SUCCESS)
	total: uint
	testing.expect_value(t, ghostty.search_get(search, .Total_Matches, &total), SUCCESS)
	testing.expect_value(t, total, 3)
	index: uint
	testing.expect_value(t, ghostty.search_get(search, .Selected_Index, &index), NONE)
	testing.expect_value(t, ghostty.search_set(search, .Select_Next, nil), SUCCESS)
	testing.expect_value(t, ghostty.search_get(search, .Selected_Index, &index), SUCCESS)
	testing.expect_value(t, index, 0)
	match := ghostty.sized(ghostty.Selection)
	testing.expect_value(t, ghostty.search_get(search, .Selected_Match, &match), SUCCESS)
	expect_selection_text(t, terminal, &match, "Needle")
	coordinate: ghostty.Point_Coordinate
	result := ghostty.terminal_point_from_grid_ref(terminal, &match.start, .Screen, &coordinate)
	testing.expect_value(t, result, SUCCESS)
	testing.expect_value(t, coordinate, ghostty.Point_Coordinate{7, 23})
	testing.expect_value(t, ghostty.search_set(search, .Select_Prev, nil), SUCCESS)
	testing.expect_value(t, ghostty.search_get(search, .Selected_Index, &index), SUCCESS)
	testing.expect_value(t, index, 2)
	matches: ghostty.Selection_Buffer
	testing.expect_value(t, ghostty.search_get(search, .Matches, &matches), SPACE)
	testing.expect_value(t, matches.len, 3)
	testing.expect_value(t, ghostty.search_set(search, .Needle, nil), SUCCESS)
	testing.expect_value(t, ghostty.search_get(search, .Total_Matches, &total), SUCCESS)
	testing.expect_value(t, total, 0)
	testing.expect_value(t, ghostty.search_set(search, .Select_Next, nil), NONE)
}
