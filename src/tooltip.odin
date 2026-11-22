package main

import "aio:commands"
import "cosmos:input"
import "cosmos:render"
import "aio:views"
import "core:strings"
import "core:time"
import "cosmos:ui"
import "cosmos:host"

@(private) TOOLTIP_MAX_WIDTH :: f32(480)

@(private)
tooltip_label :: proc(app: ^App, w: ^Window, owner: Pointer_Target, x, y: f32) -> string {
	label := pointer_tips[owner].tooltip
	if label == nil {return ""}
	return ui.tooltip_clip(label(app, w, x, y), ui.TOOLTIP_LIMIT)
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
	shortcut_of := pointer_tips[owner].shortcut
	if shortcut_of == nil {return ""}
	switch shortcut in shortcut_of(app, w, x, y) {
	case Action: return action_shortcut_text(app, shortcut, out)
	case input.Shortcut: return commands.shortcut_text(shortcut, out)
	case string: return string(out[:copy(out, shortcut)])
	}
	return ""
}

// What a control would do, shown under its label: a sentence and, for a pane header button, a picture of
// the window afterwards. Built while the tooltip draws, in temporary memory.
Tooltip_Card :: struct {
	description: string,
	preview:     Maybe(views.Pane_Preview),
}

tooltip_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	label := e.buttons != {} ? "" : tooltip_label(app, w, owner, x, y)
	now := host.clock_now(&app.clock)
	if ui.tooltip_hover(&w.tooltip_state, label, {x, y}, w.scale, now, e.buttons != {}) {w.dirty = true}
}

tooltip_cancel :: proc(w: ^Window) {
	if ui.tooltip_cancel(&w.tooltip_state) {w.dirty = true}
}

tooltip_tick :: proc(w: ^Window, now: time.Tick) {
	if ui.tooltip_tick(&w.tooltip_state, now) {w.dirty = true}
}

tooltip_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	label, shown := ui.tooltip_shown(&w.tooltip_state)
	if !shown {return .Ok}
	owner := pointer_target(app, w, w.pointer.x, w.pointer.y)
	if tooltip_label(app, w, owner, w.pointer.x, w.pointer.y) != label {return .Ok}
	shortcut_buffer: [commands.SHORTCUT_TEXT_CAP]u8
	shortcut := tooltip_shortcut(app, w, owner, w.pointer.x, w.pointer.y, shortcut_buffer[:])
	if card_of := pointer_tips[owner].tooltip_card; card_of != nil {
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
	if pictured {picture = views.pane_preview_size(preview, s)}
	room := max(0, min(TOOLTIP_MAX_WIDTH * s, f32(w.width) - 8 * s) - 2 * pad)
	aside := tooltip_shortcut_width(w, shortcut)
	inner := min(room, max(ui.text_width(&strong, label) + aside, picture.x, views.PANE_PREVIEW_WIDTH * s))
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
		if views.pane_preview_draw(&w.list, app.theme, {x + pad, top}, preview, s) != .None {return .Ok}
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
