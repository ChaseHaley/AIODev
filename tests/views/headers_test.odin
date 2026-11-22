package views_test

import "core:testing"
import "cosmos:render"
import "aio:views"
import "cosmos:ui"

// A header's buttons, left to right, as a tiled pane shows them.
@(private = "file")
Header_Button :: enum u8 {
	Documents,
	Split_Right,
	Split_Down,
	Zoom,
	Fill_Window,
	Dock,
	Linked_Window,
	Close,
}

@(private = "file")
ALL :: bit_set[Header_Button] {
	.Documents, .Split_Right, .Split_Down, .Zoom, .Fill_Window, .Dock, .Linked_Window, .Close,
}

@(private = "file")
GROUP_ENDS :: bit_set[Header_Button]{.Documents, .Split_Down, .Fill_Window, .Linked_Window}

@(private = "file", rodata)
DROP_ORDER := [?]Header_Button {
	.Documents, .Fill_Window, .Linked_Window, .Zoom, .Split_Down, .Split_Right, .Dock, .Close,
}

@(private = "file")
header :: proc(area: render.Rect, scale: f32, shown := ALL) -> views.Header_Layout(Header_Button) {
	return views.header_layout(area, scale, shown, GROUP_ENDS, DROP_ORDER[:])
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
					hit := views.header_hit_test(l, x, y)
					testing.expect_value(t, hit, views.Header_Target(Header_Button)(action))
				}
				testing.expect(t, views.header_hit_test(l, area.x-1, area.y) == nil)
				testing.expect(t, views.header_hit_test(l, area.x+area.width, area.y+5) == nil)
				testing.expect(t, views.header_hit_test(l, area.x+5, l.panel.y+l.panel.height) == nil)
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
	badge := views.header_hit_test(l, l.badge.x + l.badge.width + 8 * scale, y)
	testing.expect_value(t, badge, views.Header_Target(Header_Button)(views.Header_Badge{}))
}

@(test)
headers_set_the_documents_button_apart_and_can_leave_it_out :: proc(t: ^testing.T) {
	scale := f32(1.5)
	area := render.Rect{5, 8, 400 * scale, 200 * scale}
	l := header(area, scale)
	button, next := l.buttons[.Documents], l.buttons[.Split_Right]
	testing.expect(t, button.width > 0)
	divider := l.dividers[.Documents]
	testing.expect(t, divider.x >= button.x + button.width && divider.x + divider.width <= next.x)
	testing.expect_value(t, divider.y + divider.height / 2, l.panel.y + l.panel.height / 2)
	documents := views.header_hit_test(l, button.x + 2, button.y + 2)
	testing.expect_value(t, documents, views.Header_Target(Header_Button)(Header_Button.Documents))

	without := header(area, scale, ALL - {.Documents})
	testing.expect_value(t, without.buttons[.Documents].width, f32(0))
	testing.expect_value(t, without.dividers[.Documents].width, f32(0))
	testing.expect_value(t, without.buttons[.Split_Right], next)
	testing.expect(t, without.title.width > l.title.width)

	// In a split this narrow the button must not reach the badge or title, which focus and drag the pane.
	small := header({5, 8, 198, 200}, 1)
	testing.expect_value(t, small.buttons[.Documents].width, f32(0))
	testing.expect(t, views.header_hit_test(small, 5 + 35, 8 + 14) == nil)
	wide_enough := header({5, 8, 310, 200}, 1)
	testing.expect(t, wide_enough.buttons[.Documents].width > 0)
	testing.expect(t, wide_enough.buttons[.Documents].x >= wide_enough.badge.x + wide_enough.badge.width + 48)

	// Too narrow for every control: the controls for the pane itself stay.
	narrow := header({5, 8, 170 * scale, 200 * scale}, scale)
	testing.expect_value(t, narrow.buttons[.Documents].width, f32(0))
	testing.expect_value(t, narrow.dividers[.Documents].width, f32(0))
	testing.expect(t, narrow.buttons[.Split_Right].width > 0)
}

// Each group ends in a divider before the next group, and a group with nothing shown after it has none, so a
// float's header (no view or move buttons) shows no hairline beside Close.
@(test)
headers_divide_groups_only_where_a_later_group_shows :: proc(t: ^testing.T) {
	scale := f32(1)
	area := render.Rect{0, 0, 600, 200}
	l := header(area, scale)
	for end in GROUP_ENDS {
		divider := l.dividers[end]
		testing.expectf(t, divider.width > 0, "a divider follows %v", end)
		testing.expect(t, divider.x >= l.buttons[end].x + l.buttons[end].width)
		next := Header_Button(int(end) + 1)
		testing.expect(t, divider.x + divider.width <= l.buttons[next].x)
	}
	testing.expect_value(t, l.dividers[.Zoom].width, f32(0))

	floating := header(area, scale, {.Documents, .Split_Right, .Split_Down, .Close})
	testing.expect(t, floating.dividers[.Split_Down].width > 0)
	only_splits := header(area, scale, {.Split_Right, .Split_Down})
	testing.expect_value(t, only_splits.dividers[.Split_Down].width, f32(0))
	end := area.x + area.width - ui.SPACE_1 * scale
	down := only_splits.buttons[.Split_Down]
	testing.expect_value(t, down.x + down.width, end)
}

