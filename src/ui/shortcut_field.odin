package ui

import "aio:render"
import "core:fmt"
import "core:strings"

SHORTCUT_FIELD_WIDTH :: f32(176)

// The field borrows the first label; the complete alternatives remain in its owner's value.
Shortcut_Summary :: struct {
	first:      string,
	additional: int,
}

shortcut_summary :: proc(value: string) -> Shortcut_Summary {
	result: Shortcut_Summary
	start, count := 0, 0
	for end in 0 ..= len(value) {
		if end < len(value) && value[end] != ',' {continue}
		part := strings.trim_space(value[start:end])
		start = end + 1
		if part == "" || strings.equal_fold(part, "none") {continue}
		if count == 0 {result.first = part}
		count += 1
	}
	result.additional = max(0, count - 1)
	return result
}

// Settings and palette adapters supply the row and reset anchor; all field geometry is shared.
@(private)
shortcut_parts :: proc(parts: ^Row_Parts, scale: f32, selected: bool) {
	s := scale
	r := parts.row
	cy := r.y + r.height / 2
	right := parts.reset.x - SPACE_3 * s
	width := clamp((right - r.x) / s * 0.45, 120, SHORTCUT_FIELD_WIDTH) * s
	parts.field = {right - width, cy - HEIGHT_STANDARD / 2 * s, width, HEIGHT_STANDARD * s}
	if !selected {return}
	switch_w, switch_h := SWITCH_WIDTH * s, SWITCH_HEIGHT * s
	parts.positions = {parts.field.x - 148 * s, cy - switch_h / 2, switch_w, switch_h}
	parts.text_right = parts.positions.x
	if parts.positions.x - r.x < 190 * s {
		parts.text_right = parts.field.x - 84 * s
		parts.positions = {parts.text_right + SPACE_3 * s, r.y + SPACE_1 * s, switch_w, switch_h}
		parts.positions_label_below = true
	}
}

Shortcut_Field_State :: struct {
	capturing, focused, positions_focused, physical: bool,
	empty_label: string,
}

// One field for idle, selected and recording states on every surface. Only the popup lists
// alternatives; even a recording field keeps the same compact summary and input typography. The
// caller's layer is current again afterwards.
shortcut_field_draw :: proc(
	list: ^render.Draw_List, text: ^Text, theme: Theme, parts: Row_Parts,
	summary: Shortcut_Summary, state: Shortcut_Field_State, page: render.Rect, scale: f32,
) -> render.Build_Status {
	input := text_styled(text, .Body)
	baseline := parts.field.y + (parts.field.height - input.line_height) / 2 + input.ascent
	box_draw(list, parts.field, theme, state.focused && !state.capturing, scale)
	if state.capturing {
		radius := RADIUS_CONTROL * scale
		draw_rect(list, {rect = parts.field, color = theme.accent, radius = radius, stroke = 2 * scale})
	}
	scope, opened := clip_scope_open(list, parts.field, RADIUS_CONTROL * scale)
	if !opened {return .Ok}
	defer clip_scope_close(list, scope)
	first := summary.first
	if first == "" {
		empty := state.empty_label != "" ? state.empty_label : "Add shortcut"
		first = state.capturing ? "Press keys…" : empty
	}
	buffer: [32]u8
	suffix := summary.additional > 0 ? fmt.bprintf(buffer[:], ", +%d", summary.additional) : ""
	suffix_width := text_width(&input, suffix)
	room := max(1, parts.field.width - 2 * CONTROL_INSET * scale - suffix_width)
	x := parts.field.x + CONTROL_INSET * scale
	ink := summary.first == "" ? theme.muted : theme.text
	if result := draw_fading_text(&input, list, first, x, baseline, ink, room); result != .Ok {return result}
	if suffix != "" {
		if result := draw_text(&input, list, suffix, x + min(room, text_width(&input, first)), baseline, ink);
		   result != .Ok {return result}
	}
	if parts.positions.width <= 0 {return .Ok}
	if render.push_layer(list, page) != .None {return .Ok}
	switch_draw(list, parts.positions, state.physical, state.positions_focused, theme, scale)
	small := text_styled(text, .Detail)
	label := "Key positions"
	if parts.positions_label_below {
		return draw_text(&small, list, label,
		                 parts.positions.x + (parts.positions.width - text_width(&small, label)) / 2,
		                 parts.positions.y + parts.positions.height + 2 * scale + small.ascent, theme.muted)
	}
	return draw_text(&small, list, label, parts.positions.x + parts.positions.width + SPACE_2 * scale,
	                 parts.positions.y + (parts.positions.height - small.line_height) / 2 + small.ascent,
	                 theme.muted)
}
