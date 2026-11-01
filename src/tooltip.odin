package main

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:ui"
import "core:time"

@(private) TOOLTIP_DELAY :: 700 * time.Millisecond

@(private)
tooltip_label :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32) -> string {
	label := pointer_surfaces[owner].tooltip
	return label != nil ? label(app, w, x, y) : ""
}

tooltip_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	label := e.buttons == {} ? tooltip_label(app, w, owner, f32(e.x), f32(e.y)) : ""
	if label == w.tooltip {return}
	w.tooltip = label
	w.tooltip_visible = false
	w.tooltip_deadline = label == "" ? {} : time.tick_add(time.tick_now(), TOOLTIP_DELAY)
	w.dirty = true
}

tooltip_tick :: proc(w: ^Window) {
	if w.tooltip_deadline == {} || time.tick_diff(time.tick_now(), w.tooltip_deadline) > 0 {return}
	w.tooltip_deadline = {}
	w.tooltip_visible = true
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
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = 5 * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	return ui.draw_text(&w.ui_text, &w.list, w.tooltip, x + 8 * s,
		y + (height + w.ui_text.ascent) / 2 - 2 * s, app.theme.text)
}
