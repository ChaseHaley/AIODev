package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

@(private) TOOLTIP_DELAY :: 700 * time.Millisecond
@(private) TOOLTIP_GRACE :: time.Second
// A short pointer move between adjacent controls keeps tooltips warm across their gap.
@(private) TOOLTIP_NEIGHBOR_DISTANCE :: f32(80)

@(private) TOOLTIP_LIMIT :: 1024

@(private)
tooltip_label :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32) -> string {
	label := pointer_surfaces[owner].tooltip
	if label == nil {return ""}
	text := label(app, w, x, y)
	if len(text) <= TOOLTIP_LIMIT {return text}
	end := TOOLTIP_LIMIT
	for end > 0 && !utf8.rune_start(text[end]) {end -= 1}
	return text[:end]
}

// The window keeps its own copy, because a label may be built for one event in temporary memory.
@(private)
tooltip_store :: proc(w: ^Window, label: string) {
	w.tooltip = string(w.tooltip_text[:copy(w.tooltip_text[:], label)])
}

tooltip_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	if e.buttons != {} {tooltip_cancel(w); return}
	label := tooltip_label(app, w, owner, f32(e.x), f32(e.y))
	point := [2]f32{f32(e.x), f32(e.y)}
	dx, dy := point.x - w.tooltip_anchor.x, point.y - w.tooltip_anchor.y
	reach := TOOLTIP_NEIGHBOR_DISTANCE * max(1, w.scale)
	near := dx * dx + dy * dy <= reach * reach
	if label == w.tooltip {
		if label != "" {w.tooltip_anchor = point}
		if label == "" && !near {w.tooltip_warm_until = {}}
		return
	}
	now := time.tick_now()
	warm := w.tooltip_visible || w.tooltip_warm_until != {} &&
		time.tick_diff(now, w.tooltip_warm_until) > 0
	immediate := label != "" && warm && near
	if (label == "" && w.tooltip_visible) || immediate {
		w.tooltip_warm_until = time.tick_add(now, TOOLTIP_GRACE)
	} else if !warm || (label != "" && !immediate) {
		w.tooltip_warm_until = {}
	}
	tooltip_store(w, label)
	w.tooltip_visible = immediate
	w.tooltip_deadline = label == "" || immediate ? {} : time.tick_add(now, TOOLTIP_DELAY)
	if label != "" {w.tooltip_anchor = point}
	w.dirty = true
}

tooltip_cancel :: proc(w: ^Window) {
	if w.tooltip == "" && w.tooltip_deadline == {} && w.tooltip_warm_until == {} {return}
	tooltip_store(w, "")
	w.tooltip_deadline, w.tooltip_warm_until, w.tooltip_visible = {}, {}, false
	w.dirty = true
}

tooltip_tick :: proc(w: ^Window) {
	if w.tooltip_deadline == {} || time.tick_diff(time.tick_now(), w.tooltip_deadline) > 0 {return}
	w.tooltip_deadline = {}
	w.tooltip_visible = true
	w.tooltip_warm_until = time.tick_add(time.tick_now(), TOOLTIP_GRACE)
	w.dirty = true
}

tooltip_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	if !w.tooltip_visible || w.tooltip == "" {return .Ok}
	owner := pointer_target(app, w, w.pointer.x, w.pointer.y)
	if tooltip_label(app, w, owner, w.pointer.x, w.pointer.y) != w.tooltip {return .Ok}
	s := w.scale
	lines := strings.split_lines(w.tooltip, context.temp_allocator)
	limit := max(0, f32(w.width) - 8 * s)
	width := f32(0)
	for line in lines {width = max(width, ui.text_width(&w.ui_text, line))}
	width = min(width + 16 * s, limit)
	height := ui.HEIGHT_COMPACT * s + f32(len(lines) - 1) * w.ui_text.line_height
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 16 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = ui.RADIUS_CONTROL * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	top := y + (height - f32(len(lines)) * w.ui_text.line_height) / 2
	for line, i in lines {
		baseline := top + f32(i) * w.ui_text.line_height + w.ui_text.ascent
		if result := ui.draw_fading_text(&w.ui_text, &w.list, line, x + 8 * s, baseline, app.theme.text,
			max(0, width - 16 * s)); result != .Ok {return result}
	}
	return .Ok
}
