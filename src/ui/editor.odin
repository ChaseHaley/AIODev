package ui

import "base:runtime"
import "core:fmt"
import "core:time"
import "core:strings"
import "core:unicode/utf8"
import "aio:glyphs"
import "aio:platform"
import "aio:render"

Text_Field :: struct {
	bytes: [dynamic]u8,
	cursor: int,
	selected: bool,
}

field_set :: proc(f: ^Text_Field, value: string) {
	clear(&f.bytes)
	append(&f.bytes, ..transmute([]u8)value)
	f.cursor, f.selected = len(f.bytes), false
}

field_text :: proc(f: ^Text_Field, text: string) {
	if !utf8.valid_string(text) { return }
	if f.selected { field_set(f, "") }
	for r in text {
		if r < ' ' || r == 0x7f { continue }
		encoded, n := utf8.encode_rune(r)
		before := len(f.bytes)
		if resize(&f.bytes, before+n) != nil { return }
		copy(f.bytes[f.cursor+n:], f.bytes[f.cursor:before])
		copy(f.bytes[f.cursor:], encoded[:n])
		f.cursor += n
	}
}

field_key :: proc(f: ^Text_Field, e: platform.Key_Event) {
	control := .Control in e.modifiers
	#partial switch e.key {
	case .A:
		if control { f.selected = true; return }
	case .Home: f.cursor, f.selected = 0, false; return
	case .End: f.cursor, f.selected = len(f.bytes), false; return
	case .Arrow_Left:
		if f.cursor > 0 {
			_, n := utf8.decode_last_rune(f.bytes[:f.cursor])
			f.cursor -= n
		}
		f.selected = false
		return
	case .Arrow_Right:
		if f.cursor < len(f.bytes) {
			_, n := utf8.decode_rune(f.bytes[f.cursor:])
			f.cursor += n
		}
		f.selected = false
		return
	case .Backspace, .Delete:
		if f.selected { field_set(f, ""); return }
		start, end := f.cursor, f.cursor
		if e.key == .Backspace && start > 0 {
			_, n := utf8.decode_last_rune(f.bytes[:start])
			start -= n
		} else if e.key == .Delete && end < len(f.bytes) {
			_, n := utf8.decode_rune(f.bytes[end:])
			end += n
		}
		copy(f.bytes[start:], f.bytes[end:])
		resize(&f.bytes, len(f.bytes)-(end-start))
		f.cursor = start
		return
	}
	if !control || .Alt in e.modifiers { field_text(f, e.text) }
}

Editor_Row :: struct { key, title, description, value, default_value: string }
Editor :: struct {
	open, editing: bool,
	hover, pressed, button_focus: int,
	controls: [3]Control_Motion,
	rows: [dynamic]Editor_Row,
	matches: [dynamic]int,
	selected, scroll, visible_rows: int,
	filter, value: Text_Field,
	source: string,
	message: string,
	error: bool,
}
Editor_Outcome :: enum { None, Changed, Save, Reset, Closed }
Editor_Layout :: struct {
	panel, filter, list, value, save, reset, close: render.Rect,
	row_height: f32,
	rows: int,
}

editor_destroy :: proc(p: ^Editor) {
	for row in p.rows {
		for s in ([?]string{row.key, row.title, row.description, row.value, row.default_value}) {
			delete(s)
		}
	}
	delete(p.rows)
	delete(p.matches)
	delete(p.filter.bytes)
	delete(p.value.bytes)
	delete(p.source)
	delete(p.message)
	p^ = {}
}

@(require_results)
editor_add :: proc(p: ^Editor, row: Editor_Row) -> runtime.Allocator_Error {
	owned: [5]string
	success := false
	defer if !success { for s in owned { delete(s) } }
	for s, i in ([?]string{row.key, row.title, row.description, row.value, row.default_value}) {
		copy, err := strings.clone(s)
		if err != nil { return err }
		owned[i] = copy
	}
	_, err := append(&p.rows, Editor_Row{owned[0], owned[1], owned[2], owned[3], owned[4]})
	success = err == nil
	return err
}

