package main

import "aio:input"
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
@(private) TOOLTIP_MAX_WIDTH :: f32(480)

@(private)
tooltip_clip :: proc(text: string, limit: int) -> string {
	if len(text) <= limit {return text}
	end := limit
	for end > 0 && !utf8.rune_start(text[end]) {end -= 1}
	return text[:end]
}

@(private)
tooltip_label :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32) -> string {
	label := pointer_surfaces[owner].tooltip
	if label == nil {return ""}
	return tooltip_clip(label(app, w, x, y), TOOLTIP_LIMIT)
}

// The window's tooltip: nil is Cold. Pending shows `label` at `deadline`; Visible shows it; Warm
// (after a visible tooltip was left) shows a neighbour's label at once until `until`. `anchor` is
// where the pointer last was over the label, for the neighbour distance.
Tooltip :: union {
	Tooltip_Pending,
	Tooltip_Visible,
	Tooltip_Warm,
}

Tooltip_Pending :: struct {
	label:    string,
	deadline: time.Tick,
	anchor:   [2]f32,
}

Tooltip_Visible :: struct {
	label:  string,
	anchor: [2]f32,
}

Tooltip_Warm :: struct {
	until:  time.Tick,
	anchor: [2]f32,
}

// What a control would do, shown under its label: a sentence and, for a pane header button, a picture of
// the window afterwards. Built while the tooltip draws, in temporary memory.
Tooltip_Card :: struct {
	description: string,
	preview:     Maybe(ui.Pane_Preview),
}

// A window's tooltip with the text its labels point into: a label may be built for one event in
// temporary memory, so tooltip_store copies it here, and only this file writes either. Window embeds it.
Tooltip_State :: struct {
	tooltip:      Tooltip,
	tooltip_text: [TOOLTIP_LIMIT]u8,
}

// The label the window is waiting to show or showing; empty when Cold or Warm.
tooltip_current :: proc(w: ^Window) -> string {
	#partial switch s in w.tooltip {
	case Tooltip_Pending: return s.label
	case Tooltip_Visible: return s.label
	}
	return ""
}

tooltip_shown :: proc(w: ^Window) -> (string, bool) {
	visible, ok := w.tooltip.(Tooltip_Visible)
	return visible.label, ok
}

tooltip_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	pending, ok := w.tooltip.(Tooltip_Pending)
	return pending.deadline, ok
}

@(private = "file")
tooltip_store :: proc(w: ^Window, label: string) -> string {
	return string(w.tooltip_text[:copy(w.tooltip_text[:], label)])
}

tooltip_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if e.buttons != {} {tooltip_cancel(w); return}
	label := tooltip_label(app, w, owner, f32(e.x), f32(e.y))
	point := [2]f32{f32(e.x), f32(e.y)}
	anchor: [2]f32
	switch s in w.tooltip {
	case Tooltip_Pending: anchor = s.anchor
	case Tooltip_Visible: anchor = s.anchor
	case Tooltip_Warm: anchor = s.anchor
	}
	dx, dy := point.x - anchor.x, point.y - anchor.y
	reach := TOOLTIP_NEIGHBOR_DISTANCE * max(1, w.scale)
	near := dx * dx + dy * dy <= reach * reach
	now := clock_now(&app.clock)
	if label == tooltip_current(w) {
		switch &s in w.tooltip {
		case Tooltip_Pending: s.anchor = point
		case Tooltip_Visible: s.anchor = point
		case Tooltip_Warm: if !near {w.tooltip = nil}
		}
		return
	}
	w.dirty = true
	switch s in w.tooltip {
	case Tooltip_Visible:
		if label == "" {
			w.tooltip = Tooltip_Warm{time.tick_add(now, TOOLTIP_GRACE), anchor}
			return
		}
		if near {
			w.tooltip = Tooltip_Visible{tooltip_store(w, label), point}
			return
		}
	case Tooltip_Warm:
		if label != "" && near && time.tick_diff(now, s.until) > 0 {
			w.tooltip = Tooltip_Visible{tooltip_store(w, label), point}
			return
		}
	case Tooltip_Pending:
	}
	if label == "" {
		w.tooltip = nil
		return
	}
	w.tooltip = Tooltip_Pending{tooltip_store(w, label), time.tick_add(now, TOOLTIP_DELAY), point}
}

