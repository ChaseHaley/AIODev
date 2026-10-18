package ui

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
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

// Keyboard focus: the search field, the selected row's control, or its key-position switch.
Editor_Focus :: enum { Search, Control, Positions }

Editor_Popup :: enum { None, Choice, Color }

// The settings page shown in a settings tab. Only the selected row is edited; its pending value lives
// in `value` until it is saved.
Editor :: struct {
	open, capturing, leader_pending: bool,
	// Captured shortcuts name physical key positions (Physical+) instead of layout characters.
	physical: bool,
	focus: Editor_Focus,
	popup: Editor_Popup,
	popup_index, hover_item, hover_reset: int,
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
Editor_Outcome :: enum { None, Changed, Save, Reset }

Editor_Layout :: struct {
	page, filter, list: render.Rect,
	row_height, scale: f32,
	rows: int,
}

// The parts of one setting row; zero-sized parts do not exist for its kind.
Row_Parts :: struct {
	row, reset, field, toggle, slider, swatch, positions: render.Rect,
	text_right: f32,
}

CAPTURE_HINT :: "Press a shortcut. Enter saves, Esc cancels, Backspace clears, Tab leaves."
@(private) ROW_HEIGHT :: 52
@(private) CHOICE_HEIGHT :: 30
@(private) ICON_UNDO :: ''
@(private) ICON_CHEVRON_DOWN :: ''

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

editor_editing :: proc(p: ^Editor) -> bool { return p.focus == .Control }

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

// Leaves the selected row's control, discarding an unsaved value.
@(private)
stop_editing :: proc(p: ^Editor) {
	p.focus, p.capturing, p.leader_pending, p.captured = .Search, false, false, 0
	p.drag, p.popup = .None, .None
	if row := editor_row(p); row != nil {
		field_set(&p.value, row.value)
		sync_color(p)
	}
}

editor_select :: proc(p: ^Editor, index: int) {
	p.selected = clamp(index, 0, max(0, len(p.items)-1))
	p.capturing, p.leader_pending, p.captured, p.drag, p.popup = false, false, 0, .None, .None
	row := editor_row(p)
	if row != nil {
		field_set(&p.value, row.value)
		p.hsv = {0, 0, 1}
		sync_color(p)
	}
	if row == nil || row.kind == .Shortcut || p.focus == .Positions { p.focus = .Search }
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

// Scrolls the list without moving the selection.
editor_scroll :: proc(p: ^Editor, rows: int) {
	p.scroll = clamp(p.scroll-rows, 0, max(0, len(p.items)-max(1, p.visible_rows)))
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
choice_index :: proc(row: ^Editor_Row, value: string) -> int {
	for name, i in row.choices { if name == value { return i } }
	return 0
}

@(private)
choose :: proc(p: ^Editor, row: ^Editor_Row, index: int) -> Editor_Outcome {
	if len(row.choices) == 0 { return .None }
	next := clamp(index, 0, len(row.choices)-1)
	p.popup = .None
	if row.choices[next] == field_string(&p.value) { return .Changed }
	field_set(&p.value, row.choices[next])
	return .Save
}

@(private)
open_choices :: proc(p: ^Editor, row: ^Editor_Row) {
	p.popup, p.focus = .Choice, .Control
	p.popup_index = choice_index(row, field_string(&p.value))
}

@(private)
start_capture :: proc(p: ^Editor) {
	p.focus, p.capturing, p.leader_pending, p.captured, p.popup = .Control, true, false, 0, .None
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
			p.capturing, p.focus = false, .Positions
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

// Activates the selected row from the keyboard: toggles flip, lists open, fields take the keyboard.
@(private)
activate :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	switch row.kind {
	case .Toggle:
		p.focus = .Control
		return flip_toggle(p)
	case .Choice: open_choices(p, row)
	case .Shortcut: start_capture(p)
	case .Color, .Optional_Color:
		p.focus, p.popup = .Control, .Color
		field_select_all(&p.value)
	case .Text, .Integer, .Number:
		p.focus = .Control
		field_select_all(&p.value)
	}
	return .Changed
}

@(private)
popup_key :: proc(p: ^Editor, row: ^Editor_Row, e: platform.Key_Event) -> (Editor_Outcome, bool) {
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	#partial switch e.key {
	case .Escape:
		p.popup = .None
		return .Changed, true
	case .Arrow_Up, .Arrow_Down, .P, .N:
		if p.popup != .Choice || ((e.key == .P || e.key == .N) && !control) { return .None, false }
		delta := e.key == .Arrow_Up || e.key == .P ? -1 : 1
		p.popup_index = clamp(p.popup_index+delta, 0, len(row.choices)-1)
		return .Changed, true
	case .Enter, .Numpad_Enter, .Space:
		if p.popup == .Choice { return choose(p, row, p.popup_index), true }
		if e.key == .Space { return .None, false }
		p.popup = .None
		return .Save, true
	}
	return .None, p.popup == .Choice
}

// Takes the raw key event: capture needs the physical key, and navigation uses the layout's key.
editor_key :: proc(p: ^Editor, raw: platform.Key_Event) -> Editor_Outcome {
	if !raw.pressed { return .None }
	row := editor_row(p)
	if p.capturing && row != nil { return capture_key(p, row, raw) }
	e := raw
	e.key = commands.logical_key(raw.key, raw.unshifted)
	if p.popup != .None && row != nil {
		if outcome, handled := popup_key(p, row, e); handled { return outcome }
	}
	control := .Control in e.modifiers && .Alt not_in e.modifiers
	#partial switch e.key {
	case .Escape:
		if p.focus != .Search {
			stop_editing(p)
			return .Changed
		}
		if len(p.filter.bytes) == 0 { return .None }
		field_set(&p.filter, "")
		editor_filter(p)
		return .Changed
	case .Tab:
		stops := row != nil && row.kind == .Shortcut ? 3 : 2
		if row == nil { stops = 1 }
		focus := (int(p.focus)+(.Shift in e.modifiers ? stops-1 : 1))%stops
		p.popup = .None
		if Editor_Focus(focus) == .Control && row != nil { return activate(p, row) }
		if p.focus == .Control { stop_editing(p) }
		p.focus = Editor_Focus(focus)
		return .Changed
	case .Arrow_Up: editor_select(p, p.selected-1); return .Changed
	case .Arrow_Down: editor_select(p, p.selected+1); return .Changed
	case .P, .N:
		if control {
			editor_select(p, p.selected+(e.key == .N ? 1 : -1))
			return .Changed
		}
	case .Page_Up: editor_select(p, p.selected-max(1, p.visible_rows)); return .Changed
	case .Page_Down: editor_select(p, p.selected+max(1, p.visible_rows)); return .Changed
	case .Enter, .Numpad_Enter:
		if row == nil { editor_toggle_group(p, p.selected); return .Changed }
		if p.focus == .Positions { p.physical = !p.physical; return .Changed }
		if p.focus == .Control && text_kind(row.kind) {
			p.popup = .None
			return .Save
		}
		return activate(p, row)
	case .Space:
		if p.focus == .Positions { p.physical = !p.physical; return .Changed }
		if p.focus == .Control && row != nil && row.kind == .Toggle { return flip_toggle(p) }
	case .Arrow_Left, .Arrow_Right:
		left := e.key == .Arrow_Left
		if p.focus == .Control && row != nil && row.kind == .Choice {
			return choose(p, row, choice_index(row, field_string(&p.value))+(left ? -1 : 1))
		}
		if p.focus == .Search && row == nil && len(p.filter.bytes) == 0 && len(p.items) > 0 {
			if group_collapsed(p, p.items[p.selected].group)^ != left { editor_toggle_group(p, p.selected) }
			return .Changed
		}
	case .R:
		if control { return row == nil ? .None : .Reset }
	}
	switch p.focus {
	case .Positions: return .None
	case .Control:
		if row != nil && text_kind(row.kind) {
			if field_key(&p.value, e) == .Edited { sync_color(p) }
			return .Changed
		}
		p.focus, p.popup = .Search, .None
	case .Search:
	}
	if field_key(&p.filter, e) == .Edited { editor_filter(p) }
	return .Changed
}

editor_text :: proc(p: ^Editor, text: string) {
	if p.capturing || p.focus == .Positions { return }
	row := editor_row(p)
	if p.focus == .Control && row != nil && text_kind(row.kind) {
		if field_text(&p.value, text) == .Edited { sync_color(p) }
		return
	}
	p.focus, p.popup = .Search, .None
	if field_text(&p.filter, text) == .Edited {
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
	switch p.focus {
	case .Search: return field_selected_text(&p.filter)
	case .Control: if !p.capturing { return field_selected_text(&p.value) }
	case .Positions:
	}
	return ""
}

// Removes the selected text of the focused field after it was copied.
editor_cut :: proc(p: ^Editor) {
	if editor_selection(p) == "" { return }
	if p.focus == .Control {
		if row := editor_row(p); row != nil && text_kind(row.kind) {
			field_text(&p.value, "")
			sync_color(p)
		}
	} else {
		field_text(&p.filter, "")
		editor_filter(p)
	}
}

// Lays the page out inside a settings tab's card.
editor_layout :: proc(area: render.Rect, scale: f32) -> Editor_Layout {
	pad := 24*scale
	width := max(0, min(960*scale, area.width-2*pad))
	x := area.x+max(pad, (area.width-width)/2)
	l := Editor_Layout{page = area, row_height = ROW_HEIGHT*scale, scale = scale}
	l.filter = {x, area.y+52*scale, width, 34*scale}
	top := l.filter.y+l.filter.height+12*scale
	l.rows = max(0, int((area.y+area.height-pad/2-top)/l.row_height))
	l.list = {x, top, width, f32(l.rows)*l.row_height}
	return l
}

editor_row_parts :: proc(p: ^Editor, l: Editor_Layout, index: int) -> Row_Parts {
	s := l.scale
	r := render.Rect{l.list.x, l.list.y+f32(index-p.scroll)*l.row_height, l.list.width, l.row_height}
	parts := Row_Parts{row = r}
	item := p.items[index]
	cy := r.y+r.height/2
	parts.reset = {r.x+r.width-34*s, cy-13*s, 26*s, 26*s}
	right := parts.reset.x-12*s
	parts.text_right = right
	if item.row < 0 { return parts }
	row := p.rows[item.row]
	field := proc(right, cy, width, s: f32) -> render.Rect { return {right-width*s, cy-15*s, width*s, 30*s} }
	switch row.kind {
	case .Toggle:
		parts.toggle = {right-44*s, cy-11*s, 44*s, 22*s}
		parts.text_right = parts.toggle.x-48*s
	case .Choice:
		parts.field = field(right, cy, 180, s)
	case .Integer, .Number:
		parts.field = field(right, cy, 90, s)
		parts.slider = {parts.field.x-176*s, cy-6*s, 160*s, 12*s}
		parts.text_right = parts.slider.x-12*s
	case .Text:
		parts.field = field(right, cy, min(360, r.width/s*0.42), s)
	case .Color, .Optional_Color:
		parts.field = field(right, cy, 120, s)
		parts.swatch = {parts.field.x-38*s, cy-15*s, 30*s, 30*s}
		parts.text_right = parts.swatch.x-12*s
	case .Shortcut:
		parts.field = field(right, cy, 240, s)
		if index == p.selected { parts.positions = {parts.field.x-178*s, cy-11*s, 36*s, 22*s} }
	}
	if parts.field.width > 0 && parts.text_right > parts.field.x { parts.text_right = parts.field.x }
	parts.text_right -= 16*s
	return parts
}

// The open dropdown or color picker for the selected row, flipped above it when there is no room below.
editor_popup_rect :: proc(p: ^Editor, l: Editor_Layout) -> render.Rect {
	row := editor_row(p)
	if p.popup == .None || row == nil || p.selected < p.scroll || p.selected >= p.scroll+l.rows {
		return {}
	}
	parts := editor_row_parts(p, l, p.selected)
	s := l.scale
	r: render.Rect
	if p.popup == .Choice {
		r = {parts.field.x, parts.field.y+parts.field.height+4*s, parts.field.width,
			f32(len(row.choices))*CHOICE_HEIGHT*s+8*s}
	} else {
		r = {parts.field.x+parts.field.width-292*s, parts.field.y+parts.field.height+6*s, 292*s,
			(row.kind == .Optional_Color ? 206 : 166)*s}
	}
	if r.y+r.height > l.page.y+l.page.height-8*s { r.y = parts.row.y-r.height-4*s }
	return r
}

@(private)
Color_Parts :: struct { wheel, ramp, swatch, theme_default: render.Rect }

@(private)
color_parts :: proc(popup: render.Rect, optional: bool, scale: f32) -> Color_Parts {
	s := scale
	c := Color_Parts{wheel = {popup.x+12*s, popup.y+12*s, 140*s, 140*s}}
	c.ramp = {popup.x+168*s, popup.y+24*s, 112*s, 16*s}
	c.swatch = {popup.x+168*s, popup.y+60*s, 112*s, 40*s}
	if optional { c.theme_default = {popup.x+12*s, popup.y+166*s, 140*s, 28*s} }
	return c
}

@(private)
contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return r.width > 0 && x >= r.x && x < r.x+r.width && y >= r.y && y < r.y+r.height
}

@(private)
field_available :: proc(r: render.Rect, scale: f32) -> f32 {
	return max(1, r.width-20*scale)
}

@(private)
field_offset :: proc(f: ^Text_Field, text: ^Text, r: render.Rect, x, scale: f32) -> int {
	start := field_view_start(f, text, field_available(r, scale))
	return field_offset_at(f, text, start, r.x+10*scale, x)
}

@(private)
pick_color :: proc(p: ^Editor, c: Color_Parts, x, y: f32) {
	if p.drag == .Wheel {
		radius := c.wheel.width/2
		dx, dy := x-(c.wheel.x+radius), y-(c.wheel.y+radius)
		hue := math.to_degrees(math.atan2(dy, dx))
		if hue < 0 { hue += 360 }
		p.hsv[0], p.hsv[1] = hue, min(1, math.sqrt(dx*dx+dy*dy)/max(1, radius))
	} else {
		p.hsv[2] = clamp((x-c.ramp.x)/max(1, c.ramp.width), 0, 1)
	}
	field_set(&p.value, settings.color_hex(settings.hsv_to_rgb(p.hsv[0], p.hsv[1], p.hsv[2])))
}

@(private)
slide :: proc(p: ^Editor, row: ^Editor_Row, slider: render.Rect, x: f32) {
	field_set(&p.value, number_text(row, slider_value(row, (x-slider.x)/max(1, slider.width))))
}

// A press inside the page; `extend` (Shift) grows a text selection instead of moving the caret.
editor_press :: proc(p: ^Editor, l: Editor_Layout, text: ^Text, x, y: f32, extend: bool) -> Editor_Outcome {
	s := l.scale
	if p.popup != .None {
		popup := editor_popup_rect(p, l)
		row := editor_row(p)
		if !contains(popup, x, y) || row == nil {
			p.popup = .None
			return .Changed
		}
		if p.popup == .Choice {
			return choose(p, row, int((y-popup.y-4*s)/(CHOICE_HEIGHT*s)))
		}
		c := color_parts(popup, row.kind == .Optional_Color, s)
		switch {
		case contains(c.wheel, x, y): p.drag = .Wheel
		case contains({c.ramp.x, c.ramp.y-6*s, c.ramp.width, c.ramp.height+12*s}, x, y): p.drag = .Ramp
		case contains(c.theme_default, x, y):
			field_set(&p.value, "")
			p.popup = .None
			return .Save
		case: return .None
		}
		pick_color(p, c, x, y)
		return .Changed
	}
	if contains(l.filter, x, y) {
		if p.focus != .Search { stop_editing(p) }
		input_text := text_styled(text, .Input)
		field_pointer(&p.filter, field_offset(&p.filter, &input_text, l.filter, x, s), true, extend)
		p.drag = .Filter
		return .Changed
	}
	if !contains(l.list, x, y) { return .None }
	index := p.scroll+int((y-l.list.y)/l.row_height)
	if index >= len(p.items) { return .None }
	if p.items[index].row < 0 { editor_toggle_group(p, index); return .Changed }
	if index != p.selected { editor_select(p, index) }
	row := editor_row(p)
	parts := editor_row_parts(p, l, index)
	switch {
	case contains(parts.reset, x, y): return .Reset
	case contains(parts.toggle, x, y):
		p.focus = .Control
		return flip_toggle(p)
	case contains(parts.positions, x, y):
		p.physical = !p.physical
		return .Changed
	case contains(parts.swatch, x, y):
		p.focus, p.popup = .Control, .Color
		return .Changed
	case contains(parts.slider, x, y) || contains({parts.slider.x-8*s, parts.slider.y-10*s,
		parts.slider.width+16*s, parts.slider.height+20*s}, x, y) && parts.slider.width > 0:
		p.focus, p.drag = .Control, .Slider
		slide(p, row, parts.slider, x)
		return .Changed
	case contains(parts.field, x, y):
		#partial switch row.kind {
		case .Choice:
			if p.popup == .Choice { p.popup = .None } else { open_choices(p, row) }
			return .Changed
		case .Shortcut:
			start_capture(p)
			return .Changed
		}
		if p.capturing { stop_editing(p) }
		p.focus = .Control
		input_text := text_styled(text, .Input)
		field_pointer(&p.value, field_offset(&p.value, &input_text, parts.field, x, s), true, extend)
		p.drag = .Value
		return .Changed
	}
	if p.capturing {
		stop_editing(p)
		editor_message(p, "", false)
	}
	return .Changed
}

