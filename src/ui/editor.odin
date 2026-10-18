package ui

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import "aio:commands"
import "aio:glyphs"
import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:settings"

Row_Kind :: enum { Text, Integer, Number, Toggle, Choice, Color, Optional_Color, Shortcut }

// Strings are owned by the editor except `choices`, which borrows static schema names. An empty optional
// color shows `fallback`, the theme color it resolves to.
Editor_Row :: struct {
	key, title, description, value, default_value, fallback: string,
	group: int,
	kind: Row_Kind,
	minimum, maximum: f64,
	choices: []string,
}

// Browsing and filtering keep separate collapse states, so clearing a filter restores the browse view.
Editor_Group :: struct {
	title: string,
	collapsed, filter_collapsed: bool,
}

// One visible list line: a group header, with its matching row count, when row is -1.
Editor_Item :: struct { group, row, count: int }

Editor_Drag :: enum { None, Filter, Value, Slider, Wheel, Ramp }

Editor :: struct {
	open, editing, capturing, leader_pending: bool,
	// Captured shortcuts name physical key positions (Physical+) instead of layout characters.
	physical: bool,
	hover, pressed, button_focus: int,
	controls: [3]Control_Motion,
	rows: [dynamic]Editor_Row,
	groups: [dynamic]Editor_Group,
	items: [dynamic]Editor_Item,
	selected, scroll, visible_rows, captured: int,
	filter, value: Text_Field,
	drag: Editor_Drag,
	// The picker keeps hue and saturation while value is zero, where RGB alone would lose them.
	hsv: [3]f32,
	leader: Maybe(commands.Shortcut),
	source: string,
	message: string,
	error: bool,
}
Editor_Outcome :: enum { None, Changed, Save, Reset, Closed }
Editor_Layout :: struct {
	panel, filter, list, detail, value, save, reset, close: render.Rect,
	slider, toggle, positions, wheel, ramp, swatch, theme_default: render.Rect,
	choices: [8]render.Rect,
	row_height: f32,
	rows: int,
}

CAPTURE_HINT :: "Press a shortcut. Enter saves, Esc cancels, Backspace clears, Tab leaves."
@(private) EDITOR_DETAIL_HEIGHT :: 196

editor_destroy :: proc(p: ^Editor) {
	for row in p.rows {
		for s in ([?]string{row.key, row.title, row.description, row.value, row.default_value, row.fallback}) {
			delete(s)
		}
	}
	for group in p.groups { delete(group.title) }
	delete(p.rows)
	delete(p.groups)
	delete(p.items)
	delete(p.filter.bytes)
	delete(p.value.bytes)
	delete(p.source)
	delete(p.message)
	p^ = {}
}

@(require_results)
editor_add :: proc(p: ^Editor, row: Editor_Row, group: string) -> runtime.Allocator_Error {
	group_index := -1
	for g, i in p.groups { if g.title == group { group_index = i } }
	if group_index < 0 {
		title := strings.clone(group) or_return
		if _, err := append(&p.groups, Editor_Group{title = title}); err != nil { delete(title); return err }
		group_index = len(p.groups)-1
	}
	owned: [6]string
	success := false
	defer if !success { for s in owned { delete(s) } }
	for s, i in ([?]string{row.key, row.title, row.description, row.value, row.default_value, row.fallback}) {
		owned[i] = strings.clone(s) or_return
	}
	added := row
	added.key, added.title, added.description, added.value, added.default_value, added.fallback =
		owned[0], owned[1], owned[2], owned[3], owned[4], owned[5]
	added.group = group_index
	_, err := append(&p.rows, added)
	success = err == nil
	return err
}

editor_collapse :: proc(p: ^Editor, group: string, collapsed: bool) {
	for &g in p.groups { if g.title == group { g.collapsed = collapsed } }
}

editor_message :: proc(p: ^Editor, text: string, error: bool) {
	delete(p.message)
	p.message = strings.clone(text)
	p.error = error
}

editor_row :: proc(p: ^Editor) -> ^Editor_Row {
	if p.selected < 0 || p.selected >= len(p.items) || p.items[p.selected].row < 0 { return nil }
	return &p.rows[p.items[p.selected].row]
}

editor_capturing :: proc(p: ^Editor) -> bool { return p.open && p.capturing }

@(private)
filtering :: proc(p: ^Editor) -> bool { return strings.trim_space(field_string(&p.filter)) != "" }

@(private)
group_collapsed :: proc(p: ^Editor, group: int) -> ^bool {
	return filtering(p) ? &p.groups[group].filter_collapsed : &p.groups[group].collapsed
}

@(private)
color_or_fallback :: proc(row: ^Editor_Row, value: string) -> string {
	return value == "" ? row.fallback : value
}

@(private)
sync_color :: proc(p: ^Editor) {
	row := editor_row(p)
	if row == nil || (row.kind != .Color && row.kind != .Optional_Color) { return }
	c, ok, _ := settings.parse_color(color_or_fallback(row, field_string(&p.value)))
	if !ok || settings.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2]) == c { return }
	h, s, v := settings.rgb_to_hsv(c)
	if s == 0 || v == 0 { h = p.hsv[0] }
	if v == 0 { s = p.hsv[1] }
	p.hsv = {h, s, v}
}

