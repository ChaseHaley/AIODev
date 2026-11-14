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

// One key hint: its keycaps, joined by a slash, and what they do. The palette footer and the Arrange mode
// card list keys this way.
Key_Hint :: struct {
	keys:  [2]string,
	label: string,
}

key_hint_width :: proc(keycap, label: ^Text, hint: Key_Hint, scale: f32) -> f32 {
	width := keycap_width(keycap, hint.keys[0], scale)
	if hint.keys[1] != "" {
		width += text_width(label, "/") + 2 * SPACE_1 * scale + keycap_width(keycap, hint.keys[1], scale)
	}
	return width + SPACE_1 * scale + text_width(label, hint.label)
}

// Draws `hint` from `x`, its keycaps centred in `band`'s height and its label on `baseline`.
key_hint_draw :: proc(
	list: ^render.Draw_List,
	keycap, label: ^Text,
	theme: Theme,
	hint: Key_Hint,
	x: f32,
	band: render.Rect,
	baseline: f32,
	scale: f32,
) -> render.Build_Status {
	pen := x
	for key, i in hint.keys {
		if key == "" {continue}
		if i > 0 {
			pen += 4 * scale
			if result := draw_text(label, list, "/", pen, baseline, theme.faint); result != .Ok {return result}
			pen += text_width(label, "/") + 4 * scale
		}
		if result := keycap_draw(list, keycap, theme, key, pen, band.y, band.height, scale); result != .Ok {
			return result
		}
		pen += keycap_width(keycap, key, scale)
	}
	return draw_text(label, list, hint.label, pen + SPACE_1 * scale, baseline, theme.muted)
}
