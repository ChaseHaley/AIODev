package ui

import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "core:time"

Confirm_Button :: enum {
	None,
	Option,
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
	using presence: Presence,
	focus, hover:   Confirm_Button,
	armed:          Armed(Confirm_Button),
	extended:       bool,
	show_option:    bool,
	option:         bool,
}

Confirm_Layout :: struct {
	panel, option, cancel, accept: render.Rect,
}

@(private)
CONFIRM_WIDTH :: 380
@(private)
CONFIRM_HEIGHT :: 150
@(private)
CONFIRM_BUTTON_WIDTH :: 96
@(private)
CONFIRM_BUTTON_HEIGHT :: 30
@(private)
CONFIRM_PRESENCE :: Presence_Spec {
	open  = 120 * time.Millisecond,
	close = 90 * time.Millisecond,
}

confirm_open :: proc(c: ^Confirm) {
	presence_open(&c.presence, CONFIRM_PRESENCE)
	c.focus, c.hover = .Accept, .None
	armed_cancel(&c.armed)
}

confirm_close :: proc(c: ^Confirm) {
	presence_close(&c.presence)
	c.hover = .None
	armed_cancel(&c.armed)
}

confirm_layout :: proc(width, height, scale: f32, extended := false, show_option := false) -> Confirm_Layout {
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
	option := render.Rect{}
	if show_option {
		option = {
			panel.x + 16 * s,
			y,
			max(0, cancel.x - 8 * s - panel.x - 16 * s),
			CONFIRM_BUTTON_HEIGHT * s,
		}
	}
	return {panel, option, cancel, accept}
}

confirm_hit :: proc(l: Confirm_Layout, x, y: f32) -> Confirm_Button {
	if l.option.width > 0 && contains(l.option, x, y) {return .Option}
	if contains(l.accept, x, y) {return .Accept}
	if contains(l.cancel, x, y) {return .Cancel}
	return .None
}

confirm_contains :: proc(l: Confirm_Layout, x, y: f32) -> bool {return contains(l.panel, x, y)}

@(private)
confirm_cycle :: proc(c: ^Confirm, step: int) {
	order: [3]Confirm_Button
	count := 0
	if c.show_option {
		order[count] = .Option
		count += 1
	}
	order[count], order[count + 1] = .Cancel, .Accept
	count += 2
	index := 0
	for button, i in order[:count] {if button == c.focus {index = i}}
	index = (index + step + count) % count
	c.focus = order[index]
}

confirm_key :: proc(c: ^Confirm, e: platform.Key_Event) -> Confirm_Outcome {
	if !e.pressed {return .None}
	if c.show_option && .Alt in e.modifiers && e.key == .D {
		c.option = !c.option
		c.focus = .Option
		return .Changed
	}
	#partial switch e.key {
	case .Escape:
		return .Cancel
	case .Enter, .Numpad_Enter:
		return c.focus == .Cancel ? .Cancel : .Accept
	case .Space:
		if c.focus == .Option {
			c.option = !c.option
			return .Changed
		}
		return c.focus == .Cancel ? .Cancel : .Accept
	case .Tab:
		confirm_cycle(c, .Shift in e.modifiers ? -1 : 1)
		return .Changed
	case .Arrow_Left, .Arrow_Up:
		confirm_cycle(c, -1)
		return .Changed
	case .Arrow_Right, .Arrow_Down:
		confirm_cycle(c, 1)
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
		if hit == .Option {
			c.option = !c.option
			c.focus = .Option
			return .Changed
		}
		if hit == .None && !confirm_contains(l, x, y) {return .Cancel}
		armed_press(&c.armed, hit)
		if hit != .None {c.focus = hit}
		return .Changed
	}
	fired, ok := armed_release(&c.armed, hit)
	if ok && fired != .None {return fired == .Accept ? .Accept : .Cancel}
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
	active := armed_is(c.armed, button)
	fill := accept ? theme.error : theme.border
	if !accept && active {fill = theme.pressed} else if !accept && c.hover == button {
		fill = theme.hover
	}
	draw_rect(list, {rect = r, color = fill, radius = 6 * scale})
	if accept && (c.hover == button || active) {
		draw_rect(
			list,
			{
				rect = r,
				color = active ? theme.pressed : theme.hover,
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
	note: string,
	option_label: string = "",
) -> glyphs.Result {
	l := confirm_layout(width, height, scale, c.extended)
	s := scale
	if render.push_layer(list, {0, 0, width, height}) != .None {return .Ok}
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	p := l.panel
	frame := Panel {
		rect     = p,
		radius   = 10 * s,
		scale    = s,
		shadow_y = 12,
		softness = 32,
		border   = .Expanded,
	}
	if panel_draw(list, frame, theme) != .None {return .Ok}
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
	if c.show_option && option_label != "" {
		box := render.Rect {
			l.option.x,
			l.option.y + (l.option.height - 15 * s) / 2,
			15 * s,
			15 * s,
		}
		draw_rect(list, {rect = box, color = theme.border, radius = 3 * s})
		if c.option {
			draw_rect(list, {rect = box, color = theme.accent, radius = 3 * s})
			if r := draw_glyph_centered(&small, list, '✓', box, theme.accent_text);
			   r != .Ok {return r}
		}
		if c.focus == .Option {focus_ring_draw(list, box, theme, s)}
		if r := draw_text(
			&small,
			list,
			option_label,
			box.x + 23 * s,
			box.y + (box.height - small.line_height) / 2 + small.ascent,
			theme.muted,
			max(0, l.option.width - 26 * s),
		); r != .Ok {return r}
	}
	if r := confirm_button_draw(c, list, text, theme, l.cancel, .Cancel, "Cancel", s);
	   r != .Ok {return r}
	return confirm_button_draw(c, list, text, theme, l.accept, .Accept, accept_label, s)
}
