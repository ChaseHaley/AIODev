package ui_test

import "core:testing"
import "aio:render"
import "aio:ui"

@(test)
tab_bar_offset_separates_workspace_tabs_buttons_and_drop_region :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75, 2}) {
		bar := ui.tab_bar_layout(700*scale, scale, 3)
		bar.x = 184*scale
		testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x-1, 20*scale), -1)
		testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x, 20*scale), 0)
		testing.expect_value(t, ui.tab_bar_hit_test(bar, bar.x+bar.tab_width, 20*scale), 1)
		for i in 0..<bar.count {
			r := ui.tab_close_rect(bar, i, scale)
			testing.expect(t, r.x >= bar.x+f32(i)*bar.tab_width)
			testing.expect_value(t, ui.tab_close_hit(bar, r.x+r.width/2, r.y+r.height/2, scale), i)
		}
		end := bar.x+f32(bar.count)*bar.tab_width
		testing.expect_value(t, ui.tab_bar_hit_test(bar, end, 20*scale), bar.count)
		testing.expect_value(t, ui.tab_close_hit(bar, end+10*scale, 20*scale, scale), -1)
		r := ui.tab_drop_region(bar, 1200*scale, scale)
		testing.expect_value(t, r, render.Rect{end, 0, 1200*scale-138*scale-end, 40*scale})
		testing.expect(t, !ui.tab_drop_hit(bar, 1200*scale, scale, bar.x-1, 20*scale))
		testing.expect(t, ui.tab_drop_hit(bar, 1200*scale, scale, end, 20*scale))
	}
}
