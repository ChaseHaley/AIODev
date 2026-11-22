package ui

import "cosmos:render"

HEADER_HEIGHT :: HEIGHT_TOOLBAR
@(private = "file")
HEADER_TITLE_MINIMUM :: f32(40)

// A header's geometry for its owner's button set E, whose order runs left to right.
Header_Layout :: struct($E: typeid) {
	panel, title, badge: render.Rect,
	// Where the badge takes hover and clicks: a little past its glyph and over the chevron its hover shows,
	// never outside the panel.
	badge_target:        render.Rect,
	// The owner's own control just before the buttons, which it draws and hit tests; empty when the owner
	// asks for none or the header is too narrow for it.
	widget:              render.Rect,
	// Where the widget sits at the header's right end, which it slides to while the buttons hide; empty
	// with it.
	widget_end:          render.Rect,
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
// `widget` of that size in DIPs sits just before the first button; it is the first to give way. With
// `widget_aside` 1, for a header whose buttons are hidden, it sits at the header's right end instead, and in
// between it slides, as the program status does (header_status_layout). The title never depends on it.
header_layout :: proc(
	area: render.Rect,
	scale: f32,
	shown, separated: bit_set[$E],
	drop_order: []E,
	widget: [2]f32 = {},
	widget_aside: f32 = 0,
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
		size := widget * scale
		widget_x := end - SPACE_1 * scale - size.x
		if widget_x - SPACE_2 * scale - title_x >= HEADER_TITLE_MINIMUM * scale {
			y := area.y + max(0, (l.panel.height - size.y) / 2)
			l.widget = {widget_x, y, size.x, min(size.y, l.panel.height)}
			l.widget_end = l.widget
			l.widget_end.x = area.x + area.width - SPACE_1 * scale - size.x
			l.widget.x += (l.widget_end.x - widget_x) * widget_aside
			end = widget_x
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

// Where a header's program status pill of `status_width` sits, and how wide the title may then be.
// Beside the buttons (`aside` 0) the pill ends where the title's room ends, taking at most half of it.
// At the header's right end (`aside` 1), for a header whose buttons are hidden, the pill also takes their
// room, never reaching left of its place beside them; the owner's widget, which also moves to the right
// end, takes the corner and the pill ends SPACE_2 before it. A header without that room keeps it beside
// them. In between it slides. The title's width never depends on `aside`, so the
// title neither moves nor re-truncates when the buttons come and go. A header too narrow for a pill
// shows none.
header_status_layout :: proc(
	l: Header_Layout($E),
	status_width, scale, aside: f32,
) -> (
	pill: render.Rect,
	title_width: f32,
) {
	width := l.title.width
	if status_width <= 0 || width < 120 * scale {return {}, width}
	beside := min(status_width, width * 0.5)
	pill = {
		l.title.x + width - beside,
		l.panel.y + SPACE_1 * scale,
		beside,
		max(0, l.panel.height - 2 * SPACE_1 * scale),
	}
	title_width = max(0, width - beside - SPACE_2 * scale)
	// The pill's fill ends where the last button's does.
	right := l.panel.x + l.panel.width - SPACE_1 * scale
	if l.widget_end.width > 0 {right = l.widget_end.x - SPACE_2 * scale}
	edge := min(status_width, right - pill.x)
	if aside <= 0 || edge < beside {return}
	pill.width = beside + (edge - beside) * aside
	pill.x += (right - edge - pill.x) * aside
	return
}

// Slides a header's program status toward the header's right end while its buttons are hidden and back
// beside them when they show, with the header controls' own motion. `enabled` false lands it at once.
header_status_update :: proc(m: ^Motion, aside, enabled: bool, frame: Frame_Time) -> bool {
	motion_target(m, aside ? 1 : 0, CONTROL_MOTION_DURATION, .Linear, enabled)
	return motion_update(m, frame)
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
	// 0 for the status beside the buttons, 1 at the header's right end; see header_status_layout.
	status_aside: f32 = 0,
	mode_label: string = "",
	mode_color: render.Color = {},
) -> render.Build_Status {
	if render.push_layer(list, area, radius) != .None {return .Ok}
	draw_rect(list, {rect = l.panel, color = background})
	if render.push_layer(list, l.panel) != .None {return .Ok}
	if l.title.width > 0 && l.badge.x + l.badge.width <= area.x + area.width {
		if content_icon != .None {
			icon_draw(list, content_icon, l.badge,
				focused ? theme.text : theme.muted, ICON_BUTTON, scale)
		} else if result := badge_draw(list, text, theme, l.badge, icon, scale, icon_atlas);
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
	status_right_used: f32
	if status.glyph != .None {
		// A pill pads its ends by SPACE_2: glyph, SPACE_1, then the status text.
		pad := (SPACE_2 + 12 + SPACE_1 + SPACE_2) * scale
		pill: render.Rect
		pill, width = header_status_layout(l, text_width(&small, status_text) + pad, scale, status_aside)
		if pill.width > 0 {
			status_right_used = pill.width + SPACE_1 * scale
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
				max(0, pill.width - pad),
			); result != .Ok {return result}
		}
	}
	if mode_label != "" {
		pad := SPACE_2 * scale
		pill_w := text_width(&small, mode_label) + 2 * pad
		pill, next_width := header_status_layout(l, pill_w + status_right_used, scale, status_aside)
		if pill.width > status_right_used {
			pill.width -= status_right_used
			width = min(width, next_width)
			fill := mode_color
			fill.a *= 0.18
			draw_rect(list, {rect = pill, color = fill, radius = pill.height / 2})
			if result := draw_fading_text(
				&small,
				list,
				mode_label,
				pill.x + pad,
				pill.y + (pill.height - small.line_height) / 2 + small.ascent,
				mode_color,
				max(0, pill.width - 2 * pad),
			); result != .Ok {return result}
		}
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
