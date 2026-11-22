package ui

import "cosmos:render"
import "core:fmt"
import "core:math"

// A tab group's chip (D-093): its name in the group's colour before its tabs, in the strip and the rail
// alike, a bare label on the tray that holds the group's run (WORK-454). A folded group's chip stands in
// for its tabs, so it takes a tint and an outline of its own and adds how many there are and the most
// urgent status.
Tab_Chip :: struct {
	name:         string,
	color:        render.Color,
	folded:       bool,
	count:        int,
	status:       Status_Mark,
	status_phase: f32,
	// The chip lies on its group's tray as that folds into it or out of it: no tint or outline of its own.
	bare:         bool,
}

// In the strip a long name fades out where a tab's title would, at a tab's widest; in the rail, at the row's
// end as a tab's does.
TAB_CHIP_MAX_WIDTH :: TAB_MAX_WIDTH
// The strip keeps this much clear on either side of a chip.
TAB_CHIP_MARGIN :: SPACE_1
// The tray reaches this far past the tiles of the tabs it holds, above and below in the strip and to the
// sides in the rail.
TAB_TRAY_INSET :: f32(3)

// Which ends of a group's tray a piece of it closes: the chip starts the tray and the group's last tab ends
// it; a tab dragged on its own carries a tray closed at both ends.
Tray_End :: enum u8 {
	Start,
	End,
}
Tray_Ends :: bit_set[Tray_End;u8]

// How strongly a group's outline shows: at rest, with the pointer on its chip, and with its chip pressed or
// dragging the group, each a step more contrast.
Tray_State :: enum u8 {
	Rest,
	Hover,
	Pressed,
}

@(private = "file")
tray_edge :: proc(state: Tray_State) -> f32 {
	switch state {
	case .Rest: return 0.2
	case .Hover: return 0.45
	case .Pressed: return 0.75
	}
	return 0.2
}

// The tray's band across the strip, around the tab tiles.
tab_tray_band :: proc(bar_height, scale: f32) -> (y, height: f32) {
	tile := HEIGHT_TOOLBAR * scale
	return (bar_height - tile) / 2 - TAB_TRAY_INSET * scale, tile + 2 * TAB_TRAY_INSET * scale
}

// Draws the part of a group's tray inside `slice`, which spans the tray across the run: the tray rounds only
// the ends in `ends` and runs on past the others, so the chip and each tab, drawn apart, build one tray.
// `vertical` runs the tray down the rail rather than along the strip.
tab_tray_draw :: proc(
	list: ^render.Draw_List,
	slice: render.Rect,
	color: render.Color,
	ends: Tray_Ends,
	state: Tray_State,
	vertical: bool,
	scale: f32,
) -> render.Error {
	if color.a <= 0 || slice.width <= 0 || slice.height <= 0 || len(list.layers) == 0 {return .None}
	previous := list.layers[len(list.layers) - 1]
	radius := RADIUS_OVERLAY * scale
	// Neighbouring slices meet on the same whole pixel, so their tints neither overlap nor part.
	x, y := math.round(slice.x), math.round(slice.y)
	snapped := render.Rect{x, y, math.round(slice.x + slice.width) - x, math.round(slice.y + slice.height) - y}
	shape := snapped
	if vertical {
		if .Start not_in ends {shape.y -= 2 * radius; shape.height += 2 * radius}
		if .End not_in ends {shape.height += 2 * radius}
	} else {
		if .Start not_in ends {shape.x -= 2 * radius; shape.width += 2 * radius}
		if .End not_in ends {shape.width += 2 * radius}
	}
	c := previous.clip
	left, top := max(c.x, snapped.x), max(c.y, snapped.y)
	right := min(c.x + c.width, snapped.x + snapped.width)
	bottom := min(c.y + c.height, snapped.y + snapped.height)
	if err := render.push_layer(list, {left, top, max(0, right - left), max(0, bottom - top)}); err != .None {
		return err
	}
	fill, edge := color, color
	fill.a *= 0.09
	edge.a *= tray_edge(state)
	draw_rect(list, {rect = shape, color = fill, radius = radius})
	draw_rect(list, {rect = shape, color = edge, radius = radius, stroke = scale})
	return render.push_layer(list, previous.clip, previous.radius)
}