editor_message :: proc(p: ^Editor, text: string, error: bool) {
	delete(p.message)
	p.message = strings.clone(text)
	p.error = error
}

editor_row :: proc(p: ^Editor) -> ^Editor_Row {
	if p.selected < 0 || p.selected >= len(p.matches) { return nil }
	return &p.rows[p.matches[p.selected]]
}

editor_select :: proc(p: ^Editor, index: int) {
	p.selected = clamp(index, 0, max(0, len(p.matches)-1))
	if row := editor_row(p); row != nil { field_set(&p.value, row.value) }
	if p.selected < p.scroll { p.scroll = p.selected }
	if p.selected >= p.scroll+max(1, p.visible_rows) {
		p.scroll = p.selected-max(1, p.visible_rows)+1
	}
}

editor_filter :: proc(p: ^Editor) {
	clear(&p.matches)
	query := strings.to_lower(string(p.filter.bytes[:]), context.temp_allocator)
	for row, i in p.rows {
		haystack := strings.to_lower(fmt.tprintf("%s %s %s", row.key, row.title, row.description),
			context.temp_allocator)
		if strings.contains(haystack, query) { append(&p.matches, i) }
	}
	p.scroll = 0
	editor_select(p, 0)
}

editor_key :: proc(p: ^Editor, e: platform.Key_Event) -> Editor_Outcome {
	if !e.pressed { return .None }
	#partial switch e.key {
	case .Escape: p.open = false; return .Closed
	case .Tab:
		focus := p.button_focus > 0 ? p.button_focus+1 : (p.editing ? 1 : 0)
		if .Shift in e.modifiers { focus = (focus+4)%5 } else { focus = (focus+1)%5 }
		p.button_focus = focus >= 2 ? focus-1 : 0
		p.editing = focus == 1
		return .Changed
	case .Arrow_Up: editor_select(p, p.selected-1); return .Changed
	case .Arrow_Down: editor_select(p, p.selected+1); return .Changed
	case .Page_Up: editor_select(p, p.selected-max(1, p.visible_rows)); return .Changed
	case .Page_Down: editor_select(p, p.selected+max(1, p.visible_rows)); return .Changed
	case .Enter, .Numpad_Enter:
		if p.button_focus == 1 { return editor_row(p) == nil ? .None : .Save }
		if p.button_focus == 2 { return editor_row(p) == nil ? .None : .Reset }
		if p.button_focus == 3 { p.open = false; return .Closed }
		if p.editing { return .Save }
		p.editing = true
		return .Changed
	case .R:
		if .Control in e.modifiers { return .Reset }
	}
	if p.button_focus > 0 { return .None }
	if p.editing { field_key(&p.value, e) }
	else { field_key(&p.filter, e); editor_filter(p) }
	return .Changed
}

editor_text :: proc(p: ^Editor, text: string) {
	if p.button_focus > 0 { return }
	if p.editing { field_text(&p.value, text) }
	else { field_text(&p.filter, text); editor_filter(p) }
}

editor_layout :: proc(width, height, scale: f32) -> Editor_Layout {
	margin := 12*scale
	w, h := max(0, min(840*scale, width-2*margin)), max(0, min(650*scale, height-2*margin))
	x, y := (width-w)/2, (height-h)/2
	pad := 16*scale
	l := Editor_Layout{panel = {x, y, w, h}, row_height = 30*scale}
	l.filter = {x+pad, y+48*scale, max(0, w-2*pad), 34*scale}
	l.rows = max(0, int((h-306*scale)/l.row_height))
	l.list = {x+pad, l.filter.y+44*scale, max(0, w-2*pad), f32(l.rows)*l.row_height}
	l.value = {x+pad, l.list.y+l.list.height+76*scale, max(0, w-2*pad), 36*scale}
	l.save = {x+pad, y+h-48*scale, 120*scale, 26*scale}
	l.reset = {l.save.x+132*scale, l.save.y, 132*scale, l.save.height}
	l.close = {x+w-pad-82*scale, l.save.y, 82*scale, l.save.height}
	return l
}

