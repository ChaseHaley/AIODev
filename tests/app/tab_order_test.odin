package app_test

import "core:testing"
import app "../../src"

@(test)
tab_order_selection_after_move_follows_the_grabbed_tab :: proc(t: ^testing.T) {
	testing.expect_value(t, app.tab_selected_after_move(0, 0, 2), 2)
	testing.expect_value(t, app.tab_selected_after_move(1, 0, 2), 0)
	testing.expect_value(t, app.tab_selected_after_move(2, 0, 2), 1)
	testing.expect_value(t, app.tab_selected_after_move(0, 2, 0), 1)
	testing.expect_value(t, app.tab_selected_after_move(1, 2, 0), 2)
	testing.expect_value(t, app.tab_selected_after_move(2, 2, 0), 0)
	testing.expect_value(t, app.tab_selected_after_move(1, 1, 1), 1)
	testing.expect_value(t, app.tab_selected_after_move(3, 0, 1), 3)
}

@(test)
tab_order_selection_after_remove_clamps_to_remaining_tabs :: proc(t: ^testing.T) {
	testing.expect_value(t, app.tab_selected_after_remove(3, 3, 3), 2)
	testing.expect_value(t, app.tab_selected_after_remove(2, 0, 3), 1)
	testing.expect_value(t, app.tab_selected_after_remove(0, 0, 3), 0)
	testing.expect_value(t, app.tab_selected_after_remove(0, 0, 0), 0)
}
