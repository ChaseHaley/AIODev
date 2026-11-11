package ui

import "aio:render"

// One tiled pane of a tab whose view shows a single pane, for the glyph and map that show the others.
Hidden_Pane :: struct {
	// Where the pane sits in the tab, as fractions of the tiled area.
	rect:   render.Rect,
	title:  string,
	status: Status_Mark,
	// The pane's badge, as its header shows it: a content icon, else a keycap glyph or program art.
	icon:   Icon,
	glyph:  string,
	atlas:  render.Rect,
	// The pane the view shows.
	shown:  bool,
}

// The header glyph: the layout in miniature, in a compact box that takes the hover.
HIDDEN_PANES_GLYPH :: [2]f32{20, 14}
HIDDEN_PANES_GLYPH_BOX :: [2]f32{28, HEIGHT_COMPACT}
// The map's width; its height follows the tiled area's shape, so every card has one scale (D-089).
@(private = "file")
HIDDEN_PANES_MAP_WIDTH :: f32(340)
@(private = "file")
HIDDEN_PANES_CELL_GAP :: f32(2)
@(private = "file")
HIDDEN_PANES_DOT :: f32(6)

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
// window. Inside its padding it has the shape of the tiled `area`, narrowing when the window has too little
// room below the glyph.
hidden_panes_map_rect :: proc(box: render.Rect, area: [2]f32, width, height, scale: f32) -> render.Rect {
	pad := SPACE_2 * scale
	inset := SPACE_1 * scale
	y := box.y + box.height + inset
	shape := area.x > 0 ? area.y / area.x : 0
	inner := [2]f32{HIDDEN_PANES_MAP_WIDTH * scale - 2 * pad, 0}
	inner.y = inner.x * shape
	room := max(0, height - y - inset - 2 * pad)
	if inner.y > room {inner = {shape > 0 ? room / shape : 0, room}}
	size := inner + 2 * pad
	x := clamp(box.x + box.width + inset - size.x, inset, max(inset, width - size.x - inset))
	return {x, y, size.x, size.y}
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

// Opens the map: its frame and every pane's card, the shown pane's lit in the accent. False when the list
// has no room, and the caller draws nothing more. Previews go into the cards next, then
// hidden_panes_map_labels.
hidden_panes_map_open :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	surface: render.Rect,
	cells: []render.Rect,
	panes: []Hidden_Pane,
	width, height, scale: f32,
) -> bool {
	if !popover_open(list, surface, theme, width, height, scale) {return false}
	for pane, i in panes {
		r := cells[i]
		fill := theme.border
		if pane.shown {
			fill = theme.accent
			fill.a *= 0.18
		}
		draw_rect(list, {rect = r, color = fill, radius = hidden_panes_card_radius(r, scale)})
	}
	return true
}

// A card's corner radius.
hidden_panes_card_radius :: proc(card: render.Rect, scale: f32) -> f32 {
	return min(RADIUS_CONTROL * scale, card.width / 2, card.height / 2)
}

// Finishes the map over the previews: each card's label, the pane's badge, title and status dot on a band
// across its top, then the shown pane's accent ring and the hovered pane's ring.
hidden_panes_map_labels :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	surface: render.Rect,
	cells: []render.Rect,
	panes: []Hidden_Pane,
	hovered: int,
	scale: f32,
) -> render.Build_Status {
	small := text_styled(text, .Detail)
	pad := SPACE_1 * scale
	dot := HIDDEN_PANES_DOT * scale
	badge := ICON_INDICATOR * scale
	for pane, i in panes {
		r := cells[i]
		radius := hidden_panes_card_radius(r, scale)
		if render.push_layer(list, r, radius) != .None {return .Ok}
		band := render.Rect{r.x, r.y, r.width, small.line_height + 2 * pad}
		veil := theme.surface
		veil.a *= 0.85
		draw_rect(list, {rect = band, color = veil})
		ink := pane.shown || i == hovered ? theme.text : theme.muted
		mark := render.Rect{band.x + pad, band.y + (band.height - badge) / 2, badge, badge}
		if pane.icon != .None {
			icon_draw(list, pane.icon, mark, ink, ICON_INDICATOR, scale)
		} else if result := shell_badge_draw(list, text, theme, mark, pane.glyph, scale, pane.atlas);
		   result != .Ok {return result}
		status := render.Rect{band.x + band.width - pad - dot, band.y + (band.height - dot) / 2, dot, dot}
		if pane.status.glyph == .None || pane.status.glyph == .Idle {
			draw_rect(list, {rect = status, color = theme.faint, radius = dot / 2, stroke = scale})
		} else {
			draw_rect(list, {rect = status, color = status_color(theme, pane.status.glyph), radius = dot / 2})
		}
		title_x := mark.x + badge + pad
		baseline := band.y + pad + small.ascent
		if result := draw_fading_text(&small, list, pane.title, title_x, baseline, ink,
			   max(0, status.x - pad - title_x)); result != .Ok {return result}
		if pane.shown {
			draw_rect(list, {rect = r, color = theme.accent, radius = radius, stroke = 1.5 * scale})
		} else if i == hovered {
			draw_rect(list, {rect = r, color = theme.muted, radius = radius, stroke = 1.5 * scale})
		}
		if render.push_layer(list, surface, RADIUS_OVERLAY * scale) != .None {return .Ok}
	}
	return .Ok
}
