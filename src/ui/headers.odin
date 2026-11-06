package ui

import "aio:glyphs"
import "aio:render"

HEADER_HEIGHT :: HEIGHT_TOOLBAR
// One slot per Header_Action from Documents through Close, in that order, left to right. A tiled pane's
// header leaves the floating slots empty, and a floating pane's header leaves the tiling slots empty.
HEADER_BUTTONS :: 9
@(private = "file")
HEADER_TITLE_MINIMUM :: f32(40)
Header_Action :: enum {
	None,
	Documents,
	Split_Right,
	Split_Down,
	Zoom,
	Fill_Window,
	Linked_Window,
	Minimize,
	Dock,
	Close,
	Badge,
}
Header_Layout :: struct {
	panel, title, badge: render.Rect,
	buttons:             [HEADER_BUTTONS]render.Rect,
	// Sets the Documents button apart from the controls for the pane itself.
	divider:             render.Rect,
}

// A hairline with SPACE_1 either side.
@(private = "file")
header_divider :: proc(next: render.Rect, panel_y, panel_height, scale: f32) -> render.Rect {
	height := min(ICON_BUTTON * scale, panel_height)
	return {next.x - SPACE_1 * scale - scale, panel_y + (panel_height - height) / 2, scale, height}
}

// How a pane's Documents button shows. A pane that takes no pins has no button.
Header_Documents :: struct {
	shown, open: bool,
}

// Whether a header shows the action's button: a floating pane has no split or view controls, and only it
// can be minimized or docked.
@(private = "file")
header_shows :: proc(action: Header_Action, floating: bool) -> bool {
	#partial switch action {
	case .Documents, .Close:
		return true
	case .Minimize, .Dock:
		return floating
	}
	return !floating
}

header_layout :: proc(area: render.Rect, scale: f32, documents := true, floating := false) -> Header_Layout {
	l := Header_Layout {
		panel = {area.x, area.y, area.width, min(area.height, HEADER_HEIGHT * scale)},
	}
	// The badge and the last button's icon both sit SPACE_2 from the card's edges.
	badge := ICON_BUTTON * scale
	l.badge = {area.x + SPACE_2 * scale, area.y + (l.panel.height - badge) / 2, badge, badge}
	button := HEIGHT_COMPACT * scale
	end := area.x + area.width - SPACE_1 * scale
	{
		placed: render.Rect
		for i := len(l.buttons) - 1; i >= 0; i -= 1 {
			if !header_shows(Header_Action(i + 1), floating) {continue}
			if i == int(Header_Action.Documents) - 1 {
				// It gives way first, so a narrow pane keeps its badge, some title and its own controls.
				gap := 2 * SPACE_1 * scale + scale
				title_end := area.x + (SPACE_2 + ICON_BUTTON + SPACE_2 + HEADER_TITLE_MINIMUM) * scale
				if !documents || end - gap - button < title_end {break}
				l.divider = header_divider(placed, l.panel.y, l.panel.height, scale)
				end -= gap
			}
			if end - button < area.x + SPACE_1 * scale {break}
			l.buttons[i] = {
				end - button,
				area.y + max(0, (l.panel.height - button) / 2),
				button,
				min(button, l.panel.height),
			}
			placed = l.buttons[i]
			end -= button
		}
	}
	title_x := l.badge.x + l.badge.width + SPACE_2 * scale
	l.title = {title_x, area.y, max(0, end - SPACE_2 * scale - title_x), l.panel.height}
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
	draw_rect(list, {rect = area, color = theme.selection, radius = RADIUS_CONTROL * scale})
	label := text_styled(text, .Detail)
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
header_icon :: proc(action: Header_Action, zoomed, fullscreen, linked: bool) -> Icon {
	#partial switch action {
	case .Documents:
		return .Document
	case .Split_Down:
		return .Split_Down
	case .Zoom:
		return zoomed ? .Collapse : .Expand
	case .Fill_Window:
		return fullscreen ? .Restore : .Zoom
	case .Linked_Window:
		return linked ? .Window_In : .Window_Out
	case .Minimize:
		return .Minimize
	case .Dock:
		return .Layout_Right
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
	controls: [HEADER_BUTTONS]Control_Motion,
	zoomed := false,
	fullscreen := false,
	linked := false,
	icon_atlas: render.Rect = {},
	badge_hovered := false,
	pointer: [2]f32 = {},
	status: Status_Mark = {},
	status_text: string = "",
	status_phase: f32 = 0,
	content_icon: Icon = .None,
	documents: Header_Documents = {shown = true},
	floating := false,
) -> glyphs.Result {
	l := header_layout(area, scale, documents.shown, floating)
	if render.push_layer(list, area, radius) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = background})
	if render.push_layer(list, l.panel) != .None {return .Ok}
	if l.title.width > 0 && l.badge.x + l.badge.width <= area.x + area.width {
		if content_icon != .None {
			icon_draw(list, content_icon, l.badge,
				focused ? theme.text : theme.muted, ICON_BUTTON, scale)
		} else if result := shell_badge_draw(list, text, theme, l.badge, icon, scale, icon_atlas);
		   result != .Ok {return result}
	}
	if badge_hovered {
		chevron := render.Rect{l.badge.x + l.badge.width, l.badge.y, ICON_INDICATOR * scale, l.badge.height}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
		// The badge carries its own tinted keycap, so it takes the light but no paper hairline.
		if result := hover_rim_draw(list, theme, l.badge, RADIUS_CONTROL * scale, 1, scale, pointer, false);
		   result != .None {return .Ok}
	}
	strong := text_styled(text, focused ? .Strong : .Body)
	small := text_styled(text, .Detail)
	width := l.title.width
	if status.glyph != .None && width >= 120 * scale {
		// A pill pads its ends by SPACE_2: glyph, SPACE_1, then the status text.
		pill_width := min(text_width(&small, status_text) + (SPACE_2 + 12 + SPACE_1 + SPACE_2) * scale, width * 0.5)
		pill := render.Rect {
			l.title.x + width - pill_width,
			l.panel.y + SPACE_1 * scale,
			pill_width,
			max(0, l.panel.height - 2 * SPACE_1 * scale),
		}
		tint := status_color(theme, status.glyph)
		tint.a *= status.dim ? 0.08 : 0.16
		draw_rect(list, {rect = pill, color = tint, radius = pill.height / 2})
		if result := status_glyph_draw(
			list,
			text,
			theme,
			{pill.x + SPACE_2 * scale, pill.y + (pill.height - 12 * scale) / 2, 12 * scale, 12 * scale},
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
			pill.x + (SPACE_2 + 12 + SPACE_1) * scale,
			pill.y + (pill.height - small.line_height) / 2 + small.ascent,
			ink,
			max(0, pill.width - (SPACE_2 + 12 + SPACE_1 + SPACE_2) * scale),
		); result != .Ok {return result}
		width = max(0, width - pill_width - SPACE_2 * scale)
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
		b := Button {
			rect  = button,
			hover = controls[i].hover.value,
			press = controls[i].press.value,
		}
		// Close presses in a faint error tint rather than the neutral pressed fill.
		if Header_Action(i + 1) == .Close {
			danger := theme.error
			danger.a *= 0.14
			b.press_color = danger
		}
		if Header_Action(i + 1) == .Documents {b.selected = documents.open}
		face, ink, err := button_draw(list, theme, b, scale, pointer)
		if err != .None {return .Ok}
		icon_draw(
			list,
			header_icon(Header_Action(i + 1), zoomed, fullscreen, linked),
			face,
			ink,
			ICON_BUTTON,
			scale,
		)
	}
	if l.divider.width > 0 {draw_rect(list, {rect = l.divider, color = theme.border})}
	return .Ok
}


