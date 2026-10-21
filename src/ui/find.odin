package ui

import "aio:glyphs"
import "aio:platform"
import "aio:render"

@(private)
FIND_WIDTH :: 380
@(private)
FIND_HEIGHT :: 40
@(private)
FIND_MARGIN :: 12
@(private)
FIND_PADDING :: 12
@(private)
FIND_RADIUS :: 8

Find_Bar :: struct {
	open:  bool,
	query: Text_Field,
}

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
	field_set(&f.query, "")
}

find_close :: proc(f: ^Find_Bar) {
	f.open = false
	field_set(&f.query, "")
}

// Handles a key while the find bar is open. Enter and Up move to older matches; Shift+Enter and Down to newer.
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

// The bar sits in the window's top-right corner, clear of the command palette's centered column.
find_layout :: proc(width, scale: f32) -> render.Rect {
	margin := FIND_MARGIN * scale
	panel_width := max(0, min(FIND_WIDTH * scale, width - 2 * margin))
	return {width - margin - panel_width, margin, panel_width, FIND_HEIGHT * scale}
}

find_contains :: proc(width, scale, x, y: f32) -> bool {
	r := find_layout(width, scale)
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

// Draws the bar with `status` (such as "3 of 17") right-aligned after the query.
find_draw :: proc(
	f: ^Find_Bar,
	list: ^render.Draw_List,
	base: ^Text,
	theme: Theme,
	status: string,
	width, height, scale: f32,
) -> glyphs.Result {
	input_text := text_styled(base, .Input)
	text := &input_text
	panel := find_layout(width, scale)
	if render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	radius := FIND_RADIUS * scale
	shadow := render.Rect{panel.x, panel.y + 12 * scale, panel.width, panel.height}
	border := render.Rect {
		panel.x - scale,
		panel.y - scale,
		panel.width + 2 * scale,
		panel.height + 2 * scale,
	}
	draw_rect(list, {rect = shadow, color = theme.shadow, radius = radius, softness = 32 * scale})
	draw_rect(list, {rect = border, color = theme.border, radius = radius + scale})
	draw_rect(list, {rect = panel, color = theme.surface, radius = radius})
	padding := FIND_PADDING * scale
	baseline := panel.y + (panel.height - text.line_height) / 2 + text.ascent
	status_width := text_width(text, status)
	status_x := panel.x + panel.width - padding - status_width
	if result := draw_text(text, list, status, status_x, baseline, theme.muted); result != .Ok {
		return result
	}
	query_width := max(0, status_x - padding - (panel.x + padding))
	return field_draw(
		&f.query,
		list,
		text,
		theme,
		panel.x + padding,
		baseline,
		query_width,
		true,
		"Find in scrollback",
		theme.text,
		max(1, 1.5 * scale),
	)
}