@(private)
stop_editing :: proc(p: ^Editor) {
	p.editing, p.capturing, p.leader_pending, p.captured = false, false, false, 0
	p.drag = .None
	if row := editor_row(p); row != nil {
		field_set(&p.value, row.value)
		sync_color(p)
	}
}

editor_select :: proc(p: ^Editor, index: int) {
	p.selected = clamp(index, 0, max(0, len(p.items)-1))
	if p.button_focus == 4 { p.button_focus = 0 }
	p.capturing, p.leader_pending, p.captured, p.drag = false, false, 0, .None
	if row := editor_row(p); row != nil {
		field_set(&p.value, row.value)
		p.hsv = {0, 0, 1}
		sync_color(p)
		if row.kind == .Shortcut { p.editing = false }
	} else {
		p.editing = false
	}
	if p.selected < p.scroll { p.scroll = p.selected }
	if p.selected >= p.scroll+max(1, p.visible_rows) {
		p.scroll = p.selected-max(1, p.visible_rows)+1
	}
}

editor_select_key :: proc(p: ^Editor, key: string) -> bool {
	for row, i in p.rows {
		if row.key != key { continue }
		group_collapsed(p, row.group)^ = false
		editor_rebuild(p)
		for item, index in p.items {
			if item.row == i { editor_select(p, index); return true }
		}
	}
	return false
}

// Each query word matches as written or, for plurals such as "panes", without its final s.
@(private)
row_matches :: proc(words: []string, haystack: string) -> bool {
	for word in words {
		if strings.contains(haystack, word) { continue }
		if len(word) > 3 && word[len(word)-1] == 's' && strings.contains(haystack, word[:len(word)-1]) {
			continue
		}
		return false
	}
	return true
}

// Rebuilds the visible lines, keeping the current selection when it stays visible.
editor_rebuild :: proc(p: ^Editor) {
	selected := Editor_Item{-1, -1, 0}
	if p.selected >= 0 && p.selected < len(p.items) { selected = p.items[p.selected] }
	clear(&p.items)
	query := strings.to_lower(strings.trim_space(field_string(&p.filter)), context.temp_allocator)
	words := strings.fields(query, context.temp_allocator)
	matched := make([dynamic]int, context.temp_allocator)
	for group, g in p.groups {
		clear(&matched)
		for row, i in p.rows {
			if row.group != g { continue }
			haystack := strings.to_lower(fmt.tprintf("%s %s %s %s", row.key, row.title, group.title,
				row.description), context.temp_allocator)
			if row_matches(words, haystack) { append(&matched, i) }
		}
		if len(matched) == 0 { continue }
		append(&p.items, Editor_Item{g, -1, len(matched)})
		if group_collapsed(p, g)^ { continue }
		for i in matched { append(&p.items, Editor_Item{g, i, 0}) }
	}
	p.selected = 0
	for item, index in p.items {
		if item.group == selected.group && item.row == selected.row { p.selected = index }
	}
}

editor_filter :: proc(p: ^Editor) {
	for &group in p.groups { group.filter_collapsed = false }
	clear(&p.items)
	editor_rebuild(p)
	first := 0
	if filtering(p) {
		for item, index in p.items { if item.row >= 0 { first = index; break } }
	}
	p.scroll = 0
	editor_select(p, first)
}

editor_toggle_group :: proc(p: ^Editor, index: int) {
	if index < 0 || index >= len(p.items) { return }
	group := p.items[index].group
	collapsed := group_collapsed(p, group)
	collapsed^ = !collapsed^
	editor_rebuild(p)
	for line, i in p.items {
		if line.group == group && line.row < 0 { editor_select(p, i); return }
	}
}

@(private)
number_text :: proc(row: ^Editor_Row, value: f64) -> string {
	if row.kind == .Integer { return fmt.tprintf("%d", int(math.round(value))) }
	return fmt.tprintf("%g", math.round(value*10)/10)
}

// Wide ranges such as scrollback lines use a logarithmic track so small values stay reachable.
@(private)
slider_fraction :: proc(row: ^Editor_Row, value: f64) -> f32 {
	span := row.maximum-row.minimum
	if span <= 0 { return 0 }
	v := clamp(value, row.minimum, row.maximum)
	if span > 1000 { return f32(math.ln(v-row.minimum+1)/math.ln(span+1)) }
	return f32((v-row.minimum)/span)
}

@(private)
slider_value :: proc(row: ^Editor_Row, fraction: f32) -> f64 {
	f := f64(clamp(fraction, 0, 1))
	span := row.maximum-row.minimum
	if span > 1000 { return row.minimum+math.exp(f*math.ln(span+1))-1 }
	return row.minimum+f*span
}

@(private)
flip_toggle :: proc(p: ^Editor) -> Editor_Outcome {
	field_set(&p.value, field_string(&p.value) == "true" ? "false" : "true")
	return .Save
}

