package ui

import "aio:render"

Navigation_Row :: struct {
	title: string,
	selected, marked, hovered, pressed: bool,
	// The caller draws the selection mark itself, as the tab rail does to slide it between rows.
	mark_elsewhere: bool,
	leading, trailing: f32,
}

// The selected row's accent mark at the row's leading edge.
navigation_row_mark_rect :: proc(rect: render.Rect, scale: f32) -> render.Rect {
	return {rect.x + scale, rect.y + 8 * scale, 2 * scale, max(0, rect.height - 16 * scale)}
}

navigation_row_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	row: Navigation_Row,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if navigation_row_surface_draw(list, theme, rect, row, scale, pointer) != .None {return .Ok}
	return draw_fading_text(
		text,
		list,
		row.title,
		rect.x + CONTROL_INSET * scale + row.leading,
		rect.y + (rect.height - text.line_height) / 2 + text.ascent,
		row.selected ? theme.tab_active_text : theme.tab_text,
		max(0, rect.width - 2 * CONTROL_INSET * scale - row.leading - row.trailing),
	)
}

// Shared by tab rows and Activity reports, whose content has its own layout.
@(require_results)
navigation_row_surface_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	row: Navigation_Row,
	scale: f32,
	pointer: [2]f32,
) -> render.Error {
	s := scale
	tile := render.Rect{rect.x, rect.y + s, rect.width, max(0, rect.height - 2 * s)}
	if row.selected {
		draw_rect(list, {rect = tile, color = theme.rail_active, radius = RADIUS_CONTROL * s})
		if !row.mark_elsewhere {
			mark := navigation_row_mark_rect(rect, s)
			draw_rect(list, {rect = mark, color = theme.tab_indicator, radius = pill_radius(mark)})
		}
	} else if row.marked {
		draw_rect(list, {rect = tile, color = theme.selection, radius = RADIUS_CONTROL * s})
		draw_rect(list, {rect = tile, color = theme.accent, radius = RADIUS_CONTROL * s, stroke = s})
	} else if row.hovered || row.pressed {
		fill := row.pressed ? theme.pressed : theme.hover
		draw_rect(list, {rect = tile, color = fill, radius = RADIUS_CONTROL * s})
	}
	if row.hovered && !row.selected {
		return hover_rim_draw(list, theme, tile, RADIUS_CONTROL * s, 1, s, pointer)
	}
	return .None
}
