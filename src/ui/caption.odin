package ui

import "aio:glyphs"
import "aio:render"

TITLE_BAR_HEIGHT :: f32(40)

// The title chrome claims pointer input over this height for its caption controls. The
// claim is hit before any floating surface placed after the chrome, so such a surface
// must start at or below this height; `caption_hit` and the surface layouts read the
// same value so the claim and the exclusion cannot drift apart.
caption_claim_height :: proc(scale: f32) -> f32 {
	return TITLE_BAR_HEIGHT * scale
}

caption_hit :: proc(width, x, y, scale: f32) -> int {
	if y < 0 || y >= caption_claim_height(scale) || x < width - 138 * scale || x >= width {return -1}
	return clamp(int((x - width + 138 * scale) / (46 * scale)), 0, 2)
}

caption_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, scale: f32,
	hover, pressed: int,
	maximized: bool,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	if render.push_layer(list, {0, 0, width, TITLE_BAR_HEIGHT * scale}) != .None {return .Ok}
	for i in 0 ..< 3 {
		r := render.Rect{width - f32(3 - i) * 46 * scale, 0, 46 * scale, TITLE_BAR_HEIGHT * scale}
		ink := theme.text
		if i == hover {
			fill := i == pressed ? theme.pressed : theme.hover
			if i == 2 {fill, ink = {0.77, 0.17, 0.11, 1}, {1, 1, 1, 1}}
			draw_rect(list, {rect = r, color = fill})
		}
		icon := ([3]rune{'\ue921', maximized ? '\ue923' : '\ue922', '\ue8bb'})[i]
		if result := draw_icon(text, list, icon, r, ink, 0.4); result != .Ok {return result}
		if i == hover {
			// The buttons are flush with the window edge and some carry a forced fill, so the
			// paper hairline would read as a stray border.
			if result := hover_rim_draw(list, theme, r, 0, 1, scale, pointer, false);
			   result != .None {return .Ok}
		}
	}
	return .Ok
}