@(private)
choose :: proc(p: ^Editor, row: ^Editor_Row, delta: int) -> Editor_Outcome {
	if len(row.choices) == 0 { return .None }
	current := 0
	for name, i in row.choices { if name == field_string(&p.value) { current = i } }
	next := clamp(current+delta, 0, len(row.choices)-1)
	if next == current { return .None }
	field_set(&p.value, row.choices[next])
	return .Save
}

@(private)
start_capture :: proc(p: ^Editor) {
	p.editing, p.capturing, p.leader_pending, p.captured, p.button_focus = true, true, false, 0, 0
	editor_message(p, CAPTURE_HINT, false)
}

@(private)
is_modifier :: proc(key: input.Key) -> bool {
	#partial switch key {
	case .Shift_Left, .Shift_Right, .Control_Left, .Control_Right, .Alt_Left, .Alt_Right,
	     .Meta_Left, .Meta_Right, .Caps_Lock, .Num_Lock:
		return true
	}
	return false
}

// Records chords pressed while a shortcut field captures. Pressing the leader first adds Leader+.
@(private)
capture_key :: proc(p: ^Editor, row: ^Editor_Row, e: platform.Key_Event) -> Editor_Outcome {
	if is_modifier(e.key) { return .None }
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if modifiers == {} && !p.leader_pending {
		#partial switch e.key {
		case .Escape:
			stop_editing(p)
			editor_message(p, "", false)
			return .Changed
		case .Enter, .Numpad_Enter:
			p.capturing = false
			return .Save
		case .Backspace, .Delete:
			field_set(&p.value, "")
			p.captured = 0
			return .Changed
		case .Tab:
			p.capturing, p.editing, p.button_focus = false, false, 1
			editor_message(p, "", false)
			return .Changed
		}
	}
	chord := commands.Shortcut{p.physical ? e.key : commands.logical_key(e.key, e.unshifted), modifiers}
	if p.physical { chord.modifiers += {.Physical} }
	binding := strings.has_prefix(row.key, settings.KEY_BINDING_PREFIX)
	if leader, ok := p.leader.?; ok && binding && !p.leader_pending &&
	   commands.shortcut_matches(leader, e.key, modifiers, e.unshifted) {
		p.leader_pending = true
		editor_message(p, "Leader pressed; press the key that follows it.", false)
		return .Changed
	}
	if p.leader_pending {
		chord.modifiers += {.Leader}
		p.leader_pending = false
	} else if modifiers & {.Control, .Alt, .Super} == {} && e.text != "" {
		editor_message(p, "Typing keys need Ctrl, Alt, or the leader.", true)
		return .Changed
	}
	buffer: [128]u8
	label, err := commands.shortcut_label(chord, buffer[:])
	if err != .None { return .None }
	if !binding || p.captured == 0 || p.captured >= commands.MAX_SHORTCUTS {
		field_set(&p.value, label)
		p.captured = 1
	} else {
		field_set(&p.value, fmt.tprintf("%s, %s", field_string(&p.value), label))
		p.captured += 1
	}
	editor_message(p, CAPTURE_HINT, false)
	return .Changed
}

@(private)
text_kind :: proc(kind: Row_Kind) -> bool {
	return kind == .Text || kind == .Integer || kind == .Number || kind == .Color || kind == .Optional_Color
}

// Takes the raw key event: capture needs the physical key, and navigation uses the layout's key.
editor_key :: proc(p: ^Editor, raw: platform.Key_Event) -> Editor_Outcome {
	if !raw.pressed { return .None }
	row := editor_row(p)
	if p.capturing && row != nil { return capture_key(p, row, raw) }
	e := raw
	e.key = commands.logical_key(raw.key, raw.unshifted)
	control := .Control in e.modifiers
	#partial switch e.key {
	case .Escape:
		p.open = false
		return .Closed
	case .Tab:
		stops := row != nil && row.kind == .Shortcut ? 6 : 5
		focus := p.button_focus > 0 ? p.button_focus+1 : (p.editing ? 1 : 0)
		if .Shift in e.modifiers { focus = (focus+stops-1)%stops } else { focus = (focus+1)%stops }
		if focus == 1 && row == nil { focus = .Shift in e.modifiers ? 0 : 2 }
		p.button_focus = focus >= 2 ? focus-1 : 0
		if focus == 1 && row.kind == .Shortcut { start_capture(p) } else { p.editing = focus == 1 }
		return .Changed
	case .Arrow_Up: editor_select(p, p.selected-1); return .Changed
	case .Arrow_Down: editor_select(p, p.selected+1); return .Changed
	case .P, .N:
		if control && .Alt not_in e.modifiers {
			editor_select(p, p.selected+(e.key == .N ? 1 : -1))
			return .Changed
		}
	case .Page_Up: editor_select(p, p.selected-max(1, p.visible_rows)); return .Changed
	case .Page_Down: editor_select(p, p.selected+max(1, p.visible_rows)); return .Changed
	case .Enter, .Numpad_Enter:
		if p.button_focus == 1 { return row == nil ? .None : .Save }
		if p.button_focus == 2 { return row == nil ? .None : .Reset }
		if p.button_focus == 3 { p.open = false; return .Closed }
		if p.button_focus == 4 { p.physical = !p.physical; return .Changed }
		if row == nil { editor_toggle_group(p, p.selected); return .Changed }
		if row.kind == .Shortcut { start_capture(p); return .Changed }
		if p.editing {
			if row.kind == .Toggle { return flip_toggle(p) }
			return .Save
		}
		p.editing = true
		return .Changed
	case .Space:
		if p.button_focus == 4 { p.physical = !p.physical; return .Changed }
		if p.editing && row != nil && row.kind == .Toggle { return flip_toggle(p) }
	case .Arrow_Left, .Arrow_Right:
		left := e.key == .Arrow_Left
		if p.editing && row != nil && row.kind == .Choice { return choose(p, row, left ? -1 : 1) }
		if !p.editing && p.button_focus == 0 && row == nil && len(p.filter.bytes) == 0 && len(p.items) > 0 {
			if group_collapsed(p, p.items[p.selected].group)^ != left { editor_toggle_group(p, p.selected) }
			return .Changed
		}
	case .R:
		if control { return .Reset }
	}
	if p.button_focus > 0 { return .None }
	if p.editing {
		if row != nil && text_kind(row.kind) && field_key(&p.value, e) == .Edited { sync_color(p) }
		return .Changed
	}
	if field_key(&p.filter, e) == .Edited { editor_filter(p) }
	return .Changed
}

