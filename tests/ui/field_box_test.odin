package ui_test

import "aio:font"
import "aio:render"
import "aio:ui"
import "core:testing"

// A box answers the frame it draws in and the offset for a pointer x. Pressing at either edge
// of that frame must produce the offset a drag at the same edge needs, at every window scale.
@(test)
field_box_offset_agrees_with_its_frame_at_two_scales :: proc(t: ^testing.T) {
	fonts, err := font.system_create()
	if !testing.expect_value(t, err, font.Error.None) {return}
	defer font.system_destroy(fonts)
	text: ui.Text
	if !testing.expect(t, ui.text_init(&text, fonts, nil, 16)) {return}
	field: ui.Text_Field
	defer delete(field.bytes)
	ui.field_set(&field, "name")
	rect := render.Rect{20, 30, 240, 32}
	for scale in ([?]f32{1, 2}) {
		ui.text_set_size(&text, 16*scale)
		box := ui.Field_Box {
			field       = &field,
			text        = &text,
			rect        = rect,
			inset       = 10,
			caret_width = 1,
			radius      = 5,
			style       = .Body,
			scale       = scale,
		}
		frame := ui.field_box_text_rect(box)
		testing.expect_value(t, frame.x, rect.x+10*scale)
		testing.expect_value(t, frame.width, rect.width-20*scale)
		testing.expect_value(t, ui.field_box_offset(box, frame.x), 0)
		ui.field_pointer(&field, ui.field_box_offset(box, frame.x), true, false)
		ui.field_pointer(&field, ui.field_box_offset(box, frame.x+frame.width), false, true)
		testing.expect_value(t, ui.field_selected_text(&field), "name")
		baseline := ui.field_box_baseline(box)
		styled := ui.text_styled(&text, .Body)
		top := baseline-styled.ascent
		testing.expect_value(t, top-rect.y, rect.y+rect.height-(top+styled.line_height))
	}
}
