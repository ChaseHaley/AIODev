package ui

import "aio:render"

// The surface every chrome button shares: the raised hover (lift, seat shadow, fill, rim light),
// the press fill and the ink for its content. `hover` and `press` are the animated 0..1 values from
// Control_Motion; `radius` is in DIPs. A `selected` toggle keeps its tint under the hover. A
// disabled button stays flat with faint ink. `press_color` replaces the default pressed fill.
Button :: struct {
	rect:        render.Rect,
	hover:       f32,
	press:       f32,
	radius:      f32,
	selected:    bool,
	disabled:    bool,
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
	radius := (b.radius > 0 ? b.radius : 6) * scale
	hover := b.disabled ? 0 : clamp(b.hover, 0, 1)
	press := b.disabled ? 0 : clamp(b.press, 0, 1)
	face = b.rect
	face.y -= hover_lift_at(theme, hover, scale)
	if hover > 0 {
		if err = hover_shadow_draw(list, theme, face, radius, hover, scale); err != .None {return}
	}
	if b.selected {draw_rect(list, {rect = face, color = theme.selection, radius = radius})}
	if !b.selected || !hover_fill_opaque(theme) {
		fill := theme.hover
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
	err = hover_rim_draw(list, theme, face, radius, hover, scale, pointer, !b.selected, compact = true)
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
	radius: f32 = 6,
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