tooltip_cancel :: proc(w: ^Window) {
	if w.tooltip == nil {return}
	w.tooltip = nil
	w.dirty = true
}

tooltip_tick :: proc(w: ^Window, now: time.Tick) {
	pending, ok := w.tooltip.(Tooltip_Pending)
	if !ok || time.tick_diff(now, pending.deadline) > 0 {return}
	w.tooltip = Tooltip_Visible{pending.label, pending.anchor}
	w.dirty = true
}

tooltip_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	label, shown := tooltip_shown(w)
	if !shown {return .Ok}
	owner := pointer_target(app, w, w.pointer.x, w.pointer.y)
	if tooltip_label(app, w, owner, w.pointer.x, w.pointer.y) != label {return .Ok}
	if card_of := pointer_surfaces[owner].tooltip_card; card_of != nil {
		card := card_of(app, w, w.pointer.x, w.pointer.y)
		if card.description != "" || card.preview != nil {return tooltip_card_draw(app, w, label, card)}
	}
	s := w.scale
	room := max(0, min(TOOLTIP_MAX_WIDTH * s, f32(w.width) - 8 * s) - 16 * s)
	lines := make([dynamic]string, context.temp_allocator)
	wrapped := make([dynamic]string, context.temp_allocator)
	rest := label
	for line in strings.split_lines_iterator(&rest) {
		ui.wrap(&w.ui_text, line, room, &wrapped)
		append(&lines, ..wrapped[:])
	}
	width := f32(0)
	for line in lines {width = max(width, ui.text_width(&w.ui_text, line))}
	width += 16 * s
	height := ui.HEIGHT_COMPACT * s + f32(len(lines) - 1) * w.ui_text.line_height
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 16 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = ui.RADIUS_CONTROL * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	top := y + (height - f32(len(lines)) * w.ui_text.line_height) / 2
	for line, i in lines {
		baseline := top + f32(i) * w.ui_text.line_height + w.ui_text.ascent
		if result := ui.draw_text(&w.ui_text, &w.list, line, x + 8 * s, baseline, app.theme.text);
		   result != .Ok {return result}
	}
	return .Ok
}

// The label in emphasis, then the picture, then the sentence in detail text wrapped to the picture's width.
@(private = "file")
tooltip_card_draw :: proc(app: ^App, w: ^Window, label: string, card: Tooltip_Card) -> render.Build_Status {
	s := w.scale
	pad, gap := ui.SPACE_2 * s, ui.SPACE_2 * s
	strong := ui.text_styled(&w.ui_text, .Strong)
	detail := ui.text_styled(&w.ui_text, .Detail)
	preview, pictured := card.preview.?
	picture: [2]f32
	if pictured {picture = ui.pane_preview_size(preview, s)}
	room := max(0, min(TOOLTIP_MAX_WIDTH * s, f32(w.width) - 8 * s) - 2 * pad)
	inner := min(room, max(ui.text_width(&strong, label), picture.x, ui.PANE_PREVIEW_WIDTH * s))
	lines := make([dynamic]string, context.temp_allocator)
	if card.description != "" {ui.wrap(&detail, card.description, inner, &lines)}
	width := inner + 2 * pad
	height := pad + strong.line_height + pad
	if pictured {height += gap + picture.y}
	if len(lines) > 0 {height += gap + f32(len(lines)) * detail.line_height}
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 16 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = ui.RADIUS_CONTROL * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	top := y + pad
	if result := ui.draw_text(&strong, &w.list, label, x + pad, top + strong.ascent, app.theme.text);
	   result != .Ok {return result}
	top += strong.line_height
	if pictured {
		top += gap
		if ui.pane_preview_draw(&w.list, app.theme, {x + pad, top}, preview, s) != .None {return .Ok}
		top += picture.y
	}
	if len(lines) > 0 {top += gap}
	for line, i in lines {
		baseline := top + f32(i) * detail.line_height + detail.ascent
		if result := ui.draw_text(&detail, &w.list, line, x + pad, baseline, app.theme.muted);
		   result != .Ok {return result}
	}
	return .Ok
}