// Continues a pointer drag; returns whether anything changed.
editor_drag :: proc(p: ^Editor, l: Editor_Layout, text: ^Text, x, y: f32) -> bool {
	row := editor_row(p)
	if row == nil && p.drag != .Filter { return false }
	switch p.drag {
	case .None: return false
	case .Filter:
		input_text := text_styled(text, .Input)
		return field_pointer(&p.filter, field_offset(&p.filter, &input_text, l.filter, x, l.scale), false, true) != .None
	case .Value:
		input_text := text_styled(text, .Input)
		parts := editor_row_parts(p, l, p.selected)
		return field_pointer(&p.value, field_offset(&p.value, &input_text, parts.field, x, l.scale), false, true) != .None
	case .Slider:
		slide(p, row, editor_row_parts(p, l, p.selected).slider, x)
	case .Wheel, .Ramp:
		pick_color(p, color_parts(editor_popup_rect(p, l), row.kind == .Optional_Color, l.scale), x, y)
	}
	return true
}

// Ends a pointer drag; a slider drag saves the value it settled on and a color drag previews until
// the picker closes or Enter saves.
editor_release :: proc(p: ^Editor) -> Editor_Outcome {
	drag := p.drag
	p.drag = .None
	p.filter.dragging, p.value.dragging = false, false
	row := editor_row(p)
	if row == nil || (drag != .Slider && drag != .Wheel && drag != .Ramp) { return .None }
	return field_string(&p.value) == row.value ? .Changed : .Save
}

