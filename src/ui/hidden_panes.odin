package ui

import "aio:render"

// One tiled pane of a tab whose view shows a single pane, for the glyph and map that show the others.
Hidden_Pane :: struct {
	// Where the pane sits in the tab, as fractions of the tiled area.
	rect:        render.Rect,
	title:       string,
	status:      Status_Mark,
	status_text: string,
	// The pane the view shows.
	shown:       bool,
}

// The header glyph: the layout in miniature, in a compact box that takes the hover.
HIDDEN_PANES_GLYPH :: [2]f32{20, 14}
HIDDEN_PANES_GLYPH_BOX :: [2]f32{28, HEIGHT_COMPACT}
// The map that hangs under the glyph, and the gap between its panes.
@(private = "file")
HIDDEN_PANES_MAP :: [2]f32{340, 196}
@(private = "file")
HIDDEN_PANES_CELL_GAP :: f32(2)

// Where a cell of `size` lands inside `area`, `gap` short of its neighbours.
@(private = "file")
hidden_panes_place :: proc(area: render.Rect, r: render.Rect, gap: f32) -> render.Rect {
	return {
		area.x + r.x * area.width + gap / 2,
		area.y + r.y * area.height + gap / 2,
		max(0, r.width * area.width - gap),
		max(0, r.height * area.height - gap),
	}
}

// The glyph inside `box`: the shown pane filled in the accent, a pane with a status outlined in its colour,
// the rest outlined faintly. `open` draws the box pressed while the map shows.
hidden_panes_glyph_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	box: render.Rect,
	panes: []Hidden_Pane,
	open: bool,
	scale: f32,
) {
	if open {draw_rect(list, {rect = box, color = theme.pressed, radius = RADIUS_CONTROL * scale})}
	size := HIDDEN_PANES_GLYPH * scale
	area := render.Rect{box.x + (box.width - size.x) / 2, box.y + (box.height - size.y) / 2, size.x, size.y}
	for pane in panes {
		r := hidden_panes_place(area, pane.rect, scale)
		radius := min(1.5 * scale, r.width / 2, r.height / 2)
		if pane.shown {
			draw_rect(list, {rect = r, color = theme.accent, radius = radius})
			continue
		}
		edge := pane.status.glyph != .None ? status_color(theme, pane.status.glyph) : theme.faint
		draw_rect(list, {rect = r, color = edge, radius = radius, stroke = scale})
	}
}

// The map under the glyph `box`, its right edge just past the glyph's, kept inside a `width` by `height`
// window.
hidden_panes_map_rect :: proc(box: render.Rect, width, height, scale: f32) -> render.Rect {
	size := HIDDEN_PANES_MAP * scale
	inset := SPACE_1 * scale
	x := clamp(box.x + box.width + inset - size.x, inset, max(inset, width - size.x - inset))
	y := box.y + box.height + SPACE_1 * scale
	return {x, y, size.x, min(size.y, max(0, height - y - SPACE_1 * scale))}
}

// The map's cell for each of `panes`, in order.
hidden_panes_map_cells :: proc(surface: render.Rect, panes: []Hidden_Pane, scale: f32, out: []render.Rect) {
	inner := render.Rect {
		surface.x + SPACE_2 * scale,
		surface.y + SPACE_2 * scale,
		max(0, surface.width - 2 * SPACE_2 * scale),
		max(0, surface.height - 2 * SPACE_2 * scale),
	}
	for pane, i in panes {
		if i >= len(out) {break}
		out[i] = hidden_panes_place(inner, pane.rect, HIDDEN_PANES_CELL_GAP * scale)
	}
}

// Draws the map: every pane as a card at its place in the tab, named, with its status under the name and as
// a dot in its corner. The shown pane carries the accent; `hovered` takes the pressed fill.
hidden_panes_map_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	surface: render.Rect,
	panes: []Hidden_Pane,
	hovered: int,
	width, height, scale: f32,
) -> render.Build_Status {
	if !popover_open(list, surface, theme, width, height, scale) {return .Ok}
	cells := make([]render.Rect, len(panes), context.temp_allocator)
	hidden_panes_map_cells(surface, panes, scale, cells)
	small := text_styled(text, .Detail)
	pad := SPACE_1 * scale
	dot := 6 * scale
	for pane, i in panes {
		r := cells[i]
		radius := min(RADIUS_CONTROL * scale, r.width / 2, r.height / 2)
		fill := theme.border
		if pane.shown {
			fill = theme.accent
			fill.a *= 0.18
		} else if i == hovered {
			fill = theme.pressed
		}
		draw_rect(list, {rect = r, color = fill, radius = radius})
		if pane.shown {draw_rect(list, {rect = r, color = theme.accent, radius = radius, stroke = 1.5 * scale})}
		if render.push_layer(list, r, radius) != .None {return .Ok}
		title_room := r.width - 2 * pad
		if pane.status.glyph != .None {
			mark := render.Rect{r.x + r.width - pad - dot, r.y + pad + 1, dot, dot}
			draw_rect(list, {rect = mark, color = status_color(theme, pane.status.glyph), radius = dot / 2})
			title_room -= dot + pad
		}
		baseline := r.y + pad + small.ascent
		ink := pane.shown || i == hovered ? theme.text : theme.muted
		if result := draw_fading_text(&small, list, pane.title, r.x + pad, baseline, ink, title_room);
		   result != .Ok {return result}
		if pane.status_text != "" {
			if result := draw_fading_text(
				&small,
				list,
				pane.status_text,
				r.x + pad,
				baseline + small.line_height,
				status_color(theme, pane.status.glyph),
				r.width - 2 * pad,
			); result != .Ok {return result}
		}
		if render.push_layer(list, surface, RADIUS_OVERLAY * scale) != .None {return .Ok}
	}
	return .Ok
}
