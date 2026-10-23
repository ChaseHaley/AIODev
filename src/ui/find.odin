package ui

import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"

@(private) FIND_WIDTH :: 460
@(private) FIND_HEIGHT :: 40
@(private) FIND_MARGIN :: 12
@(private) FIND_PADDING :: 12
@(private) FIND_RADIUS :: 8

Find_Bar :: struct {
	open:  bool,
	query: Text_Field,
	hover: Find_Outcome,
	armed: Armed(Find_Outcome),
}

Find_Layout :: struct { panel, query, status, older, newer: render.Rect }

Find_Outcome :: enum {
	None,
	Changed,
	Moved,
	Older,
	Newer,
	Closed,
}

find_init :: proc(f: ^Find_Bar, allocator := context.allocator) {
	f.query.bytes = make([dynamic]u8, allocator)
}

find_destroy :: proc(f: ^Find_Bar) {
	delete(f.query.bytes)
	f^ = {}
}

find_open :: proc(f: ^Find_Bar) {
	f.open = true
	f.hover = .None
	armed_cancel(&f.armed)
	field_set(&f.query, "")
}

find_close :: proc(f: ^Find_Bar) {
	f.open = false
	f.hover = .None
	armed_cancel(&f.armed)
	field_set(&f.query, "")
}

// Handles a key while the find bar is open. Enter and Up move to older matches;
// Shift+Enter and Down to newer.
find_key :: proc(f: ^Find_Bar, e: platform.Key_Event) -> Find_Outcome {
	if !e.pressed {
		return .None
	}
	#partial switch e.key {
	case .Escape:
		find_close(f)
		return .Closed
	case .Enter, .Numpad_Enter:
		return .Shift in e.modifiers ? .Newer : .Older
	case .Arrow_Up:
		return .Older
	case .Arrow_Down:
		return .Newer
	}
	return find_change(field_key(&f.query, e))
}

@(private)
find_change :: proc(change: Field_Change) -> Find_Outcome {
	switch change {
	case .None:
		return .None
	case .Moved:
		return .Moved
	case .Edited:
	}
	return .Changed
}

find_text :: proc(f: ^Find_Bar, text: string) -> Find_Outcome {
	return find_change(field_text(&f.query, text))
}

// Keep the overlay below the title chrome, where `caption_claim_height` says the caption
// controls claim pointer input, so they cannot intercept its events.
find_layout :: proc(width, scale: f32, status_width: f32 = 0) -> Find_Layout {
	margin := FIND_MARGIN * scale
	panel_width := max(0, min(FIND_WIDTH * scale, width - 2 * margin))
	l: Find_Layout
	l.panel = {
		max(0, width - margin - panel_width),
		caption_claim_height(scale) + margin,
		panel_width,
		FIND_HEIGHT * scale,
	}
	padding, gap, button := FIND_PADDING * scale, 8 * scale, 32 * scale
	inner := max(0, panel_width - 2 * padding)
	stacked := inner < 80 * scale + status_width + 2 * gap + 2 * button
	l.query = {l.panel.x + min(padding, panel_width), l.panel.y + 4 * scale, inner, button}
	y := l.query.y
	if stacked { y += FIND_HEIGHT * scale; l.panel.height += FIND_HEIGHT * scale }
	// On very narrow windows give the count its own row to keep every digit visible.
	separate := inner < status_width + gap + 2 * button
	l.status = {l.query.x, y, min(status_width, inner), button}
	if stacked && separate { y += FIND_HEIGHT * scale; l.panel.height += FIND_HEIGHT * scale }
	button = min(button, inner / 2)
	l.newer = {l.query.x + inner - button, y, button, 32 * scale}
	l.older = {l.newer.x - button, y, button, 32 * scale}
	if !separate { l.status.x = l.older.x - gap - l.status.width }
	if !stacked { l.query.width = max(0, l.status.x - gap - l.query.x) }
	return l
}

find_contains :: proc(l: Find_Layout, x, y: f32) -> bool { return contains(l.panel, x, y) }

find_hit :: proc(l: Find_Layout, x, y: f32) -> Find_Outcome {
	if contains(l.older, x, y) { return .Older }
	if contains(l.newer, x, y) { return .Newer }
	return .None
}

find_hover :: proc(f: ^Find_Bar, l: Find_Layout, enabled: bool, x, y: f32) -> bool {
	hit := enabled ? find_hit(l, x, y) : .None
	if hit == f.hover { return false }
	f.hover = hit
	return true
}

// Like other chrome buttons, activate only on a matching left press/release. Query retains keyboard focus.
find_mouse :: proc(f: ^Find_Bar, l: Find_Layout, enabled: bool, button: input.Mouse_Button,
	pressed: bool, x, y: f32) -> Find_Outcome {
	if button != .Left { return .None }
	hit := enabled ? find_hit(l, x, y) : .None
	if pressed {
		armed_press(&f.armed, hit)
		return .Moved
	}
	fired, ok := armed_release(&f.armed, hit)
	if ok && fired != .None { return fired }
	return .Moved
}

// Draws the bar with `status` (such as "3 of 17") right-aligned after the query.
find_draw :: proc(
	f: ^Find_Bar,
	list: ^render.Draw_List,
	base: ^Text,
	theme: Theme,
	status: string,
	enabled: bool,
	width, height, scale: f32,
) -> glyphs.Result {
	input_text := text_styled(base, .Input)
	text := &input_text
	l := find_layout(width, scale, text_width(text, status))
	panel := l.panel
	if panel.width <= 2 * FIND_PADDING * scale { return .Ok }
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	frame := Panel {
		rect     = panel,
		radius   = FIND_RADIUS * scale,
		scale    = scale,
		shadow_y = 12,
		softness = 32,
		border   = .Expanded,
	}
	if panel_draw(list, frame, theme) != .None {return .Ok}
	count := input_text
	if measured := text_width(&count, status); measured > l.status.width && measured > 0 {
		text_set_size(&count, count.size_px * l.status.width / measured)
	}
	if result := draw_text(&count, list, status, l.status.x,
		l.status.y + (l.status.height - count.line_height) / 2 + count.ascent, theme.text); result != .Ok {
		return result
	}
	for area, i in ([2]render.Rect{l.older, l.newer}) {
		action: Find_Outcome = i == 0 ? .Older : .Newer
		active := armed_is(f.armed, action)
		if enabled && (f.hover == action || active) {
			draw_rect(list, {rect = area, color = active ? theme.pressed : theme.hover,
				radius = 5 * scale})
		}
		if enabled && active { focus_ring_draw(list, area, theme, scale) }
		if result := draw_glyph_centered(text, list, i == 0 ? '↑' : '↓', area,
			enabled ? theme.text : theme.faint); result != .Ok { return result }
	}
	if l.query.width <= 0 { return .Ok }
	box := Field_Box {
		field       = &f.query,
		text        = base,
		rect        = l.query,
		inset       = 0,
		caret_width = 1.5,
		radius      = 0,
		style       = .Input,
		scale       = scale,
	}
	return field_box_draw(box, list, theme, field_box_baseline(box), true, "Find in scrollback")
}