// Where a group's tray lies `open` of the way from `closed`, its folded chip, to `tray`, its tray at rest
// open: every edge moves together, so the tray gathers into the chip's top left corner as it folds.
tab_tray_fold_rect :: proc(closed, tray: render.Rect, open: f32) -> render.Rect {
	left := math.lerp(closed.x, tray.x, open)
	top := math.lerp(closed.y, tray.y, open)
	right := math.lerp(closed.x + closed.width, tray.x + tray.width, open)
	bottom := math.lerp(closed.y + closed.height, tray.y + tray.height, open)
	return {left, top, right - left, bottom - top}
}

// Draws a folding group's tray at `rect`, from tab_tray_fold_rect, its corners and tint `open` of the way
// from the folded chip's to the open tray's, so the tray hands over to the chip without a seam.
tab_tray_fold_draw :: proc(
	list: ^render.Draw_List,
	rect: render.Rect,
	color: render.Color,
	state: Tray_State,
	open, scale: f32,
) {
	radius := math.lerp(RADIUS_CONTROL, RADIUS_OVERLAY, open) * scale
	fill, edge := color, color
	fill.a *= math.lerp(f32(0.12), 0.09, open)
	edge.a *= tray_edge(state) + math.lerp(f32(0.1), 0, open)
	draw_rect(list, {rect = rect, color = fill, radius = radius})
	draw_rect(list, {rect = rect, color = edge, radius = radius, stroke = scale})
}

// What a folded chip adds after its name or dot: the tab count, then the status. Zero while unfolded.
@(private = "file")
tab_chip_tail :: proc(text: ^Text, chip: Tab_Chip, scale: f32) -> f32 {
	if !chip.folded {return 0}
	tail := text_width(text, fmt.tprint(chip.count))
	if chip.status.glyph != .None {tail += (SPACE_1 + ICON_INDICATOR) * scale}
	return tail
}

// The chip's width in pixels: its name between insets, at most `widest` pixels in all, else a square holding
// a dot of its colour, then what a folded chip adds.
tab_chip_width :: proc(text: ^Text, chip: Tab_Chip, scale, widest: f32) -> f32 {
	inset := CONTROL_INSET * scale
	tail := tab_chip_tail(text, chip, scale)
	if chip.name == "" {return HEIGHT_COMPACT * scale + (chip.folded ? tail + inset : 0)}
	strong := text_styled(text, .Strong)
	extra := chip.folded ? SPACE_1 * scale + tail : 0
	return min(max(0, widest - extra), text_width(&strong, chip.name) + 2 * inset) + extra
}

// The chip fills `rect` at its own height, centred. Unfolded it is a bare label on its tray, which shows
// `state`; folded it has no tray, so it is tinted and outlined itself, its outline showing `state`.
tab_chip_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	chip: Tab_Chip,
	state: Tray_State,
	scale: f32,
) -> render.Build_Status {
	height := HEIGHT_COMPACT * scale
	r := render.Rect{rect.x, rect.y + (rect.height - height) / 2, rect.width, height}
	radius := RADIUS_CONTROL * scale
	if chip.folded && !chip.bare {
		fill, edge := chip.color, chip.color
		fill.a *= 0.12
		edge.a *= tray_edge(state) + 0.1
		draw_rect(list, {rect = r, color = fill, radius = radius})
		draw_rect(list, {rect = r, color = edge, radius = radius, stroke = scale})
	}
	inset := CONTROL_INSET * scale
	tail := tab_chip_tail(text, chip, scale)
	x := r.x + height
	if chip.name == "" {
		size := SPACE_2 * scale
		dot := render.Rect{r.x + (height - size) / 2, r.y + (height - size) / 2, size, size}
		draw_rect(list, {rect = dot, color = chip.color, radius = size / 2})
	} else {
		strong := text_styled(text, .Strong)
		baseline := r.y + (height - strong.line_height) / 2 + strong.ascent
		room := r.width - 2 * inset - (chip.folded ? SPACE_1 * scale + tail : 0)
		label := min(text_width(&strong, chip.name), max(0, room))
		if result := draw_fading_text(&strong, list, chip.name, r.x + inset, baseline, chip.color, label);
		   result != .Ok {return result}
		x = r.x + inset + label + SPACE_1 * scale
	}
	if !chip.folded {return .Ok}
	count := fmt.tprint(chip.count)
	baseline := r.y + (height - text.line_height) / 2 + text.ascent
	if result := draw_text(text, list, count, x, baseline, theme.muted); result != .Ok {return result}
	if chip.status.glyph == .None {return .Ok}
	size := ICON_INDICATOR * scale
	mark := render.Rect{x + text_width(text, count) + SPACE_1 * scale, r.y + (height - size) / 2, size, size}
	return status_glyph_draw(list, text, theme, mark, chip.status, chip.status_phase, scale)
}