// Hover state for row highlights and reset buttons; returns whether the page must redraw.
editor_hover :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	item, reset := -1, -1
	if p.popup == .None && contains(l.list, x, y) {
		index := p.scroll+int((y-l.list.y)/l.row_height)
		if index < len(p.items) {
			item = index
			if contains(editor_row_parts(p, l, index).reset, x, y) { reset = index }
		}
	}
	if item == p.hover_item && reset == p.hover_reset { return false }
	p.hover_item, p.hover_reset = item, reset
	return true
}

// Whether the pointer is over editable text, which shows a text cursor.
editor_over_text :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	if contains(editor_popup_rect(p, l), x, y) { return false }
	if contains(l.filter, x, y) { return true }
	if !contains(l.list, x, y) { return false }
	index := p.scroll+int((y-l.list.y)/l.row_height)
	if index >= len(p.items) || p.items[index].row < 0 { return false }
	kind := p.rows[p.items[index].row].kind
	return text_kind(kind) && contains(editor_row_parts(p, l, index).field, x, y)
}

@(private)
row_preview :: proc(row: ^Editor_Row, value: string) -> string {
	#partial switch row.kind {
	case .Optional_Color: if value == "" { return "Theme default" }
	case .Shortcut: if value == "" { return "None" }
	}
	return value
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

