package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:time"

@(private) TOOLTIP_DELAY :: 700 * time.Millisecond
@(private) TOOLTIP_GRACE :: time.Second
// A short pointer move between adjacent controls keeps tooltips warm across their gap.
@(private) TOOLTIP_NEIGHBOR_DISTANCE :: f32(80)

@(private)
tooltip_label :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32) -> string {
	label := pointer_surfaces[owner].tooltip
	return label != nil ? label(app, w, x, y) : ""
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
	w.tooltip = label
	w.tooltip_visible = immediate
	w.tooltip_deadline = label == "" || immediate ? {} : time.tick_add(now, TOOLTIP_DELAY)
	if label != "" {w.tooltip_anchor = point}
	w.dirty = true
}

tooltip_cancel :: proc(w: ^Window) {
	if w.tooltip == "" && w.tooltip_deadline == {} && w.tooltip_warm_until == {} {return}
	w.tooltip, w.tooltip_deadline, w.tooltip_warm_until, w.tooltip_visible = "", {}, {}, false
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
	width := ui.text_width(&w.ui_text, w.tooltip) + 16 * s
	height := 26 * s
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 18 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = ui.RADIUS_CONTROL * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	return ui.draw_text(&w.ui_text, &w.list, w.tooltip, x + 8 * s,
		y + (height - w.ui_text.line_height) / 2 + w.ui_text.ascent, app.theme.text)
}
