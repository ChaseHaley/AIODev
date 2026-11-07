package ui_test

import "core:testing"
import "aio:render"
import "aio:ui"

// A header's buttons, left to right, as a tiled pane shows them.
@(private = "file")
Header_Button :: enum u8 {
	Documents,
	Split_Right,
	Split_Down,
	Zoom,
	Fill_Window,
	Linked_Window,
	Dock,
	Close,
}

@(private = "file")
ALL :: bit_set[Header_Button] {
	.Documents, .Split_Right, .Split_Down, .Zoom, .Fill_Window, .Linked_Window, .Dock, .Close,
}

@(private = "file", rodata)
DROP_ORDER := [?]Header_Button {
	.Documents, .Fill_Window, .Linked_Window, .Zoom, .Split_Down, .Split_Right, .Dock, .Close,
}

@(private = "file")
header :: proc(area: render.Rect, scale: f32, shown := ALL) -> ui.Header_Layout(Header_Button) {
	return ui.header_layout(area, scale, shown, Header_Button.Documents, DROP_ORDER[:])
}

@(test)
headers_keep_scaled_geometry_and_hit_targets_inside_visible_cards :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 1.75}) {
		for width in ([?]f32{0, 10, 27, 50, 100, 400}) {
			for height in ([?]f32{0, 10, 200}) {
				area := render.Rect{5, 8, width*scale, height*scale}
				l := header(area, scale)
				testing.expect_value(t, l.panel.height, min(height, 28)*scale)
				for button, action in l.buttons {
					if button.width == 0 { continue }
					x, y := button.x+button.width/2, button.y+button.height/2
					if y >= l.panel.y+l.panel.height { continue }
					hit := ui.header_hit_test(l, x, y)
					testing.expect_value(t, hit, ui.Header_Target(Header_Button)(action))
				}
				testing.expect(t, ui.header_hit_test(l, area.x-1, area.y) == nil)
				testing.expect(t, ui.header_hit_test(l, area.x+area.width, area.y+5) == nil)
				testing.expect(t, ui.header_hit_test(l, area.x+5, l.panel.y+l.panel.height) == nil)
			}
		}
	}
}

// The badge takes clicks over the chevron its hover draws, at every scale.
@(test)
headers_take_badge_clicks_where_the_hover_draws :: proc(t: ^testing.T) {
	scale := f32(2)
	l := header({5, 8, 400 * scale, 200 * scale}, scale)
	y := l.badge.y + l.badge.height / 2
	testing.expect_value(t, l.badge_target.x, l.badge.x - 3 * scale)
	testing.expect_value(t, l.badge_target.x + l.badge_target.width, l.badge.x + l.badge.width + 9 * scale)
	badge := ui.header_hit_test(l, l.badge.x + l.badge.width + 8 * scale, y)
	testing.expect_value(t, badge, ui.Header_Target(Header_Button)(ui.Header_Badge{}))
}

@(test)
headers_set_the_documents_button_apart_and_can_leave_it_out :: proc(t: ^testing.T) {
	scale := f32(1.5)
	area := render.Rect{5, 8, 400 * scale, 200 * scale}
	l := header(area, scale)
	button, next := l.buttons[.Documents], l.buttons[.Split_Right]
	testing.expect(t, button.width > 0)
	testing.expect(t, l.divider.x >= button.x + button.width && l.divider.x + l.divider.width <= next.x)
	testing.expect_value(t, l.divider.y + l.divider.height / 2, l.panel.y + l.panel.height / 2)
	documents := ui.header_hit_test(l, button.x + 2, button.y + 2)
	testing.expect_value(t, documents, ui.Header_Target(Header_Button)(Header_Button.Documents))

	without := header(area, scale, ALL - {.Documents})
	testing.expect_value(t, without.buttons[.Documents].width, f32(0))
	testing.expect_value(t, without.divider.width, f32(0))
	testing.expect_value(t, without.buttons[.Split_Right], next)
	testing.expect(t, without.title.width > l.title.width)

	// In a split this narrow the button must not reach the badge or title, which focus and drag the pane.
	small := header({5, 8, 198, 200}, 1)
	testing.expect_value(t, small.buttons[.Documents].width, f32(0))
	testing.expect(t, ui.header_hit_test(small, 5 + 35, 8 + 14) == nil)
	wide_enough := header({5, 8, 280, 200}, 1)
	testing.expect(t, wide_enough.buttons[.Documents].width > 0)
	testing.expect(t, wide_enough.buttons[.Documents].x >= wide_enough.badge.x + wide_enough.badge.width + 48)

	// Too narrow for every control: the controls for the pane itself stay.
	narrow := header({5, 8, 170 * scale, 200 * scale}, scale)
	testing.expect_value(t, narrow.buttons[.Documents].width, f32(0))
	testing.expect_value(t, narrow.divider.width, f32(0))
	testing.expect(t, narrow.buttons[.Split_Right].width > 0)
}

@(test)
the_split_overlay_carries_the_documents_button_first :: proc(t: ^testing.T) {
	scale := f32(1)
	area := render.Rect{0, 0, 600, 400}
	shown := bit_set[Header_Button]{.Documents, .Split_Right, .Split_Down}
	l := ui.split_overlay_layout(area, scale, shown, Header_Button.Documents)
	documents, right, down := l.buttons[.Documents], l.buttons[.Split_Right], l.buttons[.Split_Down]
	testing.expect(t, documents.x > l.title.x && l.divider.x > documents.x)
	testing.expect(t, right.x > l.divider.x && down.x > right.x)
	testing.expect(t, down.x + down.width <= l.panel.x + l.panel.width)
	split := ui.header_hit_test(l, right.x + 2, right.y + 2)
	testing.expect_value(t, split, ui.Header_Target(Header_Button)(Header_Button.Split_Right))
	without := ui.split_overlay_layout(area, scale, shown - {.Documents}, Header_Button.Documents)
	testing.expect_value(t, without.buttons[.Documents].width, f32(0))
	testing.expect(t, without.panel.width < l.panel.width)
}
