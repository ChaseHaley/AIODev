package ui_test

import "core:testing"
import "aio:ui"

@(test)
tab_bar_caps_widths_and_hit_tests_tabs_actions_and_empty_space :: proc(t: ^testing.T) {
	bar := ui.tab_bar_layout(500, 1, 3)
	testing.expect_value(t, bar.count, 3)
	testing.expect_value(t, bar.height, ui.TITLE_BAR_HEIGHT)
	testing.expect(t, bar.tab_width > 0 && bar.tab_width <= 220)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+2, 20), 0)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+bar.tab_width+2, 20), 1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+2, bar.height), -1)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 1, 20), 0)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, -1, 20), -1)

	new_tab := bar.x + f32(bar.count)*bar.tab_width + 2
	testing.expect_value(t, ui.tab_bar_hit_test(bar, new_tab, 20), bar.count)
	testing.expect_value(t, ui.tab_bar_hit_test(bar, new_tab+bar.button_width, 20), -1)

	close := ui.tab_close_rect(bar, 1, 1)
	testing.expect_value(t, close.width, f32(22))
	testing.expect_value(t, ui.tab_close_hit(bar, close.x+close.width/2, close.y+close.height/2, 1), 1)

	drop := ui.tab_drop_region(bar, 900, 1)
	testing.expect(t, ui.tab_drop_hit(bar, 900, 1, drop.x+2, 20))
	testing.expect(t, !ui.tab_drop_hit(bar, 900, 1, 2, 20))
}

@(test)
tab_bar_with_no_tabs_has_no_hit_surface :: proc(t: ^testing.T) {
	bar := ui.tab_bar_layout(500, 1, 0)
	testing.expect_value(t, bar.count, 0)
	testing.expect_value(t, bar.tab_width, f32(0))
	testing.expect_value(t, ui.tab_bar_hit_test(bar, 40, 20), -1)
}
