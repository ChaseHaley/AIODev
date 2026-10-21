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
header_icon_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	area: render.Rect,
	action: Header_Action,
	color: render.Color,
	scale: f32,
	zoomed: bool,
) -> glyphs.Result {
	x, y := area.x + 5 * scale, area.y + 5 * scale
	stroke := 1.5 * scale
	switch action {
	case .Split_Right, .Split_Down:
		draw_rect(
			list,
			{
				rect = {x, y, 12 * scale, 12 * scale},
				color = color,
				radius = scale,
				stroke = stroke,
			},
		)
		line :=
			action == .Split_Right ? render.Rect{x + 6 * scale, y, stroke, 12 * scale} : render.Rect{x, y + 6 * scale, 12 * scale, stroke}
		draw_rect(list, {rect = line, color = color})
	case .Zoom:
		if zoomed {
			draw_rect(
				list,
				{rect = {x + 3 * scale, y, 9 * scale, 9 * scale}, color = color, stroke = stroke},
			)
			draw_rect(
				list,
				{rect = {x, y + 3 * scale, 9 * scale, 9 * scale}, color = color, stroke = stroke},
			)
			return .Ok
		}
		for ox in ([?]f32{0, 8}) {
			for oy in ([?]f32{0, 8}) {
				draw_rect(
					list,
					{
						rect = {
							x + ox * scale,
							y + (oy == 0 ? 0 : 12) * scale - (oy == 0 ? 0 : stroke),
							4 * scale,
							stroke,
						},
						color = color,
					},
				)
				draw_rect(
					list,
					{
						rect = {
							x + (ox == 0 ? 0 : 12) * scale - (ox == 0 ? 0 : stroke),
							y + oy * scale,
							stroke,
							4 * scale,
						},
						color = color,
					},
				)
			}
		}
	case .Close:
		large := text^
		text_set_size(&large, text.size_px * 1.5)
		return draw_glyph_centered(&large, list, '×', area, color)
	case .None:
	}
	return .Ok
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
	strong := text_styled(text, focused ? .Strong : .Body)
	small := text_styled(text, .Small)
	width := l.title.width
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
		fill := theme.hover
		fill.a *= controls[i].hover.value
		draw_rect(list, {rect = button, color = fill, radius = 6 * scale})
		fill = i == 3 ? theme.error : theme.pressed
		fill.a *= controls[i].press.value * (i == 3 ? 0.14 : 1)
		draw_rect(list, {rect = button, color = fill, radius = 6 * scale})
		if result := header_icon_draw(
			list,
			text,
			button,
			Header_Action(i + 1),
			controls[i].hover.value > 0 ? theme.text : theme.muted,
			scale,
			zoomed,
		); result != .Ok {return result}
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
) -> glyphs.Result {
	if render.push_layer(list, l.panel, 8 * scale) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = theme.surface, radius = 8 * scale})
	draw_rect(list, {rect = l.panel, color = theme.border, radius = 8 * scale, stroke = scale})
	if result := draw_glyph_centered(text, list, '⠿', l.title, theme.muted);
	   result != .Ok {return result}
	buttons := l.buttons
	for button, i in buttons[:2] {
		fill := theme.hover
		fill.a *= controls[i].hover.value
		draw_rect(list, {rect = button, color = fill, radius = 6 * scale})
		fill = theme.pressed
		fill.a *= controls[i].press.value
		draw_rect(list, {rect = button, color = fill, radius = 6 * scale})
		if result := header_icon_draw(
			list,
			text,
			button,
			Header_Action(i + 1),
			controls[i].hover.value > 0 ? theme.text : theme.muted,
			scale,
			false,
		); result != .Ok {return result}
	}
	return .Ok
}