editor_text :: proc(p: ^Editor, text: string) {
	if p.button_focus > 0 || p.capturing { return }
	if p.editing {
		if row := editor_row(p); row != nil && text_kind(row.kind) && field_text(&p.value, text) == .Edited {
			sync_color(p)
		}
	} else if field_text(&p.filter, text) == .Edited {
		editor_filter(p)
	}
}

// Pasted text replaces the focused field's selection up to its first line break.
editor_paste :: proc(p: ^Editor, text: string) {
	line := text
	if end := strings.index_any(text, "\r\n"); end >= 0 { line = text[:end] }
	editor_text(p, line)
}

// The selected text of the focused field, for copying.
editor_selection :: proc(p: ^Editor) -> string {
	if p.capturing || p.button_focus > 0 { return "" }
	if p.editing { return field_selected_text(&p.value) }
	return field_selected_text(&p.filter)
}

// Removes the selected text of the focused field after it was copied.
editor_cut :: proc(p: ^Editor) {
	if editor_selection(p) == "" { return }
	if p.editing {
		if row := editor_row(p); row != nil && text_kind(row.kind) {
			field_text(&p.value, "")
			sync_color(p)
		}
	} else {
		field_text(&p.filter, "")
		editor_filter(p)
	}
}

editor_layout :: proc(p: ^Editor, width, height, scale: f32) -> Editor_Layout {
	margin := 12*scale
	w, h := max(0, min(840*scale, width-2*margin)), max(0, min(680*scale, height-2*margin))
	x, y := (width-w)/2, (height-h)/2
	pad := 16*scale
	inner := max(0, w-2*pad)
	l := Editor_Layout{panel = {x, y, w, h}, row_height = 30*scale}
	l.filter = {x+pad, y+48*scale, inner, 34*scale}
	l.save = {x+pad, y+h-48*scale, 120*scale, 26*scale}
	l.reset = {l.save.x+132*scale, l.save.y, 132*scale, l.save.height}
	l.close = {x+w-pad-82*scale, l.save.y, 82*scale, l.save.height}
	l.detail = {x+pad, l.save.y-28*scale-EDITOR_DETAIL_HEIGHT*scale, inner, EDITOR_DETAIL_HEIGHT*scale}
	list_top := l.filter.y+44*scale
	l.rows = max(0, int((l.detail.y-12*scale-list_top)/l.row_height))
	l.list = {x+pad, list_top, inner, f32(l.rows)*l.row_height}
	top := l.detail.y+80*scale
	l.value = {l.detail.x, top, inner, 36*scale}
	row := editor_row(p)
	if row == nil { return l }
	#partial switch row.kind {
	case .Integer, .Number:
		l.value.width = min(inner, 140*scale)
		track_x := l.value.x+l.value.width+20*scale
		l.slider = {track_x, top+12*scale, max(0, l.detail.x+inner-track_x-8*scale), 12*scale}
	case .Toggle:
		l.toggle = {l.detail.x, top+6*scale, 44*scale, 24*scale}
		l.value = {}
	case .Choice:
		for i in 0..<min(len(row.choices), len(l.choices)) {
			l.choices[i] = {l.detail.x+f32(i)*116*scale, top+2*scale, 110*scale, 32*scale}
		}
		l.value = {}
	case .Color, .Optional_Color:
		size := 112*scale
		l.wheel = {l.detail.x, l.detail.y+76*scale, size, size}
		side := l.wheel.x+size+20*scale
		l.ramp = {side, l.wheel.y+6*scale, min(260*scale, max(0, l.detail.x+inner-side)), 18*scale}
		l.swatch = {side, l.ramp.y+34*scale, 40*scale, 36*scale}
		field_x := side+52*scale
		l.value = {field_x, l.swatch.y, min(240*scale, max(0, l.detail.x+inner-field_x)), 36*scale}
		if row.kind == .Optional_Color {
			l.theme_default = {side, l.swatch.y+48*scale, 132*scale, 26*scale}
		}
	case .Shortcut:
		l.positions = {l.detail.x, top+50*scale, 36*scale, 20*scale}
	}
	return l
}

