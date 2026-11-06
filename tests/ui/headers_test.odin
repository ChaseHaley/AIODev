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
				l := ui.header_layout(area, scale)
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
			}
		}
	}
}

@(test)
headers_set_the_documents_button_apart_and_can_leave_it_out :: proc(t: ^testing.T) {
	scale := f32(1.5)
	area := render.Rect{5, 8, 400 * scale, 200 * scale}
	documents := int(ui.Header_Action.Documents) - 1
	l := ui.header_layout(area, scale)
	button, next := l.buttons[documents], l.buttons[documents + 1]
	testing.expect(t, button.width > 0)
	testing.expect(t, l.divider.x >= button.x + button.width && l.divider.x + l.divider.width <= next.x)
	testing.expect_value(t, l.divider.y + l.divider.height / 2, l.panel.y + l.panel.height / 2)
	testing.expect_value(t, ui.header_hit_test(l, button.x + 2, button.y + 2), ui.Header_Action.Documents)

	without := ui.header_layout(area, scale, false)
	testing.expect_value(t, without.buttons[documents].width, f32(0))
	testing.expect_value(t, without.divider.width, f32(0))
	testing.expect_value(t, without.buttons[documents + 1], next)
	testing.expect(t, without.title.width > l.title.width)

	// In a split this narrow the button must not reach the badge or title, which focus and drag the pane.
	small := ui.header_layout({5, 8, 198, 200}, 1)
	testing.expect_value(t, small.buttons[documents].width, f32(0))
	testing.expect_value(t, ui.header_hit_test(small, 5 + 35, 8 + 14), ui.Header_Action.None)
	wide_enough := ui.header_layout({5, 8, 280, 200}, 1)
	testing.expect(t, wide_enough.buttons[documents].width > 0)
	testing.expect(t, wide_enough.buttons[documents].x >= wide_enough.badge.x + wide_enough.badge.width + 48)

	// Too narrow for every control: the controls for the pane itself stay.
	narrow := ui.header_layout({5, 8, 170 * scale, 200 * scale}, scale)
	testing.expect_value(t, narrow.buttons[documents].width, f32(0))
	testing.expect_value(t, narrow.divider.width, f32(0))
	testing.expect(t, narrow.buttons[documents + 1].width > 0)
}

@(test)
pane_headers_offer_float_and_split_in_both_presentations :: proc(t: ^testing.T) {
	area := render.Rect{0, 0, 480, 200}
	tiled := ui.header_layout(area, 1, floating = false)
	floating := ui.header_layout(area, 1, floating = true)
	dock := int(ui.Header_Action.Dock) - 1
	right := int(ui.Header_Action.Split_Right) - 1
	down := int(ui.Header_Action.Split_Down) - 1
	zoom := int(ui.Header_Action.Zoom) - 1
	minimize := int(ui.Header_Action.Minimize) - 1
	testing.expect(t, tiled.buttons[dock].width > 0 && floating.buttons[dock].width > 0)
	testing.expect(t, tiled.buttons[right].width > 0 && floating.buttons[right].width > 0)
	testing.expect(t, tiled.buttons[down].width > 0 && floating.buttons[down].width > 0)
	testing.expect(t, tiled.buttons[zoom].width > 0 && floating.buttons[zoom].width == 0)
	testing.expect(t, tiled.buttons[minimize].width == 0 && floating.buttons[minimize].width > 0)
}

@(test)
the_split_overlay_carries_the_documents_button_first :: proc(t: ^testing.T) {
	scale := f32(1)
	area := render.Rect{0, 0, 600, 400}
	l := ui.split_overlay_layout(area, scale)
	documents := l.buttons[int(ui.Header_Action.Documents) - 1]
	right := l.buttons[int(ui.Header_Action.Split_Right) - 1]
	down := l.buttons[int(ui.Header_Action.Split_Down) - 1]
	testing.expect(t, documents.x > l.title.x && l.divider.x > documents.x && right.x > l.divider.x && down.x > right.x)
	testing.expect(t, down.x + down.width <= l.panel.x + l.panel.width)
	testing.expect_value(t, ui.header_hit_test(l, right.x + 2, right.y + 2), ui.Header_Action.Split_Right)
	without := ui.split_overlay_layout(area, scale, false)
	testing.expect_value(t, without.buttons[int(ui.Header_Action.Documents) - 1].width, f32(0))
	testing.expect(t, without.panel.width < l.panel.width)
}
