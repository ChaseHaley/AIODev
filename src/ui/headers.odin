package ui

import "aio:render"

HEADER_HEIGHT :: HEIGHT_TOOLBAR
@(private = "file")
HEADER_TITLE_MINIMUM :: f32(40)

// A header's geometry for its owner's button set E, whose order runs left to right.
Header_Layout :: struct($E: typeid) {
	panel, title, badge: render.Rect,
	// Where the badge takes hover and clicks: a little past its glyph and over the chevron its hover shows,
	// never outside the panel.
	badge_target:        render.Rect,
	// The owner's own control between the badge and the title, which it draws and hit tests; empty when
	// the owner asks for none or the header is too narrow for it.
	widget:              render.Rect,
	buttons:             [E]render.Rect,
	// Hairlines set each separated button apart from the buttons after it; empty where none follows.
	dividers:            [E]render.Rect,
}

// A header's badge, which opens its menu.
Header_Badge :: struct {}

// What a point on a header does: one of its buttons, its badge, or nil for its title.
Header_Target :: union($E: typeid) {
	E,
	Header_Badge,
}

// How a header button draws: its icon and motion, toggled on when selected, pressed in a faint error tint
// rather than the neutral fill when it is a danger, and flat with faint ink when disabled.
Header_Button :: struct {
	icon:                       Icon,
	motion:                     Control_Motion,
	selected, danger, disabled: bool,
}

// A hairline with SPACE_1 either side.
@(private = "file")
header_divider :: proc(next: render.Rect, panel_y, panel_height, scale: f32) -> render.Rect {
	height := min(ICON_BUTTON * scale, panel_height)
	return {next.x - SPACE_1 * scale - scale, panel_y + (panel_height - height) / 2, scale, height}
}

// Whether a divider follows `action`: it is separated and some shown button comes after it.
@(private = "file")
header_divided :: proc(action: $E, shown, separated: bit_set[E]) -> bool {
	if action not_in separated || action not_in shown {return false}
	for later in E {if later > action && later in shown {return true}}
	return false
}

// The width of the `shown` buttons, with a gap after each one a divider follows.
@(private = "file")
header_buttons_width :: proc(shown, separated: bit_set[$E], button, gap: f32) -> f32 {
	width: f32
	for action in shown {width += button + (header_divided(action, shown, separated) ? gap : 0)}
	return width
}

// A header row across the top of `area`: the badge and title at the start and the `shown` buttons at the
// end, each `separated` button set apart from those after it. Buttons never cover the badge or the start
// of the title, which focus and drag the pane, so in a narrow header they give way in `drop_order`. A
// `widget` of that size in DIPs sits between the badge and the title, clear of the badge's chevron; it is the
// first to give way.
header_layout :: proc(
	area: render.Rect,
	scale: f32,
	shown, separated: bit_set[$E],
	drop_order: []E,
	widget: [2]f32 = {},
) -> Header_Layout(E) {
	l := Header_Layout(E) {
		panel = {area.x, area.y, area.width, min(area.height, HEADER_HEIGHT * scale)},
	}
	// The badge and the last button's icon both sit SPACE_2 from the card's edges.
	badge := ICON_BUTTON * scale
	l.badge = {area.x + SPACE_2 * scale, area.y + (l.panel.height - badge) / 2, badge, badge}
	left := max(l.panel.x, l.badge.x - 3 * scale)
	top := max(l.panel.y, l.badge.y - 3 * scale)
	right := min(l.panel.x + l.panel.width, l.badge.x + l.badge.width + 9 * scale)
	bottom := min(l.panel.y + l.panel.height, l.badge.y + l.badge.height + 3 * scale)
	l.badge_target = {left, top, max(0, right - left), max(0, bottom - top)}
	button := HEIGHT_COMPACT * scale
	end := area.x + area.width - SPACE_1 * scale
	title_end := area.x + (SPACE_2 + ICON_BUTTON + SPACE_2 + HEADER_TITLE_MINIMUM) * scale
	gap := 2 * SPACE_1 * scale + scale
	shown := shown
	for action in drop_order {
		if end - header_buttons_width(shown, separated, button, gap) >= title_end {break}
		shown -= {action}
	}
	placed: render.Rect
	#reverse for &rect, action in l.buttons {
		if action not_in shown {continue}
		if header_divided(action, shown, separated) {
			l.dividers[action] = header_divider(placed, l.panel.y, l.panel.height, scale)
			end -= gap
		}
		rect = {
			end - button,
			area.y + max(0, (l.panel.height - button) / 2),
			button,
			min(button, l.panel.height),
		}
		placed = rect
		end -= button
	}
	title_x := l.badge.x + l.badge.width + SPACE_2 * scale
	if widget.x > 0 {
		widget_x := l.badge_target.x + l.badge_target.width + SPACE_1 * scale
		size := widget * scale
		after := widget_x + size.x + SPACE_2 * scale
		if end - SPACE_2 * scale - after >= HEADER_TITLE_MINIMUM * scale {
			y := area.y + max(0, (l.panel.height - size.y) / 2)
			l.widget = {widget_x, y, size.x, min(size.y, l.panel.height)}
			title_x = after
		}
	}
	l.title = {title_x, area.y, max(0, end - SPACE_2 * scale - title_x), l.panel.height}
	return l
}

