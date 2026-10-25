package ui

import "aio:glyphs"
import "aio:render"

leader_status_layout :: proc(area: render.Rect, width, scale: f32) -> render.Rect {
	padding := min(8 * scale, area.width / 4, area.height / 4)
	height := min(22 * scale, max(0, area.height - 2 * padding))
	return {
		area.x + padding,
		area.y + area.height - padding - height,
		min(max(0, area.width - 2 * padding), width + 16 * scale),
		height,
	}
}

leader_status_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	chord: string,
	scale: f32,
) -> glyphs.Result {
	small := text_styled(text, .Small)
	keycap := text_styled(text, .Keycap)
	hint := "Leader · awaiting key"
	key_width := text_width(&keycap, chord)
	r := leader_status_layout(area, key_width + 8 * scale + text_width(&small, hint), scale)
	if r.height < small.line_height || r.width <= 16 * scale {return .Ok}
	if render.push_layer(list, r) != .None {return .Ok}
	draw_rect(list, {rect = r, color = theme.pane})
	baseline := r.y + (r.height - small.line_height) / 2 + small.ascent
	if result := draw_text(
		&keycap,
		list,
		chord,
		r.x + 8 * scale,
		baseline,
		theme.accent,
		max(0, r.width - 16 * scale),
	); result != .Ok {return result}
	return draw_text(
		&small,
		list,
		hint,
		r.x + 8 * scale + key_width + 8 * scale,
		baseline,
		theme.muted,
		max(0, r.width - key_width - 24 * scale),
	)
}

pane_message_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	message: string,
	scale: f32,
	radius: f32 = 0,
) -> glyphs.Result {
	if render.push_layer(list, area, radius) != .None {return .Ok}
	padding := min(10 * scale, area.width / 4)
	lines := make([dynamic]string, context.temp_allocator)
	wrap(text, message, max(1, area.width - 2 * padding), &lines)
	height := min(area.height, f32(len(lines)) * text.line_height + 2 * padding)
	top := area.y + area.height - height
	draw_rect(list, {rect = {area.x, top, area.width, height}, color = theme.surface})
	draw_rect(list, {rect = {area.x, top, area.width, 1}, color = theme.accent})
	for line, i in lines {
		if result := draw_text(
			text,
			list,
			line,
			area.x + padding,
			top + padding + f32(i) * text.line_height + text.ascent,
			theme.text,
		); result != .Ok {return result}
	}
	return .Ok
}