@(private)
editor_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height
}

@(private)
field_available :: proc(r: render.Rect, scale: f32) -> f32 {
	return max(1, r.width-20*scale)-4*scale
}

@(private)
field_offset :: proc(f: ^Text_Field, text: ^Text, r: render.Rect, x, scale: f32) -> int {
	input_text := text_styled(text, .Input)
	start := field_view_start(f, &input_text, field_available(r, scale))
	return field_offset_at(f, &input_text, start, r.x+10*scale, x)
}

@(private)
pick_color :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) {
	if p.drag == .Wheel {
		radius := l.wheel.width/2
		dx, dy := x-(l.wheel.x+radius), y-(l.wheel.y+radius)
		hue := math.to_degrees(math.atan2(dy, dx))
		if hue < 0 { hue += 360 }
		p.hsv[0], p.hsv[1] = hue, min(1, math.sqrt(dx*dx+dy*dy)/max(1, radius))
	} else {
		p.hsv[2] = clamp((x-l.ramp.x)/max(1, l.ramp.width), 0, 1)
	}
	field_set(&p.value, settings.color_hex(settings.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2])))
}

@(private)
slide :: proc(p: ^Editor, row: ^Editor_Row, l: Editor_Layout, x: f32) {
	field_set(&p.value, number_text(row, slider_value(row, (x-l.slider.x)/max(1, l.slider.width))))
}

// A press on the panel; `extend` (Shift) grows a text selection instead of moving the caret.
editor_press :: proc(p: ^Editor, l: Editor_Layout, text: ^Text, x, y, scale: f32,
	extend: bool) -> Editor_Outcome {
	row := editor_row(p)
	if editor_contains(l.close, x, y) { p.open = false; return .Closed }
	if editor_contains(l.save, x, y) { return row == nil ? .None : .Save }
	if editor_contains(l.reset, x, y) { return row == nil ? .None : .Reset }
	if editor_contains(l.filter, x, y) {
		stop_editing(p)
		p.button_focus = 0
		field_pointer(&p.filter, field_offset(&p.filter, text, l.filter, x, scale), true, extend)
		p.drag = .Filter
		return .Changed
	}
	if editor_contains(l.list, x, y) {
		i := p.scroll+int((y-l.list.y)/l.row_height)
		if i >= len(p.items) { return .None }
		p.button_focus = 0
		if p.items[i].row < 0 { editor_toggle_group(p, i); return .Changed }
		editor_select(p, i)
		p.editing = editor_row(p).kind != .Shortcut
		return .Changed
	}
	if row == nil { return .None }
	p.button_focus = 0
	if editor_contains(l.value, x, y) {
		if row.kind == .Shortcut { start_capture(p); return .Changed }
		p.editing, p.capturing = true, false
		field_pointer(&p.value, field_offset(&p.value, text, l.value, x, scale), true, extend)
		p.drag = .Value
		return .Changed
	}
	if p.capturing { stop_editing(p); editor_message(p, "", false) }
	if editor_contains(l.positions, x, y) {
		p.physical = !p.physical
		return .Changed
	}
	switch {
	case editor_contains(l.toggle, x, y):
		p.editing = true
		return flip_toggle(p)
	case editor_contains(l.theme_default, x, y):
		field_set(&p.value, "")
		return .Save
	case l.slider.width > 0 && editor_contains({l.slider.x-8*scale, l.slider.y-10*scale,
		l.slider.width+16*scale, l.slider.height+20*scale}, x, y):
		p.editing, p.drag = true, .Slider
		slide(p, row, l, x)
		return .Changed
	case editor_contains(l.wheel, x, y):
		p.editing, p.drag = true, .Wheel
		pick_color(p, l, x, y)
		return .Changed
	case l.ramp.width > 0 && editor_contains({l.ramp.x, l.ramp.y-6*scale, l.ramp.width, l.ramp.height+12*scale}, x, y):
		p.editing, p.drag = true, .Ramp
		pick_color(p, l, x, y)
		return .Changed
	}
	for choice, i in l.choices {
		if choice.width > 0 && editor_contains(choice, x, y) {
			p.editing = true
			if row.choices[i] == field_string(&p.value) { return .Changed }
			field_set(&p.value, row.choices[i])
			return .Save
		}
	}
	return .Changed
}

