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
	Warning,
	Success,
}

notice_style :: proc(kind: Notice_Kind, theme: Theme) -> (label: string, symbol: rune, color: render.Color) {
	switch kind {
	case .Info: return "Info", 'i', theme.info
	case .Warning: return "Warning", '!', theme.warning
	case .Error: return "Error", '×', theme.error
	case .Success: return "Success", '✓', theme.success
	}
	return "Info", 'i', theme.info
}

Notice :: struct {
	key: u32,
	kind: Notice_Kind,
	text: string,
	sticky: bool,
	expires: time.Tick,
	motion: Motion,
}

Notices :: struct {
	items, fading: [dynamic]Notice,
	animations: bool,
	lines: [dynamic]string,
}

notices_init :: proc(n: ^Notices, allocator := context.allocator) {
	n.items = make([dynamic]Notice, allocator)
	n.fading = make([dynamic]Notice, allocator)
	n.lines = make([dynamic]string, allocator)
}

notices_destroy :: proc(n: ^Notices) {
	for item in n.items {
		delete(item.text, n.items.allocator)
	}
	for item in n.fading { delete(item.text, n.items.allocator) }
	delete(n.fading)
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
	motion_target(&notice.motion, 1, 160*time.Millisecond, .Decelerate, n.animations, time.tick_now())
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
			notices_remove(n, i)
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
			notices_remove(n, i)
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
	if len(n.items)+len(n.fading) == 0 || render.push_layer(list, {0, 0, width, height}) != .None {
		return .Ok
	}
	margin, padding := NOTICE_MARGIN * scale, NOTICE_PADDING * scale
	box_width := min(NOTICE_WIDTH * scale, width - 2 * margin)
	bottom := height - margin
	for i := len(n.items)+len(n.fading)-1; i >= 0; i -= 1 {
		item: Notice
		if i < len(n.items) { item = n.items[i] } else { item = n.fading[i-len(n.items)] }
		layers, rects, glyph_count := len(list.layers), len(list.rects), len(list.glyphs)
		content_width := max(scale, box_width - 2 * padding - 32 * scale)
		wrap(text, item.text, content_width, &n.lines)
		lines := min(len(n.lines), NOTICE_MAX_LINES)
		box_height := f32(lines+1) * text.line_height + 2 * padding + 4 * scale
		box := render.Rect{width - margin - box_width, bottom - box_height, box_width, box_height}
		label, symbol, accent := notice_style(item.kind, theme)
		shadow := render.Rect{box.x, box.y + 12 * scale, box.width, box.height}
		draw_rect(list, {rect = shadow, color = theme.shadow, radius = 8 * scale, softness = 32 * scale})
		draw_rect(list, {rect = box, color = theme.surface, radius = 8 * scale})
		draw_rect(list, {rect = box, color = theme.border, radius = 8 * scale, stroke = scale})
		draw_rect(list, {rect = {box.x, box.y, 4 * scale, box.height}, color = accent, radius = 2 * scale})
		badge := render.Rect{box.x+padding+4*scale, box.y+padding, 20*scale, 20*scale}
		radius: f32 = item.kind == .Info || item.kind == .Error ? 10 : 3
		draw_rect(list, {rect = badge, color = accent, radius = radius*scale, stroke = scale})
		if result := draw_glyph_centered(text, list, symbol, badge, accent); result != .Ok { return result }
		strong := text_styled(text, .Strong)
		x := box.x + padding + 32 * scale
		if result := draw_text(&strong, list, label, x, box.y+padding+strong.ascent, accent,
			content_width); result != .Ok { return result }
		for line, index in n.lines[:lines] {
			baseline := box.y + padding + f32(index+1) * text.line_height + 4 * scale + text.ascent
			max_width := index == lines - 1 && len(n.lines) > lines ? content_width : 0
			if result := draw_text(text, list, line, x, baseline, theme.text, max_width); result != .Ok {
				return result
			}
		}
		fade_draw(list, layers, rects, glyph_count, item.motion.value, item.motion.target > 0 ? 6*scale*(1-item.motion.value) : 0)
		bottom = box.y - 8 * scale
		if bottom < margin {
			break
		}
	}
	return .Ok
}

@(private)
notices_remove :: proc(n: ^Notices, index: int) {
	item := n.items[index]
	if n.animations {
		motion_target(&item.motion, 0, 120*time.Millisecond, .Accelerate, true, time.tick_now())
		if _, err := append(&n.fading, item); err != nil { delete(item.text, n.items.allocator) }
	} else { delete(item.text, n.items.allocator) }
	ordered_remove(&n.items, index)
}

notices_animating :: proc(n: ^Notices) -> bool {
	for item in n.items { if motion_active(item.motion) { return true } }
	return len(n.fading) > 0
}

notices_animate :: proc(n: ^Notices, now: time.Tick) -> bool {
	changed := false
	for &item in n.items { changed = motion_update(&item.motion, now) || changed }
	for i := len(n.fading)-1; i >= 0; i -= 1 {
		changed = motion_update(&n.fading[i].motion, now) || changed
		if !motion_active(n.fading[i].motion) {
			delete(n.fading[i].text, n.items.allocator)
			ordered_remove(&n.fading, i)
		}
	}
	return changed
}

notices_set_animations :: proc(n: ^Notices, enabled: bool) {
	n.animations = enabled
	if enabled { return }
	for &item in n.items { item.motion.value, item.motion.target = 1, 1 }
	for item in n.fading { delete(item.text, n.items.allocator) }
	clear(&n.fading)
}
