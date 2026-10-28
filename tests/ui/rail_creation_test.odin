package ui_test

import "aio:render"
import "aio:ui"
import "core:testing"

@(test)
rail_creation_follows_short_lists_and_sticks_below_overflow :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2}) {
		area := render.Rect{10 * scale, 40 * scale, 208 * scale, 200 * scale}
		for count in ([?]int{0, 1, 4, 5, 6, 20}) {
			initial := ui.rail_layout(area, scale, count, 0)
			expected := area.y + min(initial.content_height, area.height - 32 * scale)
			testing.expect_value(t, initial.footer.y, expected)
			testing.expect(t, initial.footer.y + initial.footer.height <= area.y + area.height)
			for scroll in ([?]f32{0, 80 * scale, 10000 * scale}) {
				l := ui.rail_layout(area, scale, count, scroll)
				testing.expect_value(t, l.footer, initial.footer)
				tile := ui.rail_footer_tile(l)
				x, y := tile.x + tile.width / 2, tile.y + tile.height / 2
				testing.expect(t, ui.rail_footer_hit(l, x, y))
				testing.expect_value(t, ui.rail_row_hit(l, x, y), -1)
				if count > 0 && ui.rail_scroll_max(l) == 0 {
					last := ui.rail_row_rect(l, count - 1)
					testing.expect_value(t, l.footer.y - last.y - last.height, ui.RAIL_PADDING * scale)
				}
			}
		}
	}
}

@(test)
rail_creation_and_profile_targets_stay_distinct_at_every_width :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.25, 1.5, 2}) {
		for width in ([?]f32{144, 208, 480}) {
			l := ui.rail_layout({0, 40 * scale, width * scale, 200 * scale}, scale, 20, 100)
			plus := ui.rail_new_tab_tile(l)
			profile := ui.rail_profile_rect(l)
			testing.expect_value(t, plus.x + plus.width, profile.x)
			testing.expect_value(t, plus.y, profile.y)
			testing.expect(t, !ui.rail_profile_hit(l, plus.x + plus.width / 2, plus.y + plus.height / 2))
			testing.expect(t, ui.rail_profile_hit(l, profile.x + profile.width / 2, profile.y + profile.height / 2))
		}
	}
}
