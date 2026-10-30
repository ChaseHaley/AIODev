package ui

import "aio:glyphs"
import "aio:render"

HEADER_HEIGHT :: f32(28)
Header_Action :: enum {
	None,
	Split_Right,
	Split_Down,
	Zoom,
	Close,
	Badge,
}
Header_Layout :: struct {
	panel, title, badge: render.Rect,
	buttons:             [4]render.Rect,
}

header_layout :: proc(area: render.Rect, scale: f32, _: bool) -> Header_Layout {
	l := Header_Layout {
		panel = {area.x, area.y, area.width, min(area.height, HEADER_HEIGHT * scale)},
	}
	l.badge = {area.x + 8 * scale, area.y + 7 * scale, 14 * scale, 14 * scale}
	end := area.x + area.width - 5 * scale
	{
		for i := 3; i >= 0; i -= 1 {
			if end - 22 * scale < area.x + 4 * scale {break}
			l.buttons[i] = {
				end - 22 * scale,
				area.y + 3 * scale,
				22 * scale,
				min(22 * scale, l.panel.height),
			}
			end -= 24 * scale
		}
	}
	l.title = {area.x + 28 * scale, area.y, max(0, end - area.x - 32 * scale), l.panel.height}
	return l
}

header_hit_test :: proc(l: Header_Layout, x, y: f32) -> Header_Action {
	for button, i in l.buttons {
		if button.width > 0 &&
		   x >= button.x &&
		   x < button.x + button.width &&
		   y >= button.y &&
		   y < button.y + button.height &&
		   x >= l.panel.x &&
		   x < l.panel.x + l.panel.width &&
		   y >= l.panel.y &&
		   y < l.panel.y + l.panel.height {return Header_Action(i + 1)}
	}
	// The badge's hover target extends a little past the glyph, but never outside the visible card.
	if l.badge.width > 0 && l.panel.width > 0 && l.panel.height > 0 {
		left := max(l.panel.x, l.badge.x - 3)
		top := max(l.panel.y, l.badge.y - 3)
		right := min(l.panel.x + l.panel.width, l.badge.x + l.badge.width + 9)
		bottom := min(l.panel.y + l.panel.height, l.badge.y + l.badge.height + 3)
		if x >= left && x < right && y >= top && y < bottom {return .Badge}
	}
	return .None
}

header_contains :: proc(l: Header_Layout, x, y: f32) -> bool {
	return(
		x >= l.panel.x &&
		x < l.panel.x + l.panel.width &&
		y >= l.panel.y &&
		y < l.panel.y + l.panel.height \
	)
}

shell_badge_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	icon: string,
	scale: f32,
	atlas: render.Rect = {},
) -> glyphs.Result {
	if atlas.width > 0 {
		r := area
		factor := min(area.width / atlas.width, area.height / atlas.height)
		r.width, r.height = atlas.width * factor, atlas.height * factor
		r.x, r.y = area.x + (area.width - r.width) / 2, area.y + (area.height - r.height) / 2
		if render.push_glyph(
			   list,
			   {rect = r, atlas = atlas, color = {1, 1, 1, 1}, flags = render.GLYPH_COLOR},
		   ) !=
		   .None {return .Ok}
		return .Ok
	}
	draw_rect(list, {rect = area, color = theme.selection, radius = 3 * scale})
	label := text_styled(text, .Keycap)
	x := area.x + max(0, (area.width - text_width(&label, icon)) / 2)
	return draw_fading_text(
		&label,
		list,
		icon,
		x,
		area.y + (area.height - label.line_height) / 2 + label.ascent,
		theme.accent,
		max(0, area.width - 2 * scale),
	)
}

@(private)
header_icon :: proc(action: Header_Action, zoomed: bool) -> Icon {
	#partial switch action {
	case .Split_Down:
		return .Split_Down
	case .Zoom:
		return zoomed ? .Restore : .Zoom
	case .Close:
		return .Close
	}
	return .Split_Right
}

