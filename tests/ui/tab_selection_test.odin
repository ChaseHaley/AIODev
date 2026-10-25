package ui_test

import "core:testing"
import "aio:render"
import "aio:ui"

@(test)
rail_tab_tiles_indent_without_leaving_the_row :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		area := render.Rect{0, 40 * scale, ui.RAIL_WIDTH * scale, 400 * scale}
		layout := ui.rail_layout(area, scale, 3, 0)
		row := ui.rail_row_rect(layout, 1)
		tile := ui.rail_tab_tile(layout, row)
		testing.expect_value(t, tile.x, row.x + ui.RAIL_TAB_INDENT * scale)
		testing.expect_value(t, tile.x + tile.width, row.x + row.width)
		testing.expect_value(t, tile.y, row.y)
		testing.expect_value(t, tile.height, row.height)
		testing.expect(t, ui.rail_row_contains(layout, 1, tile.x + 1, tile.y + 1))
		testing.expect(t, tile.x > row.x && ui.rail_row_contains(layout, 1, tile.x - 1, tile.y + 1))
	}
}

@(test)
tab_selection_toggle_range_and_additive_range :: proc(t: ^testing.T) {
	marked := [?]bool{false, false, false, false, false, false}
	ui.tab_selection_update(marked[:], 1, 0, false, false)
	ui.tab_selection_update(marked[:], 4, 1, true, false)
	testing.expect_value(t, marked, [6]bool{false, true, false, false, true, false})
	ui.tab_selection_update(marked[:], 4, 1, true, false)
	testing.expect_value(t, marked, [6]bool{false, true, false, false, false, false})
	ui.tab_selection_update(marked[:], 4, 1, false, true)
	testing.expect_value(t, marked, [6]bool{false, true, true, true, true, false})
	ui.tab_selection_update(marked[:], 0, 1, true, true)
	testing.expect_value(t, marked, [6]bool{true, true, true, true, true, false})
	ui.tab_selection_update(marked[:], 3, 4, false, true)
	testing.expect_value(t, marked, [6]bool{false, false, false, true, true, false})
	ui.tab_selection_update(marked[:], 5, 4, false, false)
	testing.expect_value(t, marked, [6]bool{false, false, false, false, false, true})
	ui.tab_selection_update(marked[:], -1, 4, true, false)
	testing.expect_value(t, marked, [6]bool{false, false, false, false, false, true})
}

@(test)
group_order_keeps_selected_and_remaining_tabs_in_original_order :: proc(t: ^testing.T) {
	for mask in 1..<256 {
		marked: [8]bool
		count := 0
		for &value, i in marked { value = mask&(1<<uint(i)) != 0; if value { count += 1 } }
		for slot in 0..=8-count {
			out: [8]int
			testing.expect(t, ui.tab_group_order(marked[:], slot, out[:]))
			seen: [8]bool
			selected_last, remaining_last := -1, -1
			for original, i in out {
				testing.expect(t, original >= 0 && original < len(marked))
				testing.expect(t, !seen[original])
				seen[original] = true
				if i >= slot && i < slot+count {
					testing.expect(t, marked[original] && original > selected_last)
					selected_last = original
				} else {
					testing.expect(t, !marked[original] && original > remaining_last)
					remaining_last = original
				}
			}
		}
	}
	marked := [?]bool{true, false, true, false, false}
	out: [5]int
	testing.expect(t, ui.tab_group_order(marked[:], 2, out[:]))
	testing.expect_value(t, out, [5]int{1, 3, 0, 2, 4})
	testing.expect(t, !ui.tab_group_order(marked[:], -1, out[:]))
	testing.expect(t, !ui.tab_group_order(marked[:], 4, out[:]))
	testing.expect(t, !ui.tab_group_order(marked[:], 0, out[:4]))
}
