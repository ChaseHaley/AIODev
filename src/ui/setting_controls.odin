package ui

import "aio:render"
import "aio:settings"
import "core:fmt"
import "core:math"
import "core:strings"

// The control, range and rounding a schema setting gets wherever it is edited. Settings and the
// palette both start from this, so a setting cannot show one control on the page and another in
// the palette. Dynamic choices (themes, fonts) and the current value are filled in by the caller.
// The strings are borrowed from the static schema.
schema_row :: proc(entry: settings.Schema_Entry) -> Editor_Row {
	row := Editor_Row {
		key           = entry.key,
		title         = entry.title,
		description   = entry.description,
		default_value = entry.default_value,
		minimum       = entry.minimum,
		maximum       = entry.maximum,
	}
	switch entry.kind {
	case .String:
		row.kind = .Text
		switch entry.key {
		case "input.leader":
			row.kind = .Shortcut
		case "theme.name":
			row.kind = .Choice
		case "font.family", "interface.font_family":
			row.kind, row.searchable = .Choice, true
		}
	case .Int:
		row.kind, row.step = .Integer, 1
	case .Float:
		row.kind, row.step = .Number, 0.1
	case .Bool:
		row.kind = .Toggle
	case .Enum:
		row.kind, row.choices = .Choice, entry.enum_names
	case .Set:
		row.kind, row.multiple, row.choices = .Choice, true, entry.enum_names
		row.choice_labels = settings.status_channel_labels[:]
	}
	switch entry.key {
	case "font.size":
		row.minimum, row.maximum, row.step = 6, 32, 1
	case "interface.font_size":
		row.step = 1
	case "font.line_height":
		row.minimum, row.maximum, row.step = 0.8, 2, 0.05
	}
	return row
}

// The rounding step of a numeric row; rows built outside the schema fall back by kind.
@(private)
row_step :: proc(row: ^Editor_Row) -> f64 {
	if row.step > 0 {return row.step}
	return row.kind == .Integer ? 1 : 0.1
}

// A number rounded to `step` as a setting value: whole numbers for whole steps, two decimals for
// steps finer than a tenth.
@(private)
number_text :: proc(step, value: f64) -> string {
	if step >= 1 {return fmt.tprintf("%d", int(math.round(value)))}
	rounded := math.round(value / step) * step
	if step < 0.1 {return fmt.tprintf("%.2f", rounded)}
	return fmt.tprintf("%g", rounded)
}

// Wide ranges such as scrollback lines use a logarithmic track so small values stay reachable.
@(private)
slider_fraction :: proc(minimum, maximum, value: f64) -> f32 {
	span := maximum - minimum
	if span <= 0 {return 0}
	v := clamp(value, minimum, maximum)
	if span > 1000 {return f32(math.ln(v - minimum + 1) / math.ln(span + 1))}
	return f32((v - minimum) / span)
}

@(private)
slider_value :: proc(minimum, maximum: f64, fraction: f32) -> f64 {
	f := f64(clamp(fraction, 0, 1))
	span := maximum - minimum
	if span > 1000 {return minimum + math.exp(f * math.ln(span + 1)) - 1}
	return minimum + f * span
}

// A slider groove filled to `fraction` with its thumb, centred vertically in `track`.
@(private)
slider_draw :: proc(list: ^render.Draw_List, track: render.Rect, fraction: f32, theme: Theme, scale: f32) {
	cy := track.y + track.height / 2
	groove := render.Rect{track.x, cy - 2 * scale, track.width, 4 * scale}
	draw_rect(list, {rect = groove, color = theme.border, radius = RADIUS_MARK * scale})
	groove.width *= fraction
	draw_rect(list, {rect = groove, color = theme.accent, radius = RADIUS_MARK * scale})
	thumb := render.Rect{track.x + track.width * fraction - 7 * scale, cy - 7 * scale, 14 * scale, 14 * scale}
	draw_rect(list, {rect = thumb, color = theme.accent, radius = 7 * scale})
	draw_rect(list, {rect = thumb, color = theme.surface, radius = 7 * scale, stroke = 2 * scale})
}

// A setting's reset button: faint while the value is the default, lit under the pointer otherwise.
// A selected row already carries a tint, so the button adds only the rim there.
@(private)
reset_button_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	modified, hovered, selected: bool,
	pointer: [2]f32,
	scale: f32,
) -> render.Error {
	if hovered && modified {
		if !selected {draw_rect(list, {rect = rect, color = theme.hover, radius = RADIUS_CONTROL * scale})}
		radius := RADIUS_CONTROL * scale
		if err := hover_rim_draw(list, theme, rect, radius, 1, scale, pointer, !selected); err != .None {
			return err
		}
	}
	color := theme.faint
	if modified {
		color = hovered ? theme.text : theme.muted
	} else {
		color.a *= 0.5
	}
	icon_draw(list, .Undo, rect, color, ICON_BUTTON, scale)
	return .None
}

// Indexes of the choices whose label, or value when unlabelled, contains `query` ignoring case.
@(private)
choice_matches_filter :: proc(matches: ^[dynamic]int, choices, labels: []string, query: string) {
	clear(matches)
	needle := strings.to_lower(query, context.temp_allocator)
	for choice, i in choices {
		label := i < len(labels) && labels[i] != "" ? labels[i] : choice
		if strings.contains(strings.to_lower(label, context.temp_allocator), needle) {append(matches, i)}
	}
}