@(private)
editor_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height
}

editor_click :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> Editor_Outcome {
	if editor_contains(l.close, x, y) { p.open = false; return .Closed }
	if editor_contains(l.save, x, y) { return editor_row(p) == nil ? .None : .Save }
	if editor_contains(l.reset, x, y) { return editor_row(p) == nil ? .None : .Reset }
	if editor_contains(l.filter, x, y) { p.editing = false; p.button_focus = 0 }
	if editor_contains(l.value, x, y) { p.editing = true; p.button_focus = 0 }
	if editor_contains(l.list, x, y) {
		i := p.scroll+int((y-l.list.y)/l.row_height)
		if i < len(p.matches) { editor_select(p, i); p.editing = true; p.button_focus = 0 }
	}
	return .Changed
}

editor_draw :: proc(p: ^Editor, list: ^render.Draw_List, text: ^Text, theme: Theme,
	width, height, scale: f32) -> glyphs.Result {
	l := editor_layout(width, height, scale)
	p.visible_rows = l.rows
	if render.push_layer(list, {0, 0, width, height}) != .None { return .Ok }
	draw_rect(list, {rect = {0, 0, width, height}, color = theme.scrim})
	shadow := l.panel
	shadow.y += 12*scale
	draw_rect(list, {rect = shadow, color = theme.shadow, radius = 10*scale, softness = 32*scale})
	draw_rect(list, {rect = l.panel, color = theme.surface, radius = 10*scale})
	draw_rect(list, {rect = l.panel, color = theme.border, radius = 10*scale, stroke = scale})
	if render.push_layer(list, l.panel) != .None { return .Ok }
	x, y := l.filter.x, l.panel.y+28*scale
	if r := draw_text(text, list, "Settings", x, y, theme.text); r != .Ok { return r }
	count := fmt.tprintf("%d results", len(p.matches))
	if r := draw_text(text, list, count, x+110*scale, y, theme.muted,
		max(1, l.panel.width-140*scale)); r != .Ok { return r }
	if r := editor_field_draw(&p.filter, list, text, theme, l.filter, !p.editing && p.button_focus == 0,
		"Filter settings and shortcuts", scale); r != .Ok { return r }
	for index in p.scroll..<min(len(p.matches), p.scroll+l.rows) {
		row := p.rows[p.matches[index]]
		r := render.Rect{l.list.x, l.list.y+f32(index-p.scroll)*l.row_height, l.list.width, l.row_height}
		if index == p.selected { draw_rect(list, {rect = r, color = theme.selection, radius = 6*scale}) }
		baseline := r.y+(r.height-text.line_height)/2+text.ascent
		if result := draw_text(text, list, row.title, r.x+8*scale, baseline, theme.text,
			max(1, r.width*0.58-16*scale)); result != .Ok { return result }
		if result := draw_text(text, list, row.value, r.x+r.width*0.60, baseline, theme.muted,
			max(1, r.width*0.4-8*scale)); result != .Ok { return result }
	}
	if row := editor_row(p); row != nil {
		if r := draw_text(text, list, row.key, x, l.value.y-52*scale, theme.accent,
			max(1, l.value.width)); r != .Ok { return r }
		small := text_styled(text, .Small)
		if r := draw_text(&small, list, row.description, x, l.value.y-28*scale, theme.muted,
			max(1, l.value.width)); r != .Ok { return r }
	}
	if r := editor_field_draw(&p.value, list, text, theme, l.value, p.editing && p.button_focus == 0,
		"Empty value", scale); r != .Ok { return r }
	status := p.message
	if status == "" { status = "Tab: move focus   Up/Down: select   Enter: activate   Esc: close" }
	if r := draw_text(text, list, status, x, l.value.y+59*scale, p.error ? theme.error : theme.muted,
		max(1, l.value.width)); r != .Ok { return r }
	for rect, i in ([?]render.Rect{l.save, l.reset, l.close}) {
		disabled := i < 2 && editor_row(p) == nil
		layers, rect_start, glyph_start := len(list.layers), len(list.rects), len(list.glyphs)
		strong := text_styled(text, i == 0 ? .Strong : .Body)
		draw_rect(list, {rect = rect, color = i == 0 ? theme.accent : theme.surface, radius = 6*scale})
		if i != 0 { draw_rect(list, {rect = rect, color = theme.border, radius = 6*scale, stroke = scale}) }
		fill := theme.hover
		fill.a *= p.controls[i].hover.value
		draw_rect(list, {rect = rect, color = fill, radius = 6*scale})
		fill = theme.pressed
		fill.a *= p.controls[i].press.value
		draw_rect(list, {rect = rect, color = fill, radius = 6*scale})
		if p.button_focus == i+1 { focus_ring_draw(list, rect, theme, scale) }
		labels := [?]string{"Save change", "Reset default", "Close"}
		if r := draw_text(&strong, list, labels[i], rect.x+10*scale,
			rect.y+(rect.height-text.line_height)/2+text.ascent, i == 0 ? theme.accent_text : theme.text,
			max(1, rect.width-20*scale)); r != .Ok { return r }
		if disabled { fade_draw(list, layers, rect_start, glyph_start, 0.45, 0) }
	}
	return .Ok
}

