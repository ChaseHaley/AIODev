package ui

import "aio:platform"
import "aio:render"

TITLE_BAR_HEIGHT :: f32(platform.TITLE_BAR_HEIGHT)
CAPTION_WIDTH :: f32(platform.CAPTION_WIDTH)

// The title chrome claims pointer input over this height for its caption controls. The
// claim is hit before any floating surface placed after the chrome, so such a surface
// must start at or below this height; `caption_hit` and the surface layouts read the
// same value so the claim and the exclusion cannot drift apart.
caption_claim_height :: proc(scale: f32) -> f32 {
	return TITLE_BAR_HEIGHT * scale
}

caption_hit :: proc(width, x, y, scale: f32) -> Maybe(platform.Caption_Button) {
	if y < 0 || y >= caption_claim_height(scale) || x < width - CAPTION_WIDTH * scale || x >= width {return nil}
	index := int((x - width + CAPTION_WIDTH * scale) / (platform.CAPTION_BUTTON_WIDTH * scale))
	return platform.Caption_Button(clamp(index, 0, len(platform.Caption_Button) - 1))
}

caption_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, scale: f32,
	hover, pressed: Maybe(platform.Caption_Button),
	maximized: bool,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	if render.push_layer(list, {0, 0, width, TITLE_BAR_HEIGHT * scale}) != .None {return .Ok}
	for button in platform.Caption_Button {
		count := f32(len(platform.Caption_Button) - int(button))
		r := render.Rect {
			width - count * platform.CAPTION_BUTTON_WIDTH * scale,
			0,
			platform.CAPTION_BUTTON_WIDTH * scale,
			TITLE_BAR_HEIGHT * scale,
		}
		ink := theme.text
		hovered := hover != nil && hover.? == button
		if hovered {
			fill := pressed != nil && pressed.? == button ? theme.pressed : theme.hover
			if button == .Close {fill, ink = {0.77, 0.17, 0.11, 1}, {1, 1, 1, 1}}
			draw_rect(list, {rect = r, color = fill})
		}
		icon: rune
		switch button {
		case .Minimize:
			icon = '\ue921'
		case .Maximize:
			icon = maximized ? '\ue923' : '\ue922'
		case .Close:
			icon = '\ue8bb'
		}
		if result := draw_icon(text, list, icon, r, ink, 0.4); result != .Ok {return result}
		if hovered {
			// The buttons are flush with the window edge and some carry a forced fill, so the
			// paper hairline would read as a stray border.
			if result := hover_rim_draw(list, theme, r, 0, 1, scale, pointer, false);
			   result != .None {return .Ok}
		}
	}
	return .Ok
}