// A header's program status sits just left of its buttons while they show and at the header's right end
// while they are hidden, where the last button's fill would end. The title keeps one width either way.
@(test)
headers_move_the_status_to_the_right_end_while_buttons_hide :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5}) {
		area := render.Rect{5, 8, 600 * scale, 200 * scale}
		l := header(area, scale)
		natural := 100 * scale
		beside, title := views.header_status_layout(l, natural, scale, 0)
		testing.expect_value(t, beside.width, natural)
		testing.expect_value(t, beside.x + beside.width + ui.SPACE_2 * scale, l.buttons[.Documents].x)
		testing.expect_value(t, title, l.title.width - natural - ui.SPACE_2 * scale)
		edge, edge_title := views.header_status_layout(l, natural, scale, 1)
		close := l.buttons[.Close]
		testing.expect_value(t, edge.x + edge.width, close.x + close.width)
		testing.expect_value(t, edge.x + edge.width, area.x + area.width - ui.SPACE_1 * scale)
		testing.expect_value(t, edge.width, natural)
		testing.expect_value(t, edge.y, beside.y)
		testing.expect_value(t, edge.height, beside.height)
		testing.expect_value(t, edge_title, title)
		// Halfway through the slide it is halfway between.
		half, half_title := views.header_status_layout(l, natural, scale, 0.5)
		testing.expect_value(t, half.x, (beside.x + edge.x) / 2)
		testing.expect_value(t, half_title, title)
	}

	// A long status takes at most half the title's room beside the buttons; at the right end it also takes
	// theirs, growing from where it began.
	l := header({0, 0, 400, 200}, 1)
	beside, title := views.header_status_layout(l, 1000, 1, 0)
	testing.expect_value(t, beside.width, l.title.width * 0.5)
	edge, edge_title := views.header_status_layout(l, 1000, 1, 1)
	testing.expect_value(t, edge.x, beside.x)
	testing.expect_value(t, edge.x + edge.width, 400 - ui.SPACE_1)
	testing.expect_value(t, edge_title, title)

	// The owner's widget sits before the buttons and slides to the right end with the status, which then
	// ends SPACE_2 before it; the title keeps one width.
	area := render.Rect{0, 0, 600, 200}
	size := [2]f32{20, 20}
	with_widget := views.header_layout(area, 1, ALL, GROUP_ENDS, DROP_ORDER[:], size)
	widget := with_widget.widget
	if !testing.expect(t, widget.width > 0) {return}
	testing.expect_value(t, widget.x + widget.width + ui.SPACE_1, with_widget.buttons[.Documents].x)
	at_end := views.header_layout(area, 1, ALL, GROUP_ENDS, DROP_ORDER[:], size, 1)
	testing.expect_value(t, at_end.widget.x + at_end.widget.width, area.width - ui.SPACE_1)
	testing.expect_value(t, at_end.widget.y, widget.y)
	testing.expect_value(t, at_end.title, with_widget.title)
	half_way := views.header_layout(area, 1, ALL, GROUP_ENDS, DROP_ORDER[:], size, 0.5)
	testing.expect_value(t, half_way.widget.x, (widget.x + at_end.widget.x) / 2)
	beside, _ = views.header_status_layout(with_widget, 1000, 1, 0)
	testing.expect(t, beside.x + beside.width <= widget.x)
	edge, _ = views.header_status_layout(at_end, 1000, 1, 1)
	testing.expect_value(t, edge.x, beside.x)
	testing.expect_value(t, edge.x + edge.width + ui.SPACE_2, at_end.widget.x)
}

// In every width, narrow headers that drop buttons included, the status at the right end never reaches
// left of its place beside the buttons, so it never covers the title, and stays inside the header.
@(test)
headers_keep_the_status_clear_of_the_title_in_narrow_headers :: proc(t: ^testing.T) {
	for scale in ([?]f32{1, 1.5, 2}) {
		for width := f32(0); width <= 640; width += 10 {
			area := render.Rect{5, 8, width * scale, 200 * scale}
			l := header(area, scale)
			for natural in ([?]f32{40, 120, 400}) {
				beside, title := views.header_status_layout(l, natural * scale, scale, 0)
				edge, edge_title := views.header_status_layout(l, natural * scale, scale, 1)
				testing.expect_value(t, edge_title, title)
				if l.title.width < 120 * scale {
					testing.expect_value(t, beside, render.Rect{})
					testing.expect_value(t, edge, render.Rect{})
					testing.expect_value(t, title, l.title.width)
					continue
				}
				testing.expect(t, l.title.x + title + ui.SPACE_2 * scale <= beside.x + 0.001)
				testing.expect(t, edge.x >= beside.x)
				testing.expect(t, edge.width >= beside.width)
				testing.expect(t, edge.width <= natural * scale)
				testing.expect(t, edge.x + edge.width <= area.x + area.width - ui.SPACE_1 * scale + 0.001)
			}
		}
	}
}