@(private)
editor_field_draw :: proc(f: ^Text_Field, list: ^render.Draw_List, base: ^Text, theme: Theme,
	r: render.Rect, focused: bool, placeholder: string, scale: f32) -> glyphs.Result {
	input_text := text_styled(base, .Input)
	text := &input_text
	draw_rect(list, {rect = r, color = theme.border, radius = 6*scale})
	if focused { focus_ring_draw(list, r, theme, scale) }
	value := string(f.bytes[:])
	available := max(1, r.width-20*scale)
	start := 0
	for start < f.cursor && text_width(text, value[start:f.cursor]) > available-4*scale {
		_, n := utf8.decode_rune(value[start:])
		start += n
	}
	shown := value[start:]
	if value == "" { shown = placeholder }
	x := r.x+10*scale
	baseline := r.y+(r.height-text.line_height)/2+text.ascent
	if f.selected && focused {
		draw_rect(list, {rect = {x, baseline-text.ascent, min(available, text_width(text, shown)),
			text.line_height}, color = theme.accent})
	}
	if result := draw_text(text, list, shown, x, baseline, value == "" ? theme.muted : (f.selected && focused ? theme.accent_text : theme.text),
		available); result != .Ok { return result }
	if focused {
		caret := x+min(available, text_width(text, value[start:f.cursor]))
		draw_rect(list, {rect = {caret, baseline-text.ascent, scale, text.line_height}, color = theme.accent})
	}
	return .Ok
}

editor_pointer :: proc(p: ^Editor, width, height, scale, x, y: f32, pressed: bool) -> bool {
	previous_hover, previous_press := p.hover, p.pressed
	l := editor_layout(width, height, scale)
	p.hover = 0
	for rect, i in ([?]render.Rect{l.save, l.reset, l.close}) {
		if editor_contains(rect, x, y) && (i == 2 || editor_row(p) != nil) { p.hover = i+1 }
	}
	p.pressed = pressed ? p.hover : 0
	return p.hover != previous_hover || p.pressed != previous_press
}

editor_animating :: proc(p: ^Editor) -> bool {
	if !p.open { return false }
	for control in p.controls { if control_active(control) { return true } }
	return false
}

editor_animate :: proc(p: ^Editor, now: time.Tick, enabled: bool) -> bool {
	if !p.open { return false }
	changed := false
	for &control, i in p.controls {
		changed = control_update(&control, p.hover == i+1, p.pressed == i+1, enabled, now) || changed
	}
	return changed
}