// Continues a pointer drag; returns whether anything changed.
editor_drag :: proc(p: ^Editor, l: Editor_Layout, text: ^Text, x, y, scale: f32) -> bool {
	row := editor_row(p)
	switch p.drag {
	case .None: return false
	case .Filter:
		return field_pointer(&p.filter, field_offset(&p.filter, text, l.filter, x, scale), false, true) != .None
	case .Value:
		return field_pointer(&p.value, field_offset(&p.value, text, l.value, x, scale), false, true) != .None
	case .Slider:
		if row == nil { return false }
		slide(p, row, l, x)
	case .Wheel, .Ramp:
		pick_color(p, l, x, y)
	}
	return true
}

// Ends a pointer drag; a slider or color drag saves the value it settled on.
editor_release :: proc(p: ^Editor) -> Editor_Outcome {
	drag := p.drag
	p.drag = .None
	p.filter.dragging, p.value.dragging = false, false
	row := editor_row(p)
	if row == nil || (drag != .Slider && drag != .Wheel && drag != .Ramp) { return .None }
	return field_string(&p.value) == row.value ? .Changed : .Save
}

@(private)
row_preview :: proc(row: Editor_Row) -> string {
	#partial switch row.kind {
	case .Toggle: return row.value == "true" ? "On" : "Off"
	case .Optional_Color: if row.value == "" { return "Theme default" }
	case .Shortcut: if row.value == "" { return "None" }
	}
	return row.value
}

@(private)
color_value :: proc(c: settings.Color) -> render.Color {
	return {f32(c.r)/255, f32(c.g)/255, f32(c.b)/255, 1}
}

@(private)
icon_box_draw :: proc(list: ^render.Draw_List, r: render.Rect, color: render.Color, expanded: bool, scale: f32) {
	draw_rect(list, {rect = r, color = color, radius = 3*scale, stroke = scale})
	bar := math.round(max(1, scale))
	cx, cy := math.round(r.x+r.width/2-bar/2), math.round(r.y+r.height/2-bar/2)
	draw_rect(list, {rect = {r.x+3*scale, cy, r.width-6*scale, bar}, color = color})
	if !expanded { draw_rect(list, {rect = {cx, r.y+3*scale, bar, r.height-6*scale}, color = color}) }
}

editor_draw :: proc(p: ^Editor, list: ^render.Draw_List, text: ^Text, theme: Theme,
	width, height, scale: f32) -> glyphs.Result {
	l := editor_layout(p, width, height, scale)
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
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Small)
	if r := draw_text(&strong, list, "Settings", x, y, theme.text); r != .Ok { return r }
	matches := 0
	for item in p.items { matches += item.count }
	count := fmt.tprintf("%d results", matches)
	if r := draw_text(text, list, count, x+110*scale, y, theme.muted,
		max(1, l.panel.width-140*scale)); r != .Ok { return r }
	if r := editor_field_draw(&p.filter, list, text, theme, l.filter, !p.editing && p.button_focus == 0,
		"Search settings, groups, and shortcuts", scale); r != .Ok { return r }
	for index in p.scroll..<min(len(p.items), p.scroll+l.rows) {
		item := p.items[index]
		r := render.Rect{l.list.x, l.list.y+f32(index-p.scroll)*l.row_height, l.list.width, l.row_height}
		if index == p.selected { draw_rect(list, {rect = r, color = theme.selection, radius = 6*scale}) }
		baseline := r.y+(r.height-text.line_height)/2+text.ascent
		if item.row < 0 {
			icon_box_draw(list, {r.x+8*scale, r.y+(r.height-11*scale)/2, 11*scale, 11*scale}, theme.muted,
				!group_collapsed(p, item.group)^, scale)
			if result := draw_text(&strong, list, p.groups[item.group].title, r.x+28*scale, baseline,
				theme.text, max(1, r.width*0.7)); result != .Ok { return result }
			label := fmt.tprintf("%d", item.count)
			if result := draw_text(&small, list, label, r.x+r.width-8*scale-text_width(&small, label),
				baseline, theme.faint); result != .Ok { return result }
			continue
		}
		row := p.rows[item.row]
		if result := draw_text(text, list, row.title, r.x+28*scale, baseline, theme.text,
			max(1, r.width*0.55-28*scale)); result != .Ok { return result }
		preview_x := r.x+r.width*0.58
		if c, ok, _ := settings.parse_color(color_or_fallback(&row, row.value));
		   ok && (row.kind == .Color || row.kind == .Optional_Color) {
			chip := render.Rect{preview_x, r.y+(r.height-14*scale)/2, 14*scale, 14*scale}
			draw_rect(list, {rect = chip, color = color_value(c), radius = 3*scale})
			draw_rect(list, {rect = chip, color = theme.border, radius = 3*scale, stroke = scale})
			preview_x += 22*scale
		}
		if result := draw_text(text, list, row_preview(row), preview_x, baseline, theme.muted,
			max(1, r.x+r.width-8*scale-preview_x)); result != .Ok { return result }
	}
	if result := editor_detail_draw(p, l, list, text, theme, scale); result != .Ok { return result }
	status := p.message
	if status == "" { status = "Tab: move focus   Up/Down or Ctrl+N/P: select   Enter: edit or expand   Esc: close" }
	if r := draw_text(&small, list, status, x, l.save.y-12*scale, p.error ? theme.error : theme.muted,
		max(1, l.detail.width)); r != .Ok { return r }
	for rect, i in ([?]render.Rect{l.save, l.reset, l.close}) {
		disabled := i < 2 && editor_row(p) == nil
		layers, rect_start, glyph_start := len(list.layers), len(list.rects), len(list.glyphs)
		label_text := text_styled(text, i == 0 ? .Strong : .Body)
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
		if r := draw_text(&label_text, list, labels[i], rect.x+10*scale,
			rect.y+(rect.height-text.line_height)/2+text.ascent, i == 0 ? theme.accent_text : theme.text,
			max(1, rect.width-20*scale)); r != .Ok { return r }
		if disabled { fade_draw(list, layers, rect_start, glyph_start, 0.45, 0) }
	}
	return .Ok
}