header_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	background: render.Color,
	radius, scale: f32,
	title, directory, icon: string,
	focused: bool,
	controls: [4]Control_Motion,
	zoomed := false,
	icon_atlas: render.Rect = {},
	badge_hovered := false,
	pointer: [2]f32 = {},
	status: Status_Mark = {},
	status_text: string = "",
	status_phase: f32 = 0,
) -> glyphs.Result {
	l := header_layout(area, scale, focused)
	if render.push_layer(list, area, radius) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = background})
	draw_rect(
		list,
		{
			rect = {area.x, l.panel.y + l.panel.height - scale, area.width, scale},
			color = theme.border,
		},
	)
	if render.push_layer(list, l.panel) != .None {return .Ok}
	if l.title.width > 0 && l.badge.x + l.badge.width <= area.x + area.width {
		if result := shell_badge_draw(list, text, theme, l.badge, icon, scale, icon_atlas);
		   result != .Ok {return result}
	}
	if badge_hovered {
		chevron := render.Rect{l.badge.x + l.badge.width, l.badge.y, ICON_INDICATOR * scale, l.badge.height}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
		// The badge carries its own tinted keycap, so it takes the light but no paper hairline.
		if result := hover_rim_draw(list, theme, l.badge, 4 * scale, 1, scale, pointer, false);
		   result != .None {return .Ok}
	}
	strong := text_styled(text, focused ? .Strong : .Body)
	small := text_styled(text, .Small)
	width := l.title.width
	if status.glyph != .None && width >= 120 * scale {
		pill_width := min(text_width(&small, status_text) + 30 * scale, width * 0.5)
		pill := render.Rect {
			l.title.x + width - pill_width,
			l.panel.y + 5 * scale,
			pill_width,
			max(0, l.panel.height - 10 * scale),
		}
		tint := status_color(theme, status.glyph)
		tint.a *= status.dim ? 0.08 : 0.16
		draw_rect(list, {rect = pill, color = tint, radius = pill.height / 2})
		if result := status_glyph_draw(
			list,
			text,
			theme,
			{pill.x + 6 * scale, pill.y + (pill.height - 12 * scale) / 2, 12 * scale, 12 * scale},
			status,
			status_phase,
			scale,
		); result != .Ok {return result}
		ink := theme.muted
		if status_blocked(status.glyph) || status.glyph == .Error {ink = status_color(theme, status.glyph)}
		if result := draw_fading_text(
			&small,
			list,
			status_text,
			pill.x + 22 * scale,
			pill.y + (pill.height - small.line_height) / 2 + small.ascent,
			ink,
			max(0, pill.width - 28 * scale),
		); result != .Ok {return result}
		width = max(0, width - pill_width - 8 * scale)
	}
	title_width := directory == "" ? width : min(width * 0.55, text_width(&strong, title))
	baseline := l.panel.y + (l.panel.height - strong.line_height) / 2 + strong.ascent
	if result := draw_fading_text(
		&strong,
		list,
		title,
		l.title.x,
		baseline,
		focused ? theme.text : theme.muted,
		title_width,
	); result != .Ok {return result}
	if directory != "" && width > title_width + 8 * scale {
		if result := draw_fading_text(
			&small,
			list,
			directory,
			l.title.x + title_width + 8 * scale,
			baseline,
			theme.faint,
			width - title_width - 8 * scale,
		); result != .Ok {return result}
	}
	for button, i in l.buttons {
		if button.width == 0 {continue}
		hover := controls[i].hover.value
		b := button
		b.y -= hover_lift_at(theme, hover, scale)
		if hover > 0 {
			if result := hover_shadow_draw(list, theme, b, 6 * scale, hover, scale);
			   result != .None {return .Ok}
		}
		fill := theme.hover
		fill.a *= hover
		draw_rect(list, {rect = b, color = fill, radius = 6 * scale})
		fill = i == 3 ? theme.error : theme.pressed
		fill.a *= controls[i].press.value * (i == 3 ? 0.14 : 1)
		draw_rect(list, {rect = b, color = fill, radius = 6 * scale})
		ink := hover > 0 ? theme.text : theme.muted
		icon_draw(list, header_icon(Header_Action(i + 1), zoomed), b, ink, ICON_BUTTON, scale)
		if result := hover_rim_draw(list, theme, b, 6 * scale, hover, scale, pointer);
		   result != .None {return .Ok}
	}
	return .Ok
}


// Single-pane tabs keep their full terminal height, so their split controls float in a small pill at the
// pane's top-right corner instead of a header row.
split_overlay_layout :: proc(area: render.Rect, scale: f32) -> Header_Layout {
	width, height := 80 * scale, 28 * scale
	l := Header_Layout {
		panel = {
			max(area.x, area.x + area.width - width - 6 * scale),
			area.y + 6 * scale,
			min(width, area.width),
			min(height, area.height),
		},
	}
	l.title = {l.panel.x + 3 * scale, l.panel.y + 3 * scale, 26 * scale, 22 * scale}
	l.buttons[0] = {l.panel.x + 31 * scale, l.panel.y + 3 * scale, 22 * scale, 22 * scale}
	l.buttons[1] = {l.panel.x + 55 * scale, l.panel.y + 3 * scale, 22 * scale, 22 * scale}
	return l
}

split_overlay_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Header_Layout,
	controls: [4]Control_Motion,
	scale: f32,
	pointer: [2]f32 = {},
) -> glyphs.Result {
	if render.push_layer(list, l.panel, 8 * scale) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = theme.surface, radius = 8 * scale})
	draw_rect(list, {rect = l.panel, color = theme.border, radius = 8 * scale, stroke = scale})
	icon_draw(list, .Grip, l.title, theme.muted, ICON_BUTTON, scale)
	buttons := l.buttons
	for &button, i in buttons[:2] {
		hover := controls[i].hover.value
		button.y -= hover_lift_at(theme, hover, scale)
		if hover > 0 {
			if result := hover_shadow_draw(list, theme, button, 6 * scale, hover, scale);
			   result != .None {return .Ok}
		}
		fill := theme.hover
		fill.a *= hover
		draw_rect(list, {rect = button, color = fill, radius = 6 * scale})
		fill = theme.pressed
		fill.a *= controls[i].press.value
		draw_rect(list, {rect = button, color = fill, radius = 6 * scale})
		ink := hover > 0 ? theme.text : theme.muted
		icon_draw(list, header_icon(Header_Action(i + 1), false), button, ink, ICON_BUTTON, scale)
		if result := hover_rim_draw(list, theme, button, 6 * scale, hover, scale, pointer);
		   result != .None {return .Ok}
	}
	return .Ok
}
