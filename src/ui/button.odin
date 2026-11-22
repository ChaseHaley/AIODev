package ui

import "cosmos:render"

// How a button's surface answers the hover. A raised button lifts on a seat shadow; a flat one stays
// in place, for a control that is itself a whole surface such as a float header. An unfilled flat
// button also leaves out the hover fill, for a control already drawn on its own panel.
Button_Surface :: enum u8 {
	Raised,
	Flat,
	Flat_Unfilled,
}

// The surface every chrome button shares: the hover (lift, seat shadow, fill, rim light), the press
// fill and the ink for its content. `hover` and `press` are the animated 0..1 values from
// Control_Motion; `radius` is in DIPs, RADIUS_BUTTON when zero. A `selected` toggle keeps its tint
// under the hover. A disabled button stays flat with faint ink. `press_color` replaces the default
// pressed fill. An `on_tint` button sits inside a tinted surface such as a selected row: an opaque
// hover fill would punch a hole in that tint, so there it takes the lift and the light without the
// fill or the hairline.
Button :: struct {
	rect:        render.Rect,
	hover:       f32,
	press:       f32,
	radius:      f32,
	surface:     Button_Surface,
	selected:    bool,
	disabled:    bool,
	on_tint:     bool,
	press_color: Maybe(render.Color),
}

// Draws the surface and returns where its content goes, lifted with the hover, and the ink for it.
// The rim lives on the rounded edge, so content drawn afterwards never covers it.
button_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	b: Button,
	scale: f32,
	pointer: [2]f32,
) -> (
	face: render.Rect,
	ink: render.Color,
	err: render.Error,
) {
	radius := (b.radius > 0 ? b.radius : RADIUS_BUTTON) * scale
	hover := b.disabled ? 0 : clamp(b.hover, 0, 1)
	press := b.disabled ? 0 : clamp(b.press, 0, 1)
	face = b.rect
	if b.surface == .Raised {
		face.y -= hover_lift_at(theme, hover, scale)
		if hover > 0 {
			if err = hover_shadow_draw(list, theme, face, radius, hover, scale); err != .None {return}
		}
	}
	if b.selected {draw_rect(list, {rect = face, color = theme.selection, radius = radius})}
	keep_tint := (b.selected || b.on_tint) && hover_fill_opaque(theme)
	if !keep_tint {
		fill := b.surface == .Flat_Unfilled ? render.Color{} : theme.hover
		fill.a *= hover
		draw_rect(list, {rect = face, color = fill, radius = radius})
	}
	fill := b.press_color.? or_else theme.pressed
	fill.a *= press
	draw_rect(list, {rect = face, color = fill, radius = radius})
	switch {
	case b.disabled:
		ink = theme.faint
	case hover > 0 || press > 0 || b.selected:
		ink = theme.text
	case:
		ink = theme.muted
	}
	edge := !b.selected && !keep_tint
	err = hover_rim_draw(list, theme, face, radius, hover, scale, pointer, edge, compact = true)
	return
}

// Draws an icon button with the raised hover. `hover` and `press` run from 0 to 1; `radius` is in
// DIPs. The icon is `text.muted` at rest and `text` while hovered or pressed.
icon_button_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	rect: render.Rect,
	icon: Icon,
	hover, press, scale: f32,
	pointer: [2]f32,
	size := ICON_BUTTON,
	radius := RADIUS_BUTTON,
) -> render.Error {
	b := Button {
		rect   = rect,
		hover  = hover,
		press  = press,
		radius = radius,
	}
	face, ink, err := button_draw(list, theme, b, scale, pointer)
	icon_draw(list, icon, face, ink, size, scale)
	return err
}

// The checkbox of a confirmation option and of a Markdown task item, at `x` and centred in the band
// from `top` that is `height` tall.
checkbox_rect :: proc(x, top, height, scale: f32) -> render.Rect {
	size := CHECKBOX_SIZE * scale
	return {x, top + (height - size) / 2, size, size}
}

