package ui

import "core:strings"
import "core:time"
import "aio:glyphs"
import "aio:render"

@(private) NOTICE_WIDTH :: 520
@(private) NOTICE_MARGIN :: 16
@(private) NOTICE_PADDING :: 12
@(private) NOTICE_MAX_LINES :: 4

Notice_Kind :: enum u8 {
	Info,
	Error,
}

Notice :: struct {
	key: u32,
	kind: Notice_Kind,
	text: string,
	sticky: bool,
	expires: time.Tick,
}

Notices :: struct {
	items: [dynamic]Notice,
	lines: [dynamic]string,
}

notices_init :: proc(n: ^Notices, allocator := context.allocator) {
	n.items = make([dynamic]Notice, allocator)
	n.lines = make([dynamic]string, allocator)
}

notices_destroy :: proc(n: ^Notices) {
	for item in n.items {
		delete(item.text, n.items.allocator)
	}
	delete(n.items)
	delete(n.lines)
	n^ = {}
}

// Shows a notice. A nonzero key replaces the notice already shown under it; a zero duration is sticky.
notices_put :: proc(n: ^Notices, key: u32, kind: Notice_Kind, text: string, duration: time.Duration) {
	if key != 0 {
		notices_clear(n, key)
	}
	owned, err := strings.clone(text, n.items.allocator)
	if err != nil {
		return
	}
	notice := Notice{key = key, kind = kind, text = owned, sticky = duration == 0}
	if !notice.sticky {
		notice.expires = time.tick_add(time.tick_now(), duration)
	}
	if _, append_err := append(&n.items, notice); append_err != nil {
		delete(owned, n.items.allocator)
	}
}

notices_clear :: proc(n: ^Notices, key: u32) -> bool {
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		if n.items[i].key == key {
			delete(n.items[i].text, n.items.allocator)
			ordered_remove(&n.items, i)
			return true
		}
	}
	return false
}

// Removes expired notices and reports whether any were removed.
notices_expire :: proc(n: ^Notices, now: time.Tick) -> bool {
	removed := false
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		item := n.items[i]
		if !item.sticky && time.tick_diff(item.expires, now) >= 0 {
			delete(item.text, n.items.allocator)
			ordered_remove(&n.items, i)
			removed = true
		}
	}
	return removed
}

notices_deadline :: proc(n: ^Notices) -> (time.Tick, bool) {
	deadline: time.Tick
	found := false
	for item in n.items {
		if !item.sticky && (!found || time.tick_diff(item.expires, deadline) > 0) {
			deadline, found = item.expires, true
		}
	}
	return deadline, found
}

notices_draw :: proc(
	n: ^Notices,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	width, height, scale: f32,
) -> glyphs.Result {
	if len(n.items) == 0 || render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	margin, padding := NOTICE_MARGIN * scale, NOTICE_PADDING * scale
	box_width := min(NOTICE_WIDTH * scale, width - 2 * margin)
	bottom := height - margin
	for i := len(n.items) - 1; i >= 0; i -= 1 {
		item := n.items[i]
		wrap(text, item.text, box_width - 2 * padding - 4 * scale, &n.lines)
		lines := min(len(n.lines), NOTICE_MAX_LINES)
		box_height := f32(lines) * text.line_height + 2 * padding
		box := render.Rect{width - margin - box_width, bottom - box_height, box_width, box_height}
		accent := item.kind == .Error ? theme.error : theme.accent
		shadow := render.Rect{box.x, box.y + 4 * scale, box.width, box.height}
		draw_rect(list, {rect = shadow, color = theme.shadow, radius = 8 * scale, softness = 12 * scale})
		draw_rect(list, {rect = box, color = theme.surface, radius = 8 * scale})
		draw_rect(list, {rect = {box.x, box.y, 4 * scale, box.height}, color = accent, radius = 2 * scale})
		for line, index in n.lines[:lines] {
			x := box.x + padding + 4 * scale
			baseline := box.y + padding + f32(index) * text.line_height + text.ascent
			max_width := index == lines - 1 && len(n.lines) > lines ? box_width - 2 * padding : 0
			if result := draw_text(text, list, line, x, baseline, theme.text, max_width); result != .Ok {
				return result
			}
		}
		bottom = box.y - 8 * scale
		if bottom < margin {
			break
		}
	}
	return .Ok
}