@(private)
switch_draw :: proc(list: ^render.Draw_List, track: render.Rect, on, focused: bool, theme: Theme, scale: f32) {
	draw_rect(list, {rect = track, color = on ? theme.accent : theme.border, radius = track.height/2})
	knob := track.height-6*scale
	knob_x := on ? track.x+track.width-3*scale-knob : track.x+3*scale
	draw_rect(list, {rect = {knob_x, track.y+3*scale, knob, knob}, color = on ? theme.accent_text : theme.text,
		radius = knob/2})
	if focused { focus_ring_draw(list, track, theme, scale) }
}

@(private)
box_draw :: proc(list: ^render.Draw_List, r: render.Rect, theme: Theme, focused: bool, scale: f32) {
	draw_rect(list, {rect = r, color = theme.border, radius = 6*scale})
	if focused { focus_ring_draw(list, r, theme, scale) }
}

@(private)
field_box_draw :: proc(f: ^Text_Field, list: ^render.Draw_List, base: ^Text, theme: Theme,
	r: render.Rect, focused: bool, placeholder: string, scale: f32) -> glyphs.Result {
	input_text := text_styled(base, .Input)
	box_draw(list, r, theme, focused, scale)
	if render.push_layer(list, r, 6*scale) != .None { return .Ok }
	baseline := r.y+(r.height-input_text.line_height)/2+input_text.ascent
	return field_draw(f, list, &input_text, theme, r.x+10*scale, baseline, field_available(r, scale),
		focused, placeholder, theme.text, scale)
}