@(private)
editor_detail_draw :: proc(p: ^Editor, l: Editor_Layout, list: ^render.Draw_List, text: ^Text,
	theme: Theme, scale: f32) -> glyphs.Result {
	draw_rect(list, {rect = {l.detail.x, l.detail.y-6*scale, l.detail.width, scale}, color = theme.border})
	row := editor_row(p)
	x := l.detail.x
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Small)
	if row == nil {
		return draw_text(text, list, "Select a setting to edit it. Enter or a click expands a group.", x,
			l.detail.y+22*scale, theme.muted, max(1, l.detail.width))
	}
	if r := draw_text(&strong, list, row.title, x, l.detail.y+22*scale, theme.text,
		max(1, l.detail.width*0.6)); r != .Ok { return r }
	key_x := x+min(l.detail.width*0.6, text_width(&strong, row.title))+10*scale
	if r := draw_text(&small, list, row.key, key_x, l.detail.y+22*scale, theme.accent,
		max(1, l.detail.x+l.detail.width-key_x)); r != .Ok { return r }
	lines := make([dynamic]string, context.temp_allocator)
	wrap(&small, row.description, max(1, l.detail.width), &lines)
	for line, i in lines[:min(2, len(lines))] {
		if r := draw_text(&small, list, line, x, l.detail.y+44*scale+f32(i)*small.line_height, theme.muted,
			max(1, l.detail.width)); r != .Ok { return r }
	}
	value := field_string(&p.value)
	focused := p.editing && p.button_focus == 0
	switch row.kind {
	case .Text, .Integer, .Number:
		if r := editor_field_draw(&p.value, list, text, theme, l.value, focused, "Empty value", scale);
			r != .Ok { return r }
	case .Color, .Optional_Color:
		placeholder := "Paste hex, rgb(), or hsl()"
		if row.kind == .Optional_Color {
			placeholder = row.fallback == "" ? "Theme default" : fmt.tprintf("Theme default %s", row.fallback)
		}
		if r := editor_field_draw(&p.value, list, text, theme, l.value, focused, placeholder, scale);
			r != .Ok { return r }
		if r := color_picker_draw(p, row, l, list, text, theme, scale); r != .Ok {
			return r
		}
	case .Shortcut:
		placeholder := p.capturing ? "Press keys…" : "None; press Enter to record keys"
		if r := editor_field_draw(&p.value, list, text, theme, l.value, focused && !p.capturing, placeholder,
			scale); r != .Ok { return r }
		if p.capturing { draw_rect(list, {rect = l.value, color = theme.accent, radius = 6*scale, stroke = 2*scale}) }
		if r := switch_draw(list, text, theme, l.positions, p.physical, p.button_focus == 4,
			"Record key positions (Physical+)", scale); r != .Ok { return r }
	case .Toggle:
		on := value == "true"
		if r := switch_draw(list, text, theme, l.toggle, on, focused, on ? "On" : "Off", scale); r != .Ok { return r }
	case .Choice:
		for choice, i in l.choices {
			if choice.width == 0 { continue }
			chosen := row.choices[i] == value
			draw_rect(list, {rect = choice, color = chosen ? theme.accent : theme.surface, radius = 6*scale})
			if !chosen { draw_rect(list, {rect = choice, color = theme.border, radius = 6*scale, stroke = scale}) }
			if focused && chosen { focus_ring_draw(list, choice, theme, scale) }
			label_text := text_styled(text, chosen ? .Strong : .Body)
			label := row.choices[i]
			if r := draw_text(&label_text, list, label, choice.x+(choice.width-text_width(&label_text, label))/2,
				choice.y+(choice.height-text.line_height)/2+text.ascent, chosen ? theme.accent_text : theme.text,
				max(1, choice.width-8*scale)); r != .Ok { return r }
		}
	}
	if row.kind == .Integer || row.kind == .Number {
		track := l.slider
		number, ok := strconv.parse_f64(value)
		if !ok { number, _ = strconv.parse_f64(row.value) }
		fraction := slider_fraction(row, number)
		groove := render.Rect{track.x, track.y+4*scale, track.width, 4*scale}
		draw_rect(list, {rect = groove, color = theme.border, radius = 2*scale})
		groove.width *= fraction
		draw_rect(list, {rect = groove, color = theme.accent, radius = 2*scale})
		thumb := render.Rect{track.x+track.width*fraction-8*scale, track.y-2*scale, 16*scale, 16*scale}
		draw_rect(list, {rect = thumb, color = theme.accent, radius = 8*scale})
		draw_rect(list, {rect = thumb, color = theme.surface, radius = 8*scale, stroke = 2*scale})
		limits := fmt.tprintf("%s to %s", number_text(row, row.minimum), number_text(row, row.maximum))
		if r := draw_text(&small, list, limits, track.x, track.y+track.height+20*scale, theme.faint,
			max(1, track.width)); r != .Ok { return r }
	}
	return .Ok
}

