package ui

import "aio:render"

// The raised-hover language shared by every interactive surface. Callers pass the already
// animated 0..1 hover value from Control_Motion, so hover fills, lift and the rim light all
// settle together and none of them run while the pointer is still.
//
// The lift is purely visual: hit testing keeps using the unmoved rectangle.
hover_lift_at :: proc(theme: Theme, hover, scale: f32) -> f32 {
	if hover <= 0 || theme.hover_lift <= 0 {return 0}
	return theme.hover_lift * scale * clamp(hover, 0, 1)
}

// Draws the soft seat under a lifted control. Call before the control's own fill.
hover_shadow_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	radius, hover, scale: f32,
) -> render.Error {
	if hover <= 0 || theme.hover_lift <= 0 {return .None}
	color := theme.shadow
	color.a *= clamp(hover, 0, 1)
	return render.push_rect(
		list,
		{
			rect = {rect.x, rect.y + 2 * scale, rect.width, rect.height},
			color = color,
			radius = radius,
			softness = 7 * scale,
		},
	)
}

// Draws the pointer-following rim light. Call after the control's content; the band lives on
// the rounded edge, so it never covers an inset label or glyph. `pointer` is in window pixels.
hover_rim_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	radius, hover, scale: f32,
	pointer: [2]f32,
) -> render.Error {
	if hover <= 0 || theme.hover_gloss <= 0 || rect.width <= 0 || rect.height <= 0 {return .None}
	color := theme.rim
	color.a = min(color.a * clamp(hover, 0, 1) * theme.hover_gloss, 1)
	return render.push_rect(
		list,
		{
			rect = rect,
			color = color,
			radius = radius,
			fill = render.RECT_FILL_RIM,
			sheen = {pointer.x - rect.x, pointer.y - rect.y, 90 * scale, max(1, 1.25 * scale)},
		},
	)
}
