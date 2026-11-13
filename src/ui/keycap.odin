package ui

import "aio:render"

// A shortcut's whole chord, such as Ctrl+Shift+P, as one keycap: detail text in muted ink, inset
// KEYCAP_PADDING inside a hairline box KEYCAP_HEIGHT tall. The Settings search's Ctrl+F, the palette
// footer and tooltips draw keys this way. `keycap` is text in the detail style.
keycap_width :: proc(keycap: ^Text, label: string, scale: f32) -> f32 {
	return text_width(keycap, label) + 2 * KEYCAP_PADDING * scale
}

// Draws `label` as a keycap from `x`, centred in the band `top` to `top + height`, no taller than the
// band; `max_width` clips the label as draw_text does.
keycap_draw :: proc(
	list: ^render.Draw_List,
	keycap: ^Text,
	theme: Theme,
	label: string,
	x, top, height, scale: f32,
	max_width: f32 = 0,
) -> render.Build_Status {
	box_height := min(KEYCAP_HEIGHT * scale, height)
	box := render.Rect{x, top + (height - box_height) / 2, keycap_width(keycap, label, scale), box_height}
	draw_rect(list, {rect = box, color = theme.border, radius = RADIUS_CONTROL * scale, stroke = scale})
	baseline := box.y + (box.height - keycap.line_height) / 2 + keycap.ascent
	return draw_text(keycap, list, label, box.x + KEYCAP_PADDING * scale, baseline, theme.muted, max_width)
}
