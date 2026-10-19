package ui_test

import "core:testing"
import "aio:render"
import "aio:ui"

@(test)
headers_keep_scaled_geometry_and_hit_targets_inside_visible_cards :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		for width in ([?]f32{0, 10, 27, 50, 100, 400}) {
			for height in ([?]f32{0, 10, 200}) {
				area := render.Rect{5, 8, width*scale, height*scale}
				l := ui.header_layout(area, scale, true)
				testing.expect_value(t, l.panel.height, min(height, 28)*scale)
				for button, i in l.buttons {
					if button.width == 0 { continue }
					x, y := button.x+button.width/2, button.y+button.height/2
					if y >= l.panel.y+l.panel.height { continue }
					testing.expect_value(t, ui.header_hit_test(l, x, y), ui.Header_Action(i+1))
				}
				testing.expect_value(t, ui.header_hit_test(l, area.x-1, area.y), ui.Header_Action.None)
				testing.expect_value(t, ui.header_hit_test(l, area.x+area.width, area.y+5), ui.Header_Action.None)
				testing.expect_value(t, ui.header_hit_test(l, area.x+5, l.panel.y+l.panel.height), ui.Header_Action.None)
				inactive := ui.header_layout(area, scale, false)
				testing.expect_value(t, inactive.buttons, l.buttons)
			}
		}
	}
}