// Draws a control's resting value, or for the selected row its pending value and focus.
@(private)
control_draw :: proc(p: ^Editor, row: ^Editor_Row, parts: Row_Parts, selected: bool, list: ^render.Draw_List,
	text: ^Text, theme: Theme, page: render.Rect, scale: f32) -> glyphs.Result {
	value := selected ? field_string(&p.value) : row.value
	focused := selected && p.focus == .Control
	input_text := text_styled(text, .Input)
	baseline := parts.field.y+(parts.field.height-input_text.line_height)/2+input_text.ascent
	switch row.kind {
	case .Toggle:
		on := value == "true"
		switch_draw(list, parts.toggle, on, focused, theme, scale)
		label := on ? "On" : "Off"
		return draw_text(text, list, label, parts.toggle.x-12*scale-text_width(text, label),
			parts.toggle.y+(parts.toggle.height-text.line_height)/2+text.ascent, theme.muted)
	case .Choice:
		box_draw(list, parts.field, theme, focused, scale)
		if r := draw_text(&input_text, list, value, parts.field.x+10*scale, baseline, theme.text,
			max(1, parts.field.width-40*scale)); r != .Ok { return r }
		chevron := render.Rect{parts.field.x+parts.field.width-30*scale, parts.field.y, 24*scale, parts.field.height}
		return draw_icon(text, list, ICON_CHEVRON_DOWN, chevron, theme.muted, 0.8)
	case .Integer, .Number:
		number, ok := strconv.parse_f64(value)
		if !ok { number, _ = strconv.parse_f64(row.value) }
		fraction := slider_fraction(row, number)
		track := parts.slider
		groove := render.Rect{track.x, track.y+4*scale, track.width, 4*scale}
		draw_rect(list, {rect = groove, color = theme.border, radius = 2*scale})
		groove.width *= fraction
		draw_rect(list, {rect = groove, color = theme.accent, radius = 2*scale})
		thumb := render.Rect{track.x+track.width*fraction-7*scale, track.y-1*scale, 14*scale, 14*scale}
		draw_rect(list, {rect = thumb, color = theme.accent, radius = 7*scale})
		draw_rect(list, {rect = thumb, color = theme.surface, radius = 7*scale, stroke = 2*scale})
	case .Color, .Optional_Color:
		shown := color_or_fallback(row, value)
		if c, ok, _ := settings.parse_color(shown); ok {
			draw_rect(list, {rect = parts.swatch, color = color_value(c), radius = 6*scale})
		}
		draw_rect(list, {rect = parts.swatch, color = theme.border, radius = 6*scale, stroke = scale})
		if selected && p.popup == .Color { focus_ring_draw(list, parts.swatch, theme, scale) }
	case .Text, .Shortcut:
	}
	if selected {
		placeholder := row.kind == .Optional_Color ? "Theme default" : "Empty"
		if row.kind == .Shortcut { placeholder = p.capturing ? "Press keys…" : "None" }
		if r := field_box_draw(&p.value, list, text, theme, parts.field, focused && !p.capturing, placeholder,
			scale); r != .Ok { return r }
		if p.capturing {
			draw_rect(list, {rect = parts.field, color = theme.accent, radius = 6*scale, stroke = 2*scale})
		}
		if parts.positions.width > 0 {
			if render.push_layer(list, page) != .None { return .Ok }
			switch_draw(list, parts.positions, p.physical, p.focus == .Positions, theme, scale)
			small := text_styled(text, .Small)
			label := "Key positions"
			return draw_text(&small, list, label, parts.positions.x+parts.positions.width+8*scale,
				parts.positions.y+(parts.positions.height-small.line_height)/2+small.ascent, theme.muted)
		}
		return .Ok
	}
	box_draw(list, parts.field, theme, false, scale)
	shown := row_preview(row, value)
	color := row.value == "" ? theme.muted : theme.text
	return draw_text(&input_text, list, shown, parts.field.x+10*scale, baseline, color,
		max(1, parts.field.width-20*scale))
}