header_hit_test :: proc(l: Header_Layout($E), x, y: f32) -> Header_Target(E) {
	for button, action in l.buttons {
		if button.width > 0 &&
		   render.rect_contains(button, x, y) &&
		   render.rect_contains(l.panel, x, y) {return action}
	}
	if render.rect_contains(l.badge_target, x, y) {return Header_Badge{}}
	return nil
}

header_contains :: proc(l: Header_Layout($E), x, y: f32) -> bool {
	return render.rect_contains(l.panel, x, y)
}

shell_badge_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	icon: string,
	scale: f32,
	atlas: render.Rect = {},
) -> render.Build_Status {
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

// Draws a header row laid out by header_layout over the card at `area`.
header_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	l: Header_Layout($E),
	buttons: [E]Header_Button,
	background: render.Color,
	radius, scale: f32,
	title, directory, icon: string,
	focused: bool,
	icon_atlas: render.Rect = {},
	badge_hovered := false,
	pointer: [2]f32 = {},
	status: Status_Mark = {},
	status_text: string = "",
	status_phase: f32 = 0,
	content_icon: Icon = .None,
) -> render.Build_Status {
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
		if status.urgent {ink = status_color(theme, status.glyph)}
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
	header_buttons_draw(list, theme, l, buttons, scale, pointer)
	return .Ok
}

// Draws the laid-out buttons, then the divider; stops at a full draw list.
@(private = "file")
header_buttons_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	l: Header_Layout($E),
	buttons: [E]Header_Button,
	scale: f32,
	pointer: [2]f32,
) {
	for rect, action in l.buttons {
		if rect.width == 0 {continue}
		button := buttons[action]
		b := Button {
			rect     = rect,
			hover    = button.motion.hover.value,
			press    = button.motion.press.value,
			selected = button.selected,
			disabled = button.disabled,
		}
		if button.danger {
			danger := theme.error
			danger.a *= 0.14
			b.press_color = danger
		}
		face, ink, err := button_draw(list, theme, b, scale, pointer)
		if err != .None {return}
		// Faint ink alone sits too close to the muted ink of its neighbours at icon size.
		if button.disabled {ink.a *= 0.55}
		icon_draw(list, button.icon, face, ink, ICON_BUTTON, scale)
	}
	for divider in l.dividers {
		if divider.width > 0 {draw_rect(list, {rect = divider, color = theme.border})}
	}
}

// Single-pane tabs keep their full terminal height, so their split controls float in a small pill at the
// pane's top-right corner instead of a header row: a grip in `title`, then the `shown` buttons, each
// `separated` button set apart from those after it.
split_overlay_layout :: proc(
	area: render.Rect,
	scale: f32,
	shown, separated: bit_set[$E],
) -> Header_Layout(E) {
	// A grip and compact buttons in a toolbar-height pill, SPACE_2 from the pane's corner.
	button := HEIGHT_COMPACT * scale
	inset := (HEIGHT_TOOLBAR - HEIGHT_COMPACT) / 2 * scale
	gap := 2 * SPACE_1 * scale + scale
	// The grip takes a button's room.
	width := button + header_buttons_width(shown, separated, button, gap) + 2 * inset
	height := HEIGHT_TOOLBAR * scale
	l := Header_Layout(E) {
		panel = {
			max(area.x, area.x + area.width - width - SPACE_2 * scale),
			area.y + SPACE_2 * scale,
			min(width, area.width),
			min(height, area.height),
		},
	}
	l.title = {l.panel.x + inset, l.panel.y + inset, button, button}
	x := l.title.x + button
	previous: Maybe(E)
	for &rect, action in l.buttons {
		if action not_in shown {continue}
		rect = {x, l.title.y, button, button}
		if before, ok := previous.?; ok && before in separated {
			l.dividers[before] = header_divider(rect, l.panel.y, l.panel.height, scale)
		}
		previous = action
		x += header_divided(action, shown, separated) ? button + gap : button
	}
	return l
}

split_overlay_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	l: Header_Layout($E),
	buttons: [E]Header_Button,
	scale: f32,
	pointer: [2]f32 = {},
) -> render.Build_Status {
	radius := RADIUS_OVERLAY * scale
	if render.push_layer(list, l.panel, radius) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = theme.surface, radius = radius})
	draw_rect(list, {rect = l.panel, color = theme.border, radius = radius, stroke = scale})
	icon_draw(list, .Grip, l.title, theme.muted, ICON_BUTTON, scale)
	header_buttons_draw(list, theme, l, buttons, scale, pointer)
	return .Ok
}
