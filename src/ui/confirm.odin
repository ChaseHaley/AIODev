package ui

import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"

Confirm_Button :: enum {
	None,
	Cancel,
	Accept,
}

Confirm_Outcome :: enum {
	None,
	Changed,
	Cancel,
	Accept,
}

// A modal question with Cancel and Accept buttons. Accept has the keyboard first so Enter confirms.
Confirm :: struct {
	open:                  bool,
	focus, hover, pressed: Confirm_Button,
	motion:                Motion,
	extended:              bool,
}

Confirm_Layout :: struct {
	panel, cancel, accept: render.Rect,
}

@(private)
CONFIRM_WIDTH :: 380
@(private)
CONFIRM_HEIGHT :: 150
@(private)
CONFIRM_BUTTON_WIDTH :: 96
@(private)
CONFIRM_BUTTON_HEIGHT :: 30

confirm_open :: proc(c: ^Confirm) {
	c.open, c.focus, c.hover, c.pressed = true, .Accept, .None, .None
}

confirm_close :: proc(c: ^Confirm) {
	c.open, c.hover, c.pressed = false, .None, .None
}

confirm_layout :: proc(width, height, scale: f32, extended := false) -> Confirm_Layout {
	s := scale
	panel_width := min((extended ? 540 : CONFIRM_WIDTH) * s, max(0, width - 32 * s))
	panel := render.Rect {
		(width - panel_width) / 2,
		max(24 * s, height * 0.22),
		panel_width,
		CONFIRM_HEIGHT * s,
	}
	y := panel.y + panel.height - 16 * s - CONFIRM_BUTTON_HEIGHT * s
	accept := render.Rect {
		panel.x + panel.width - 16 * s - CONFIRM_BUTTON_WIDTH * s,
		y,
		CONFIRM_BUTTON_WIDTH * s,
		CONFIRM_BUTTON_HEIGHT * s,
	}
	cancel := accept
	cancel.x -= CONFIRM_BUTTON_WIDTH * s + 8 * s
	return {panel, cancel, accept}
}

confirm_hit :: proc(l: Confirm_Layout, x, y: f32) -> Confirm_Button {
	if contains(l.accept, x, y) {return .Accept}
	if contains(l.cancel, x, y) {return .Cancel}
	return .None
}

confirm_contains :: proc(l: Confirm_Layout, x, y: f32) -> bool {return contains(l.panel, x, y)}

confirm_key :: proc(c: ^Confirm, e: platform.Key_Event) -> Confirm_Outcome {
	if !e.pressed {return .None}
	#partial switch e.key {
	case .Escape:
		return .Cancel
	case .Enter, .Numpad_Enter, .Space:
		return c.focus == .Cancel ? .Cancel : .Accept
	case .Tab, .Arrow_Left, .Arrow_Right:
		c.focus = c.focus == .Accept ? .Cancel : .Accept
		return .Changed
	}
	return .None
}

// Pointer presses arm a button; the release activates it only over the same button.
confirm_mouse :: proc(
	c: ^Confirm,
	l: Confirm_Layout,
	button: input.Mouse_Button,
	pressed: bool,
	x, y: f32,
) -> Confirm_Outcome {
	if button != .Left {return .None}
	hit := confirm_hit(l, x, y)
	if pressed {
		if hit == .None && !confirm_contains(l, x, y) {return .Cancel}
		c.pressed = hit
		if hit != .None {c.focus = hit}
		return .Changed
	}
	armed := c.pressed
	c.pressed = .None
	if armed != .None && armed == hit {return hit == .Accept ? .Accept : .Cancel}
	return .Changed
}

confirm_hover :: proc(c: ^Confirm, l: Confirm_Layout, x, y: f32) -> bool {
	hit := confirm_hit(l, x, y)
	if hit == c.hover {return false}
	c.hover = hit
	return true
}

@(private)
confirm_button_draw :: proc(
	c: ^Confirm,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	r: render.Rect,
	button: Confirm_Button,
	label: string,
	scale: f32,
) -> glyphs.Result {
	accept := button == .Accept
	fill := accept ? theme.error : theme.border
	if !accept &&
	   c.pressed ==
		   button {fill = theme.pressed} else if !accept && c.hover == button {fill = theme.hover}
	draw_rect(list, {rect = r, color = fill, radius = 6 * scale})
	if accept && (c.hover == button || c.pressed == button) {
		draw_rect(
			list,
			{
				rect = r,
				color = c.pressed == button ? theme.pressed : theme.hover,
				radius = 6 * scale,
			},
		)
	}
	if c.focus == button {focus_ring_draw(list, r, theme, scale)}
	strong := text_styled(text, .Strong)
	color := accept ? theme.accent_text : theme.text
	return draw_text(
		&strong,
		list,
		label,
		r.x + (r.width - text_width(&strong, label)) / 2,
		r.y + (r.height - strong.line_height) / 2 + strong.ascent,
		color,
		r.width - 8 * scale,
	)
}

confirm_draw :: proc(
	c: ^Confirm,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
	title, body, accept_label: string,
	note := "Turn this off with Confirm Closing Split Tabs in Settings.",
) -> glyphs.Result {
	l := confirm_layout(width, height, scale, c.extended)
	s := scale
	if render.push_layer(list, {0, 0, width, height}) != .None {return .Ok}
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	p := l.panel
	draw_rect(
		list,
		{
			rect = {p.x, p.y + 12 * s, p.width, p.height},
			color = theme.shadow,
			radius = 10 * s,
			softness = 32 * s,
		},
	)
	draw_rect(
		list,
		{
			rect = {p.x - s, p.y - s, p.width + 2 * s, p.height + 2 * s},
			color = theme.border,
			radius = 11 * s,
		},
	)
	draw_rect(list, {rect = p, color = theme.surface, radius = 10 * s})
	strong := text_styled(text, .Strong)
	text_set_size(&strong, strong.size_px * 1.15)
	inner := p.width - 40 * s
	if r := draw_fading_text(
		&strong,
		list,
		title,
		p.x + 20 * s,
		p.y + 20 * s + strong.ascent,
		theme.text,
		inner,
	); r != .Ok {
		return r
	}
	small := text_styled(text, .Small)
	if r := draw_text(
		text,
		list,
		body,
		p.x + 20 * s,
		p.y + 54 * s + text.ascent,
		theme.muted,
		inner,
	); r != .Ok {
		return r
	}
	if r := draw_fading_text(
		&small,
		list,
		note,
		p.x + 20 * s,
		p.y + 78 * s + small.ascent,
		theme.faint,
		inner,
	); r != .Ok {return r}
	if r := confirm_button_draw(c, list, text, theme, l.cancel, .Cancel, "Cancel", s);
	   r != .Ok {return r}
	return confirm_button_draw(c, list, text, theme, l.accept, .Accept, accept_label, s)
}