@(private)
popup_draw :: proc(p: ^Editor, l: Editor_Layout, list: ^render.Draw_List, text: ^Text, theme: Theme) -> glyphs.Result {
	r := editor_popup_rect(p, l)
	row := editor_row(p)
	if r.width == 0 || row == nil { return .Ok }
	s := l.scale
	if render.push_layer(list, l.page) != .None { return .Ok }
	draw_rect(list, {rect = {r.x, r.y+6*s, r.width, r.height}, color = theme.shadow, radius = 8*s, softness = 16*s})
	draw_rect(list, {rect = r, color = theme.surface, radius = 8*s})
	draw_rect(list, {rect = r, color = theme.border, radius = 8*s, stroke = s})
	if p.popup == .Choice {
		for name, i in row.choices {
			option := render.Rect{r.x+4*s, r.y+4*s+f32(i)*CHOICE_HEIGHT*s, r.width-8*s, CHOICE_HEIGHT*s}
			if i == p.popup_index { draw_rect(list, {rect = option, color = theme.selection, radius = 5*s}) }
			if name == field_string(&p.value) {
				draw_rect(list, {rect = {option.x, option.y+8*s, 3*s, option.height-16*s}, color = theme.accent,
					radius = 2*s})
			}
			if result := draw_text(text, list, name, option.x+12*s,
				option.y+(option.height-text.line_height)/2+text.ascent, theme.text); result != .Ok { return result }
		}
		return .Ok
	}
	c := color_parts(r, row.kind == .Optional_Color, s)
	wheel := c.wheel
	draw_rect(list, {rect = wheel, color = {p.hsv[2], 0, 0, 1}, radius = wheel.width/2, fill = render.RECT_FILL_HUE_WHEEL})
	draw_rect(list, {rect = wheel, color = theme.border, radius = wheel.width/2, stroke = s})
	angle := math.to_radians(p.hsv[0])
	reach := wheel.width/2*p.hsv[1]
	mx := wheel.x+wheel.width/2+math.cos(angle)*reach
	my := wheel.y+wheel.height/2+math.sin(angle)*reach
	draw_rect(list, {rect = {mx-7*s, my-7*s, 14*s, 14*s}, color = {0, 0, 0, 0.6}, radius = 7*s, stroke = s})
	draw_rect(list, {rect = {mx-6*s, my-6*s, 12*s, 12*s}, color = {1, 1, 1, 1}, radius = 6*s, stroke = 2*s})
	full := color_value(settings.hsv_to_rgb(p.hsv[0], p.hsv[1], 1))
	draw_rect(list, {rect = c.ramp, color = full, radius = 4*s, fill = render.RECT_FILL_VALUE_RAMP})
	draw_rect(list, {rect = c.ramp, color = theme.border, radius = 4*s, stroke = s})
	marker := c.ramp.x+c.ramp.width*p.hsv[2]
	draw_rect(list, {rect = {marker-3*s, c.ramp.y-3*s, 6*s, c.ramp.height+6*s}, color = {1, 1, 1, 1},
		radius = 3*s, stroke = 2*s})
	if color, ok, _ := settings.parse_color(color_or_fallback(row, field_string(&p.value))); ok {
		draw_rect(list, {rect = c.swatch, color = color_value(color), radius = 6*s})
	}
	draw_rect(list, {rect = c.swatch, color = theme.border, radius = 6*s, stroke = s})
	small := text_styled(text, .Small)
	if result := draw_text(&small, list, "Enter saves, Esc closes", c.swatch.x, c.swatch.y+c.swatch.height+22*s,
		theme.muted, c.swatch.width); result != .Ok { return result }
	if c.theme_default.width == 0 { return .Ok }
	box_draw(list, c.theme_default, theme, false, s)
	return draw_text(text, list, "Use theme default", c.theme_default.x+10*s,
		c.theme_default.y+(c.theme_default.height-text.line_height)/2+text.ascent, theme.text,
		c.theme_default.width-20*s)
}