checkbox_draw :: proc(list: ^render.Draw_List, box: render.Rect, checked: bool, theme: Theme, scale: f32) {
	checkbox_paint(list, box, checked, checked ? theme.accent : theme.border, theme.accent_text, scale)
}

// A checkbox in the given colours: `fill` is its box and `tick` the mark of a checked one.
checkbox_paint :: proc(
	list: ^render.Draw_List,
	box: render.Rect,
	checked: bool,
	fill, tick: render.Color,
	scale: f32,
) {
	draw_rect(list, {rect = box, color = fill, radius = RADIUS_CONTROL * scale})
	if checked && tick.a > 0 {icon_draw(list, .Check, box, tick, ICON_INDICATOR, scale)}
}

// A secondary text button: the raised surface with a hairline border and a centred label. The
// pointer light shows while the pointer is over it; `focused` draws the keyboard focus ring.
text_button_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	label: string,
	focused: bool,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if rect.width <= 0 {return .Ok}
	radius := RADIUS_CONTROL * scale
	draw_rect(list, {rect = rect, color = theme.surface, radius = radius})
	draw_rect(list, {rect = rect, color = theme.border, radius = radius, stroke = scale})
	if focused {focus_ring_draw(list, rect, theme, scale)}
	if render.rect_contains(rect, pointer.x, pointer.y) {
		if hover_rim_draw(list, theme, rect, radius, 1, scale, pointer, true) != .None {return .Ok}
	}
	inset := CONTROL_INSET * scale
	width := min(text_width(text, label), max(0, rect.width - 2 * inset))
	return draw_text(
		text,
		list,
		label,
		rect.x + (rect.width - width) / 2,
		rect.y + (rect.height - text.line_height) / 2 + text.ascent,
		theme.text,
		max(1, rect.width - 2 * inset),
	)
}

// The one call to action of a surface: an accent button with a Strong label. `hover` and `press` are
// the animated 0..1 values from Control_Motion.
primary_button_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	label: string,
	hover, press: f32,
	focused: bool,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	return filled_button_draw(
		list, text, theme, rect, label, theme.accent, theme.accent_text, hover, press, focused, scale, pointer,
	)
}

// A button filled with `fill` and labelled in `ink`, as the primary button is in the accent; a notice's
// action takes its severity colour. The hover lightens with the ink colour, because the theme's hover
// fill is paper in light mode and would hide the fill.
filled_button_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	rect: render.Rect,
	label: string,
	fill, ink: render.Color,
	hover, press: f32,
	focused: bool,
	scale: f32,
	pointer: [2]f32,
) -> render.Build_Status {
	if rect.width <= 0 {return .Ok}
	radius := RADIUS_CONTROL * scale
	h, p := clamp(hover, 0, 1), clamp(press, 0, 1)
	face := rect
	face.y -= hover_lift_at(theme, h, scale)
	if h > 0 {
		if hover_shadow_draw(list, theme, face, radius, h, scale) != .None {return .Ok}
	}
	draw_rect(list, {rect = face, color = fill, radius = radius})
	lighten := ink
	lighten.a *= PRIMARY_HOVER_ALPHA * h
	draw_rect(list, {rect = face, color = lighten, radius = radius})
	dim := theme.pressed
	dim.a *= p
	draw_rect(list, {rect = face, color = dim, radius = radius})
	if focused {focus_ring_draw(list, face, theme, scale)}
	if h > 0 {
		if hover_rim_draw(list, theme, face, radius, h, scale, pointer, false) != .None {return .Ok}
	}
	strong := text_styled(text, .Strong)
	inset := CONTROL_INSET * scale
	width := min(text_width(&strong, label), max(0, face.width - 2 * inset))
	return draw_text(
		&strong,
		list,
		label,
		face.x + (face.width - width) / 2,
		face.y + (face.height - strong.line_height) / 2 + strong.ascent,
		ink,
		max(1, face.width - 2 * inset),
	)
}

@(private = "file")
PRIMARY_HOVER_ALPHA :: f32(0.14)