@(private)
switch_draw :: proc(list: ^render.Draw_List, text: ^Text, theme: Theme, track: render.Rect, on, focused: bool,
	label: string, scale: f32) -> glyphs.Result {
	draw_rect(list, {rect = track, color = on ? theme.accent : theme.border, radius = track.height/2})
	knob := track.height-6*scale
	knob_x := on ? track.x+track.width-3*scale-knob : track.x+3*scale
	draw_rect(list, {rect = {knob_x, track.y+3*scale, knob, knob}, color = on ? theme.accent_text : theme.text,
		radius = knob/2})
	if focused { focus_ring_draw(list, track, theme, scale) }
	return draw_text(text, list, label, track.x+track.width+12*scale,
		track.y+(track.height-text.line_height)/2+text.ascent, theme.text)
}

@(private)
color_picker_draw :: proc(p: ^Editor, row: ^Editor_Row, l: Editor_Layout, list: ^render.Draw_List, text: ^Text,
	theme: Theme, scale: f32) -> glyphs.Result {
	wheel := l.wheel
	draw_rect(list, {rect = wheel, color = {p.hsv[2], 0, 0, 1}, radius = wheel.width/2,
		fill = render.RECT_FILL_HUE_WHEEL})
	draw_rect(list, {rect = wheel, color = theme.border, radius = wheel.width/2, stroke = scale})
	angle := math.to_radians(p.hsv[0])
	reach := wheel.width/2*p.hsv[1]
	mx := wheel.x+wheel.width/2+math.cos(angle)*reach
	my := wheel.y+wheel.height/2+math.sin(angle)*reach
	draw_rect(list, {rect = {mx-7*scale, my-7*scale, 14*scale, 14*scale}, color = {0, 0, 0, 0.6},
		radius = 7*scale, stroke = scale})
	draw_rect(list, {rect = {mx-6*scale, my-6*scale, 12*scale, 12*scale}, color = {1, 1, 1, 1},
		radius = 6*scale, stroke = 2*scale})
	full := color_value(settings.hsv_to_rgb(p.hsv[0], p.hsv[1], 1))
	draw_rect(list, {rect = l.ramp, color = full, radius = 4*scale, fill = render.RECT_FILL_VALUE_RAMP})
	draw_rect(list, {rect = l.ramp, color = theme.border, radius = 4*scale, stroke = scale})
	marker := l.ramp.x+l.ramp.width*p.hsv[2]
	draw_rect(list, {rect = {marker-3*scale, l.ramp.y-3*scale, 6*scale, l.ramp.height+6*scale},
		color = {1, 1, 1, 1}, radius = 3*scale, stroke = 2*scale})
	if c, ok, _ := settings.parse_color(color_or_fallback(row, field_string(&p.value))); ok {
		draw_rect(list, {rect = l.swatch, color = color_value(c), radius = 6*scale})
	}
	draw_rect(list, {rect = l.swatch, color = theme.border, radius = 6*scale, stroke = scale})
	if row.kind != .Optional_Color { return .Ok }
	b := l.theme_default
	draw_rect(list, {rect = b, color = theme.border, radius = 6*scale, stroke = scale})
	return draw_text(text, list, "Use theme default", b.x+10*scale, b.y+(b.height-text.line_height)/2+text.ascent,
		theme.text, max(1, b.width-20*scale))
}

@(private)
editor_field_draw :: proc(f: ^Text_Field, list: ^render.Draw_List, base: ^Text, theme: Theme,
	r: render.Rect, focused: bool, placeholder: string, scale: f32) -> glyphs.Result {
	input_text := text_styled(base, .Input)
	draw_rect(list, {rect = r, color = theme.border, radius = 6*scale})
	if focused { focus_ring_draw(list, r, theme, scale) }
	baseline := r.y+(r.height-input_text.line_height)/2+input_text.ascent
	return field_draw(f, list, &input_text, theme, r.x+10*scale, baseline, field_available(r, scale),
		focused, placeholder, theme.text, scale)
}

editor_pointer :: proc(p: ^Editor, l: Editor_Layout, x, y: f32, pressed: bool) -> bool {
	previous_hover, previous_press := p.hover, p.pressed
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
