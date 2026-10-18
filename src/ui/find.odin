package ui

import "aio:glyphs"
import "aio:platform"
import "aio:render"

@(private) FIND_WIDTH :: 380
@(private) FIND_HEIGHT :: 40
@(private) FIND_MARGIN :: 12
@(private) FIND_PADDING :: 12
@(private) FIND_RADIUS :: 8

Find_Bar :: struct {
	open: bool,
	query: [dynamic]u8,
}

Find_Outcome :: enum {
	None,
	Changed,
	Older,
	Newer,
	Closed,
}

find_init :: proc(f: ^Find_Bar, allocator := context.allocator) {
	f.query = make([dynamic]u8, allocator)
}

find_destroy :: proc(f: ^Find_Bar) {
	delete(f.query)
	f^ = {}
}

find_open :: proc(f: ^Find_Bar) {
	f.open = true
	clear(&f.query)
}

find_close :: proc(f: ^Find_Bar) {
	f.open = false
	clear(&f.query)
}

// Handles a key while the find bar is open. Enter and Up move to older matches; Shift+Enter and Down to newer.
find_key :: proc(f: ^Find_Bar, e: platform.Key_Event) -> Find_Outcome {
	if !e.pressed {
		return .None
	}
	control := .Control in e.modifiers
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
	case .Backspace:
		if len(f.query) == 0 {
			return .None
		}
		erase(&f.query, control)
		return .Changed
	}
	if len(e.text) > 0 && (!control || .Alt in e.modifiers) {
		return find_text(f, e.text)
	}
	return .None
}

find_text :: proc(f: ^Find_Bar, text: string) -> Find_Outcome {
	return insert(&f.query, text) ? .Changed : .None
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
	border := render.Rect{panel.x - scale, panel.y - scale, panel.width + 2 * scale, panel.height + 2 * scale}
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
	query := string(f.query[:])
	query_width := max(0, status_x - padding - (panel.x + padding))
	shown, shown_color := query, theme.text
	if len(query) == 0 {
		shown, shown_color = "Find in scrollback", theme.muted
	}
	result := draw_text(text, list, shown, panel.x + padding, baseline, shown_color, query_width)
	if result != .Ok {
		return result
	}
	caret_x := panel.x + padding + min(text_width(text, query), query_width)
	caret := render.Rect{caret_x, baseline - text.ascent, max(1, 1.5 * scale), text.line_height}
	draw_rect(list, {rect = caret, color = theme.accent})
	return .Ok
}
