package main

import "aio:commands"
import "cosmos:input"
import "cosmos:render"
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

// Where the shortcut a control's tooltip names comes from: the command the control runs, which the user
// can rebind, or the fixed key the control's own surface handles, taken from the table its key handler
// reads. A string is keycap text for a gesture no single chord stands for, such as "type to start". nil
// names none.
Tooltip_Shortcut :: union {
	Action,
	input.Shortcut,
	string,
}

// The shortcut a control's tooltip shows beside its label, as menus write it, in out
// (commands.SHORTCUT_TEXT_CAP bytes). A command's is its first active shortcut, read at every draw so a
// rebinding shows at once. Empty when the control names none or its command is unbound.
tooltip_shortcut :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32, out: []u8) -> string {
	shortcut_of := pointer_surfaces[owner].shortcut
	if shortcut_of == nil {return ""}
	switch shortcut in shortcut_of(app, w, x, y) {
	case Action: return action_shortcut_text(app, shortcut, out)
	case input.Shortcut: return commands.shortcut_text(shortcut, out)
	case string: return string(out[:copy(out, shortcut)])
	}
	return ""
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
	shortcut_buffer: [commands.SHORTCUT_TEXT_CAP]u8
	shortcut := tooltip_shortcut(app, w, owner, w.pointer.x, w.pointer.y, shortcut_buffer[:])
	if card_of := pointer_surfaces[owner].tooltip_card; card_of != nil {
		card := card_of(app, w, w.pointer.x, w.pointer.y)
		if card.description != "" || card.preview != nil {
			return tooltip_card_draw(app, w, label, shortcut, card)
		}
	}
	s := w.scale
	aside := tooltip_shortcut_width(w, shortcut)
	room := max(0, min(TOOLTIP_MAX_WIDTH * s, f32(w.width) - 8 * s) - 16 * s - aside)
	lines := make([dynamic]string, context.temp_allocator)
	wrapped := make([dynamic]string, context.temp_allocator)
	rest := label
	for line in strings.split_lines_iterator(&rest) {
		ui.wrap(&w.ui_text, line, room, &wrapped)
		append(&lines, ..wrapped[:])
	}
	width := f32(0)
	for line in lines {width = max(width, ui.text_width(&w.ui_text, line))}
	width += 16 * s + aside
	// The first line's band also holds the keycap; the usual padding stays around the lines.
	line := w.ui_text.line_height
	first := tooltip_line_band(w, line, shortcut)
	block := first + f32(len(lines) - 1) * line
	height := ui.HEIGHT_COMPACT * s - line + block
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 16 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = ui.RADIUS_CONTROL * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	top := y + (height - block) / 2
	for text, i in lines {
		line_top := i == 0 ? top + (first - line) / 2 : top + first + f32(i - 1) * line
		if result := ui.draw_text(&w.ui_text, &w.list, text, x + 8 * s, line_top + w.ui_text.ascent,
			   app.theme.text); result != .Ok {return result}
	}
	return tooltip_shortcut_draw(app, w, shortcut, x + width - 8 * s, top, first)
}

// The height of a tooltip's first line: its text, or the shortcut's keycap where that is taller.
@(private = "file")
tooltip_line_band :: proc(w: ^Window, line_height: f32, shortcut: string) -> f32 {
	return shortcut == "" ? line_height : max(line_height, ui.KEYCAP_HEIGHT * w.scale)
}

// The room a shortcut takes beside a tooltip's first line: its keycap and the gap before it.
@(private = "file")
tooltip_shortcut_width :: proc(w: ^Window, shortcut: string) -> f32 {
	if shortcut == "" {return 0}
	keycap := ui.text_styled(&w.ui_text, .Detail)
	return ui.SPACE_2 * w.scale + ui.keycap_width(&keycap, shortcut, w.scale)
}

// The shortcut as a keycap, as the Settings search shows Ctrl+F: ending at `right`, centred in the first
// line's band.
@(private = "file")
tooltip_shortcut_draw :: proc(
	app: ^App, w: ^Window, shortcut: string, right, band_top, band_height: f32,
) -> render.Build_Status {
	if shortcut == "" {return .Ok}
	keycap := ui.text_styled(&w.ui_text, .Detail)
	x := right - ui.keycap_width(&keycap, shortcut, w.scale)
	return ui.keycap_draw(&w.list, &keycap, app.theme, shortcut, x, band_top, band_height, w.scale)
}

// The label in emphasis with the shortcut beside it, then the picture, then the sentence in detail text
// wrapped to the picture's width.
@(private = "file")
tooltip_card_draw :: proc(
	app: ^App, w: ^Window, label, shortcut: string, card: Tooltip_Card,
) -> render.Build_Status {
	s := w.scale
	pad, gap := ui.SPACE_2 * s, ui.SPACE_2 * s
	strong := ui.text_styled(&w.ui_text, .Strong)
	detail := ui.text_styled(&w.ui_text, .Detail)
	preview, pictured := card.preview.?
	picture: [2]f32
	if pictured {picture = ui.pane_preview_size(preview, s)}
	room := max(0, min(TOOLTIP_MAX_WIDTH * s, f32(w.width) - 8 * s) - 2 * pad)
	aside := tooltip_shortcut_width(w, shortcut)
	inner := min(room, max(ui.text_width(&strong, label) + aside, picture.x, ui.PANE_PREVIEW_WIDTH * s))
	lines := make([dynamic]string, context.temp_allocator)
	if card.description != "" {ui.wrap(&detail, card.description, inner, &lines)}
	width := inner + 2 * pad
	band := tooltip_line_band(w, strong.line_height, shortcut)
	height := pad + band + pad
	if pictured {height += gap + picture.y}
	if len(lines) > 0 {height += gap + f32(len(lines)) * detail.line_height}
	x := clamp(w.pointer.x + 12 * s, 4 * s, max(4 * s, f32(w.width) - width - 4 * s))
	y := clamp(w.pointer.y + 16 * s, 4 * s, max(4 * s, f32(w.height) - height - 4 * s))
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return .Ok}
	if ui.panel_draw(&w.list, {rect = {x, y, width, height}, radius = ui.RADIUS_CONTROL * s,
	   scale = s, shadow_y = 2, softness = 8, border = .Stroked}, app.theme) != .None {return .Ok}
	top := y + pad
	label_baseline := top + (band - strong.line_height) / 2 + strong.ascent
	if result := ui.draw_text(&strong, &w.list, label, x + pad, label_baseline, app.theme.text,
		aside > 0 ? max(1, inner - aside) : 0); result != .Ok {return result}
	if result := tooltip_shortcut_draw(app, w, shortcut, x + pad + inner, top, band); result != .Ok {
		return result
	}
	top += band
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
