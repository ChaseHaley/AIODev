package ui

import "aio:glyphs"
import "aio:render"

// A one-line editable field drawn inside a rectangle. Draw and hit-test read the same numbers; the
// surface still owns the fill, border, focus ring and baseline.
Field_Box :: struct {
	field:       ^Text_Field,
	text:        ^Text,
	rect:        render.Rect,
	inset:       f32,
	caret_width: f32,
	radius:      f32,
	style:       Text_Style,
	scale:       f32,
}

field_box_text_rect :: proc(box: Field_Box) -> render.Rect {
	inset := box.inset * box.scale
	return {box.rect.x + inset, box.rect.y, max(1, box.rect.width - 2 * inset), box.rect.height}
}

// The caret offset nearest to `x`, for a press or drag inside the box.
field_box_offset :: proc(box: Field_Box, x: f32) -> int {
	// An empty field has a single offset, so it needs no glyph metrics.
	if len(box.field.bytes) == 0 {return 0}
	text := text_styled(box.text, box.style)
	frame := field_box_text_rect(box)
	start := field_view_start(box.field, &text, frame.width)
	return field_offset_at(box.field, &text, start, frame.x, x)
}

// The baseline that centres one line of the box's text.
field_box_baseline :: proc(box: Field_Box) -> f32 {
	text := text_styled(box.text, box.style)
	return box.rect.y + (box.rect.height - text.line_height) / 2 + text.ascent
}

// Draws the field at `baseline`, clipped to the box. A surface that draws more content in the
// box's layer draws it before this call or pushes its own layer afterwards.
field_box_draw :: proc(
	box: Field_Box,
	list: ^render.Draw_List,
	theme: Theme,
	baseline: f32,
	focused: bool,
	placeholder: string,
) -> glyphs.Result {
	text := text_styled(box.text, box.style)
	frame := field_box_text_rect(box)
	if render.push_layer(list, box.rect, box.radius * box.scale) != .None {return .Ok}
	return field_draw(
		box.field,
		list,
		&text,
		theme,
		frame.x,
		baseline,
		frame.width,
		focused,
		placeholder,
		theme.text,
		max(1, box.caret_width * box.scale),
	)
}