// Single-pane tabs keep their full terminal height, so their split controls float in a small pill at the
// pane's top-right corner instead of a header row.
split_overlay_layout :: proc(area: render.Rect, scale: f32, documents := true) -> Header_Layout {
	// A grip and compact buttons in a toolbar-height pill, SPACE_2 from the pane's corner.
	button := HEIGHT_COMPACT * scale
	inset := (HEIGHT_TOOLBAR - HEIGHT_COMPACT) / 2 * scale
	gap := 2 * SPACE_1 * scale + scale
	width, height := 3 * button + 2 * inset, HEIGHT_TOOLBAR * scale
	if documents {width += button + gap}
	l := Header_Layout {
		panel = {
			max(area.x, area.x + area.width - width - SPACE_2 * scale),
			area.y + SPACE_2 * scale,
			min(width, area.width),
			min(height, area.height),
		},
	}
	l.title = {l.panel.x + inset, l.panel.y + inset, button, button}
	x := l.title.x + button
	if documents {
		l.buttons[0] = {x, l.title.y, button, button}
		x += button + gap
	}
	l.buttons[1] = {x, l.title.y, button, button}
	l.buttons[2] = {x + button, l.title.y, button, button}
	if documents {l.divider = header_divider(l.buttons[1], l.panel.y, l.panel.height, scale)}
	return l
}

split_overlay_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Header_Layout,
	controls: [HEADER_BUTTONS]Control_Motion,
	scale: f32,
	pointer: [2]f32 = {},
	documents: Header_Documents = {},
) -> glyphs.Result {
	radius := RADIUS_OVERLAY * scale
	if render.push_layer(list, l.panel, radius) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = theme.surface, radius = radius})
	draw_rect(list, {rect = l.panel, color = theme.border, radius = radius, stroke = scale})
	icon_draw(list, .Grip, l.title, theme.muted, ICON_BUTTON, scale)
	buttons := l.buttons
	for button, i in buttons[:3] {
		if button.width == 0 {continue}
		b := Button {
			rect     = button,
			hover    = controls[i].hover.value,
			press    = controls[i].press.value,
			selected = i == 0 && documents.open,
		}
		face, ink, err := button_draw(list, theme, b, scale, pointer)
		if err != .None {return .Ok}
		icon_draw(list, header_icon(Header_Action(i + 1), false, false, false), face, ink, ICON_BUTTON, scale)
	}
	if l.divider.width > 0 {draw_rect(list, {rect = l.divider, color = theme.border})}
	return .Ok
}