editor_draw :: proc(p: ^Editor, l: Editor_Layout, list: ^render.Draw_List, text: ^Text, theme: Theme,
	focused: bool) -> glyphs.Result {
	s := l.scale
	p.visible_rows = l.rows
	if render.push_layer(list, l.page) != .None { return .Ok }
	strong := text_styled(text, .Strong)
	small := text_styled(text, .Small)
	heading := strong
	text_set_size(&heading, strong.size_px*1.4)
	x := l.filter.x
	if r := draw_text(&heading, list, "Settings", x, l.page.y+36*s, theme.text); r != .Ok { return r }
	status := p.message
	matches := 0
	for item in p.items { matches += item.count }
	if status == "" { status = fmt.tprintf("%d settings and shortcuts", matches) }
	status_x := x+text_width(&heading, "Settings")+16*s
	if r := draw_text(&small, list, status, status_x, l.page.y+36*s, p.error ? theme.error : theme.muted,
		max(1, l.filter.x+l.filter.width-status_x)); r != .Ok { return r }
	if r := field_box_draw(&p.filter, list, text, theme, l.filter, focused && p.focus == .Search,
		"Search settings, groups, and shortcuts", s); r != .Ok { return r }
	if render.push_layer(list, l.list) != .None { return .Ok }
	for index in p.scroll..<min(len(p.items), p.scroll+l.rows) {
		item := p.items[index]
		parts := editor_row_parts(p, l, index)
		r := parts.row
		selected := index == p.selected
		if selected {
			draw_rect(list, {rect = r, color = theme.selection, radius = 6*s})
		} else if index == p.hover_item {
			draw_rect(list, {rect = r, color = theme.hover, radius = 6*s})
		}
		if item.row < 0 {
			baseline := r.y+(r.height-strong.line_height)/2+strong.ascent
			icon_box_draw(list, {r.x+10*s, r.y+(r.height-11*s)/2, 11*s, 11*s}, theme.muted,
				!group_collapsed(p, item.group)^, s)
			if result := draw_text(&strong, list, p.groups[item.group].title, r.x+30*s, baseline, theme.text,
				max(1, r.width*0.7)); result != .Ok { return result }
			label := fmt.tprintf("%d", item.count)
			if result := draw_text(&small, list, label, r.x+r.width-14*s-text_width(&small, label), baseline,
				theme.faint); result != .Ok { return result }
			continue
		}
		row := &p.rows[item.row]
		text_width_limit := max(1, parts.text_right-r.x-30*s)
		if result := draw_text(text, list, row.title, r.x+30*s, r.y+21*s, theme.text, text_width_limit);
			result != .Ok { return result }
		if result := draw_text(&small, list, row.description, r.x+30*s, r.y+39*s, theme.muted, text_width_limit);
			result != .Ok { return result }
		if result := control_draw(p, row, parts, selected, list, text, theme, l.list, s); result != .Ok {
			return result
		}
		if render.push_layer(list, l.list) != .None { return .Ok }
		modified := row.value != row.default_value
		if index == p.hover_reset && modified {
			draw_rect(list, {rect = parts.reset, color = theme.hover, radius = 6*s})
		}
		icon_color := modified ? (index == p.hover_reset ? theme.text : theme.muted) : theme.faint
		if !modified { icon_color.a *= 0.5 }
		if result := draw_icon(text, list, ICON_UNDO, parts.reset, icon_color, 0.9); result != .Ok { return result }
	}
	return popup_draw(p, l, list, text, theme)
}
