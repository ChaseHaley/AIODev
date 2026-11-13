package ui

import "aio:render"
import "core:fmt"

// A tab group's chip (D-093): a tinted label in the group's colour before its tabs, in the strip and the
// rail alike. A folded group's chip stands in for its tabs, so it adds how many there are and the most
// urgent status among them.
Tab_Chip :: struct {
	name:         string,
	color:        render.Color,
	folded:       bool,
	count:        int,
	status:       Status_Mark,
	status_phase: f32,
}

// A long name fades out at this width rather than crowd the tabs.
TAB_CHIP_MAX_WIDTH :: f32(160)
// The strip keeps this much clear on either side of a chip.
TAB_CHIP_MARGIN :: SPACE_1

// What a folded chip adds after its name or dot: the tab count, then the status. Zero while unfolded.
@(private = "file")
tab_chip_tail :: proc(text: ^Text, chip: Tab_Chip, scale: f32) -> f32 {
	if !chip.folded {return 0}
	tail := text_width(text, fmt.tprint(chip.count))
	if chip.status.glyph != .None {tail += (SPACE_1 + ICON_INDICATOR) * scale}
	return tail
}

// The chip's width in pixels: its name between insets, else a square holding a dot of its colour, then
// what a folded chip adds.
tab_chip_width :: proc(text: ^Text, chip: Tab_Chip, scale: f32) -> f32 {
	inset := CONTROL_INSET * scale
	tail := tab_chip_tail(text, chip, scale)
	if chip.name == "" {return HEIGHT_COMPACT * scale + (chip.folded ? tail + inset : 0)}
	strong := text_styled(text, .Strong)
	width := min(TAB_CHIP_MAX_WIDTH * scale, text_width(&strong, chip.name) + 2 * inset)
	return width + (chip.folded ? SPACE_1 * scale + tail : 0)
}

// The chip fills `rect` at its own height, centred: hovering deepens its tint, and a folded chip is outlined.
tab_chip_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	chip: Tab_Chip,
	hover, scale: f32,
) -> render.Build_Status {
	height := HEIGHT_COMPACT * scale
	r := render.Rect{rect.x, rect.y + (rect.height - height) / 2, rect.width, height}
	radius := RADIUS_CONTROL * scale
	fill := chip.color
	fill.a *= 0.16 + 0.1 * hover
	draw_rect(list, {rect = r, color = fill, radius = radius})
	if chip.folded {
		edge := chip.color
		edge.a *= 0.45
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
