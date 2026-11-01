package ui

import "aio:glyphs"
import "aio:render"

Navigation_Row :: struct {
	title: string,
	selected, marked, hovered, pressed: bool,
	leading, trailing: f32,
}

navigation_row_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	row: Navigation_Row,
	scale: f32,
	pointer: [2]f32,
) -> glyphs.Result {
	s := scale
	tile := render.Rect{rect.x, rect.y + s, rect.width, max(0, rect.height - 2 * s)}
	if row.selected {
		draw_rect(list, {rect = tile, color = theme.rail_active, radius = RADIUS_CONTROL * s})
		draw_rect(list, {rect = {rect.x + s, rect.y + 8 * s, 2 * s, rect.height - 16 * s},
			color = theme.tab_indicator, radius = s})
	} else if row.marked {
		draw_rect(list, {rect = tile, color = theme.selection, radius = RADIUS_CONTROL * s})
		draw_rect(list, {rect = tile, color = theme.accent, radius = RADIUS_CONTROL * s, stroke = s})
	} else if row.hovered || row.pressed {
		fill := row.pressed ? theme.pressed : theme.hover
		draw_rect(list, {rect = tile, color = fill, radius = RADIUS_CONTROL * s})
	}
	if result := draw_fading_text(
		text,
		list,
		row.title,
		rect.x + 8 * s + row.leading,
		rect.y + (rect.height - text.line_height) / 2 + text.ascent,
		row.selected ? theme.tab_active_text : theme.tab_text,
		max(0, rect.width - 16 * s - row.leading - row.trailing),
	); result != .Ok {return result}
	if row.hovered && !row.selected {
		if hover_rim_draw(list, theme, tile, RADIUS_CONTROL * s, 1, s, pointer) != .None {return .Ok}
	}
	return .Ok
}
