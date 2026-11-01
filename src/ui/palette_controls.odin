package ui

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "core:math"
import "core:strconv"
import "core:strings"

@(private) PALETTE_TOGGLE_WIDTH :: 36
@(private) PALETTE_TOGGLE_HEIGHT :: 20
@(private) PALETTE_SLIDER_WIDTH :: 112
@(private) PALETTE_SLIDER_VALUE :: 44
@(private) PALETTE_BOX_HEIGHT :: 26
@(private) PALETTE_CHOICE_WIDTH :: 176
@(private) PALETTE_TEXT_WIDTH :: 196
@(private) PALETTE_POPUP_ROW :: 26
// The reset button matches the Settings page: a square at the row's right edge, before the control.
@(private) PALETTE_RESET_SIZE :: 26
@(private) PALETTE_RESET_INSET :: 8
@(private) PALETTE_RESET_GAP :: 12
@(private) PALETTE_POPUP_ROWS :: 8
@(private) PALETTE_POPUP_SEARCH :: 32
// Keyboard steps across a wide range move a twentieth of the track instead of one unit.
@(private) PALETTE_STEP_FRACTION :: 0.05
@(private) PALETTE_UNIT_STEPS :: 60

// The control a setting row offers in place. None keeps the row jump-only.
Palette_Control :: enum {
	None,
	Toggle,
	Slider,
	Choice,
	Text,
}

// Reads live values for setting controls. `value` returns the saved value and the text a choice
// displays for it; `choices` lists a dynamic choice's values and optional labels. Both may borrow
// temporary memory: the palette copies what it keeps.
Palette_Values :: struct {
	user:    rawptr,
	value:   proc(user: rawptr, key: string) -> (value, label: string),
	choices: proc(user: rawptr, key: string) -> (choices, labels: []string),
}

Palette_Edit_Kind :: enum {
	None,
	Slider,
	Choice,
	Text,
}

// The one setting control being operated: a slider drag, an open choice list or a text entry.
// Choice strings are owned copies, released when the edit ends.
Palette_Edit :: struct {
	kind:            Palette_Edit_Kind,
	setting:         int,
	number:          f64,
	field, filter:   Text_Field,
	choices, labels: [dynamic]string,
	matches:         [dynamic]int,
	index, scroll:   int,
	hover:           int,
}

// A setting's palette entry, built from the row shape the Settings page uses. Settings whose page
// control is a key capture or a group editor stay jump-only. Program groups have no reset there,
// so they have none here.
palette_setting :: proc(entry: settings.Schema_Entry) -> Palette_Setting {
	row := schema_row(entry)
	s := Palette_Setting {
		key           = entry.key,
		title         = entry.title,
		group         = settings.group_title(entry.key),
		minimum       = row.minimum,
		maximum       = row.maximum,
		step          = row.step,
		choices       = row.choices,
		searchable    = row.searchable,
		default_value = entry.default_value,
		resettable    = entry.key != settings.PADDING_GROUPS_KEY,
	}
	#partial switch row.kind {
	case .Toggle:
		s.control = .Toggle
	case .Integer, .Number:
		s.control = .Slider
	case .Choice:
		s.control = .Choice
	case .Text:
		s.control = entry.key == settings.PADDING_GROUPS_KEY ? .None : .Text
	}
	return s
}

palette_set_values :: proc(p: ^Palette, values: Palette_Values) {p.values = values}

palette_editing :: proc(p: ^Palette) -> Palette_Edit_Kind {return p.edit.kind}

// The setting key and value of the last Set_Setting outcome.
palette_chosen_value :: proc(p: ^Palette) -> (key, value: string) {
	return p.chosen, string(p.chosen_value[:])
}

@(private)
edit_init :: proc(e: ^Palette_Edit, allocator := context.allocator) {
	e.field.bytes = make([dynamic]u8, allocator)
	e.filter.bytes = make([dynamic]u8, allocator)
	e.choices = make([dynamic]string, allocator)
	e.labels = make([dynamic]string, allocator)
	e.matches = make([dynamic]int, allocator)
	e.setting, e.hover = -1, -1
}

@(private)
edit_choices_clear :: proc(e: ^Palette_Edit) {
	for s in e.choices {delete(s, e.choices.allocator)}
	for s in e.labels {delete(s, e.labels.allocator)}
	clear(&e.choices)
	clear(&e.labels)
	clear(&e.matches)
}

@(private)
edit_destroy :: proc(e: ^Palette_Edit) {
	edit_choices_clear(e)
	delete(e.field.bytes)
	delete(e.filter.bytes)
	delete(e.choices)
	delete(e.labels)
	delete(e.matches)
}

// Ends any in-place edit without saving.
palette_edit_cancel :: proc(p: ^Palette) {
	if p.edit.kind == .None {return}
	edit_choices_clear(&p.edit)
	p.edit.kind, p.edit.setting, p.edit.hover = .None, -1, -1
	p.edit.field.dragging, p.edit.filter.dragging = false, false
}

// The setting a result row shows, or nil when the row is not a setting.
@(private)
result_setting :: proc(p: ^Palette, index: int) -> ^Palette_Setting {
	if index < 0 || index >= len(p.results) || p.results[index].kind != .Setting {return nil}
	s := p.results[index].setting
	return s >= 0 && s < len(p.settings) ? &p.settings[s] : nil
}

@(private)
setting_value :: proc(p: ^Palette, s: ^Palette_Setting) -> (value, label: string) {
	if p.values.value == nil {return "", ""}
	value, label = p.values.value(p.values.user, s.key)
	if label == "" {label = value}
	return
}

@(private)
snap :: proc(s: ^Palette_Setting, value: f64) -> f64 {
	step := s.step > 0 ? s.step : 1
	return clamp(math.round(value / step) * step, s.minimum, s.maximum)
}

@(private)
setting_number :: proc(p: ^Palette, s: ^Palette_Setting) -> f64 {
	value, _ := setting_value(p, s)
	number, ok := strconv.parse_f64(value)
	return ok ? number : s.minimum
}

// Records a new value for the owner to save. The palette stays open on this setting.
@(private)
choose_value :: proc(p: ^Palette, s: ^Palette_Setting, value: string) -> Outcome {
	current, _ := setting_value(p, s)
	palette_edit_cancel(p)
	if value == current {return .Changed}
	p.chosen = s.key
	clear(&p.chosen_value)
	append(&p.chosen_value, value)
	return .Set_Setting
}

@(private)
choose_number :: proc(p: ^Palette, s: ^Palette_Setting, value: f64) -> Outcome {
	return choose_value(p, s, number_text(s.step > 0 ? s.step : 1, snap(s, value)))
}

@(private)
step_number :: proc(p: ^Palette, s: ^Palette_Setting, direction: int) -> Outcome {
	current := setting_number(p, s)
	step := s.step > 0 ? s.step : 1
	if (s.maximum - s.minimum) / step <= PALETTE_UNIT_STEPS {
		return choose_number(p, s, current + f64(direction) * step)
	}
	fraction := slider_fraction(s.minimum, s.maximum, current) + f32(direction) * PALETTE_STEP_FRACTION
	next := snap(s, slider_value(s.minimum, s.maximum, fraction))
	// Snapping can land back on the current value near the low end of a logarithmic track.
	if next == current {next = snap(s, current + f64(direction) * step)}
	return choose_number(p, s, next)
}

// The values a choice offers: static enum names, or the owner's live list.
@(private)
static_or_live_choices :: proc(p: ^Palette, s: ^Palette_Setting) -> (choices, labels: []string) {
	if len(s.choices) > 0 {return s.choices, nil}
	if p.values.choices == nil {return nil, nil}
	return p.values.choices(p.values.user, s.key)
}

@(private)
step_choice :: proc(p: ^Palette, s: ^Palette_Setting, direction: int) -> Outcome {
	choices, _ := static_or_live_choices(p, s)
	if len(choices) == 0 {return .None}
	current, _ := setting_value(p, s)
	index := -1
	for choice, i in choices {if choice == current {index = i; break}}
	next := index < 0 ? 0 : (index + direction + len(choices)) % len(choices)
	return choose_value(p, s, choices[next])
}

@(private)
choice_filter_update :: proc(p: ^Palette) {
	e := &p.edit
	choice_matches_filter(&e.matches, e.choices[:], e.labels[:], field_string(&e.filter))
	e.index, e.scroll = 0, 0
}

@(private)
open_choice :: proc(p: ^Palette, setting: int) -> Outcome {
	s := &p.settings[setting]
	choices, labels := static_or_live_choices(p, s)
	if len(choices) == 0 {return .None}
	palette_edit_cancel(p)
	e := &p.edit
	allocator := e.choices.allocator
	current, _ := setting_value(p, s)
	for choice, i in choices {
		label := i < len(labels) ? labels[i] : ""
		append(&e.choices, strings.clone(choice, allocator))
		append(&e.labels, label != "" && label != choice ? strings.clone(label, allocator) : "")
	}
	field_set(&e.filter, "")
	e.kind, e.setting = .Choice, setting
	choice_filter_update(p)
	for match, i in e.matches {if e.choices[match] == current {e.index = i}}
	popup_keep_visible(p)
	return .Changed
}

@(private)
open_text :: proc(p: ^Palette, setting: int) -> Outcome {
	s := &p.settings[setting]
	palette_edit_cancel(p)
	value, _ := setting_value(p, s)
	field_set(&p.edit.field, value)
	field_select_all(&p.edit.field)
	p.edit.kind, p.edit.setting = .Text, setting
	return .Changed
}

@(private)
popup_keep_visible :: proc(p: ^Palette) {
	e := &p.edit
	count := len(e.matches)
	e.index = clamp(e.index, 0, max(0, count - 1))
	if e.index < e.scroll {e.scroll = e.index}
	if e.index >= e.scroll + PALETTE_POPUP_ROWS {e.scroll = e.index - PALETTE_POPUP_ROWS + 1}
	e.scroll = clamp(e.scroll, 0, max(0, count - PALETTE_POPUP_ROWS))
}

@(private)
popup_choose :: proc(p: ^Palette, index: int) -> Outcome {
	e := &p.edit
	if index < 0 || index >= len(e.matches) || e.setting < 0 {return .None}
	value := strings.clone(e.choices[e.matches[index]], context.temp_allocator)
	return choose_value(p, &p.settings[e.setting], value)
}

// Toggles flip, choices open their list, and sliders and text open a typed entry.
@(private)
control_activate :: proc(p: ^Palette, setting: int) -> Outcome {
	s := &p.settings[setting]
	switch s.control {
	case .None:
		return .None
	case .Toggle:
		value, _ := setting_value(p, s)
		return choose_value(p, s, value == "true" ? "false" : "true")
	case .Choice:
		return open_choice(p, setting)
	case .Slider, .Text:
		return open_text(p, setting)
	}
	return .None
}

@(private)
control_step :: proc(p: ^Palette, setting: int, direction: int) -> Outcome {
	s := &p.settings[setting]
	switch s.control {
	case .None, .Text:
		return .None
	case .Toggle:
		value, _ := setting_value(p, s)
		want := direction > 0 ? "true" : "false"
		return value == want ? .Changed : choose_value(p, s, want)
	case .Slider:
		return step_number(p, s, direction)
	case .Choice:
		return step_choice(p, s, direction)
	}
	return .None
}

// Keys for an open choice list or text entry. Every key is consumed.
@(private)
edit_key :: proc(p: ^Palette, e: platform.Key_Event) -> Outcome {
	edit := &p.edit
	#partial switch e.key {
	case .Escape:
		palette_edit_cancel(p)
		return .Changed
	case .Tab:
		return .None
	}
	switch edit.kind {
	case .None, .Slider:
		return .None
	case .Text:
		#partial switch e.key {
		case .Enter, .Numpad_Enter:
			s := &p.settings[edit.setting]
			value := strings.clone(field_string(&edit.field), context.temp_allocator)
			if s.control == .Slider {
				number, ok := strconv.parse_f64(strings.trim_space(value))
				// An unreadable number still goes to the owner, which reports why it was refused.
				if ok {return choose_number(p, s, number)}
			}
			return choose_value(p, s, value)
		}
		return field_key(&edit.field, e) == .None ? .None : .Changed
	case .Choice:
		if step := list_step(e); step != 0 {
			edit.index += step
			popup_keep_visible(p)
			return .Changed
		}
		#partial switch e.key {
		case .Enter, .Numpad_Enter:
			return popup_choose(p, edit.index)
		case .Page_Up:
			edit.index -= PALETTE_POPUP_ROWS
			popup_keep_visible(p)
			return .Changed
		case .Page_Down:
			edit.index += PALETTE_POPUP_ROWS
			popup_keep_visible(p)
			return .Changed
		}
		if !popup_searchable(p) {return .None}
		if field_key(&edit.filter, e) == .Edited {choice_filter_update(p)}
		return .Changed
	}
	return .None
}

// The field typed text and pastes go to while an edit is open.
@(private)
edit_field :: proc(p: ^Palette) -> ^Text_Field {
	switch p.edit.kind {
	case .Text:
		return &p.edit.field
	case .Choice:
		return popup_searchable(p) ? &p.edit.filter : nil
	case .None, .Slider:
	}
	return nil
}

@(private)
edit_text :: proc(p: ^Palette, text: string) -> Outcome {
	field := edit_field(p)
	if field == nil {return .None}
	change := field_text(field, text)
	if change == .Edited && p.edit.kind == .Choice {choice_filter_update(p)}
	return change == .None ? .None : .Changed
}

// Where a setting row draws its control, at the row's right edge.
@(private)
control_rect :: proc(s: ^Palette_Setting, row: render.Rect, scale: f32) -> render.Rect {
	right := row.x + row.width - PALETTE_TEXT_INSET * scale
	if s.resettable {right = reset_rect(s, row, scale).x - PALETTE_RESET_GAP * scale}
	cy := row.y + row.height / 2
	switch s.control {
	case .None:
		return {}
	case .Toggle:
		w, h := PALETTE_TOGGLE_WIDTH * scale, PALETTE_TOGGLE_HEIGHT * scale
		return {right - w, cy - h / 2, w, h}
	case .Slider:
		w, h := (PALETTE_SLIDER_WIDTH + PALETTE_SLIDER_VALUE) * scale, PALETTE_BOX_HEIGHT * scale
		return {right - w, cy - h / 2, w, h}
	case .Choice:
		w, h := PALETTE_CHOICE_WIDTH * scale, PALETTE_BOX_HEIGHT * scale
		return {right - w, cy - h / 2, w, h}
	case .Text:
		w, h := PALETTE_TEXT_WIDTH * scale, PALETTE_BOX_HEIGHT * scale
		return {right - w, cy - h / 2, w, h}
	}
	return {}
}

// The reset-to-default button of a setting row, or nothing for a setting without one.
@(private)
reset_rect :: proc(s: ^Palette_Setting, row: render.Rect, scale: f32) -> render.Rect {
	if !s.resettable {return {}}
	size := PALETTE_RESET_SIZE * scale
	x := row.x + row.width - (PALETTE_RESET_INSET + PALETTE_RESET_SIZE) * scale
	return {x, row.y + (row.height - size) / 2, size, size}
}

@(private)
setting_modified :: proc(p: ^Palette, s: ^Palette_Setting) -> bool {
	value, _ := setting_value(p, s)
	return value != s.default_value
}

// The setting row whose reset button is under the pointer, or -1.
@(private)
reset_at :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> int {
	index := row_at(p, l, x, y)
	s := result_setting(p, index)
	if s == nil {return -1}
	row, _ := row_rect(p, l, index)
	return contains(reset_rect(s, row, l.scale), x, y) ? index : -1
}

// A press on a reset button saves the default. An unmodified setting has nothing to reset.
@(private)
reset_press :: proc(p: ^Palette, l: Palette_Layout, index: int, x, y: f32) -> (Outcome, bool) {
	if reset_at(p, l, x, y) != index {return .None, false}
	s := result_setting(p, index)
	p.selected = index
	if !setting_modified(p, s) {return .Changed, true}
	return choose_value(p, s, s.default_value), true
}

@(private)
draw_reset :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	theme: Theme,
	l: Palette_Layout,
	index: int,
	row: render.Rect,
	pointer: [2]f32,
) -> glyphs.Result {
	s := result_setting(p, index)
	rect := reset_rect(s, row, l.scale)
	if rect.width <= 0 {return .Ok}
	hovered := contains(rect, pointer.x, pointer.y)
	modified, selected := setting_modified(p, s), index == p.selected
	_ = reset_button_draw(list, theme, rect, modified, hovered, selected, pointer, l.scale)
	return .Ok
}

@(private)
slider_track :: proc(control: render.Rect, scale: f32) -> render.Rect {
	return {control.x + 7 * scale, control.y, PALETTE_SLIDER_WIDTH * scale - 14 * scale, control.height}
}

@(private)
slider_number_rect :: proc(control: render.Rect, scale: f32) -> render.Rect {
	w := PALETTE_SLIDER_VALUE * scale
	return {control.x + control.width - w, control.y, w, control.height}
}

// The rectangle of result `index` when it is on screen.
@(private)
row_rect :: proc(p: ^Palette, l: Palette_Layout, index: int) -> (render.Rect, bool) {
	y := l.list.y
	rows := 0
	for i := p.scroll; i < len(p.results) && rows < l.rows; i += 1 {
		if row_header(p, i) {y += l.header_height}
		if i == index {return {l.list.x, y, l.list.width, l.row_height}, true}
		y += l.row_height
		rows += 1
	}
	return {}, false
}

@(private)
setting_row :: proc(p: ^Palette, l: Palette_Layout, setting: int) -> (render.Rect, bool) {
	for result, i in p.results {
		if result.kind == .Setting && result.setting == setting {return row_rect(p, l, i)}
	}
	return {}, false
}

@(private)
edit_control :: proc(p: ^Palette, l: Palette_Layout) -> render.Rect {
	if p.edit.setting < 0 {return {}}
	row, ok := setting_row(p, l, p.edit.setting)
	if !ok {return {}}
	return control_rect(&p.settings[p.edit.setting], row, l.scale)
}

// The open choice list, below its control or above it when the window has no room below.
palette_popup_rect :: proc(p: ^Palette, l: Palette_Layout) -> render.Rect {
	if p.edit.kind != .Choice {return {}}
	control := edit_control(p, l)
	if control.width <= 0 {return {}}
	s := l.scale
	rows := min(PALETTE_POPUP_ROWS, max(1, len(p.edit.matches)))
	height := f32(rows * PALETTE_POPUP_ROW + 8) * s
	if popup_searchable(p) {height += PALETTE_POPUP_SEARCH * s}
	width := max(control.width, 220 * s)
	x := clamp(control.x + control.width - width, s, max(s, l.viewport.width - width - s))
	y := control.y + control.height + 4 * s
	if y + height > l.viewport.height - s {y = max(s, control.y - height - 4 * s)}
	return {x, y, width, height}
}

palette_popup_contains :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> bool {
	return contains(palette_popup_rect(p, l), x, y)
}

// Searchable lists, such as installed fonts, have a filter field at the top of the popup.
@(private)
popup_searchable :: proc(p: ^Palette) -> bool {
	return p.edit.setting >= 0 && p.settings[p.edit.setting].searchable
}

@(private)
popup_list_top :: proc(p: ^Palette, popup: render.Rect, scale: f32) -> f32 {
	top := popup.y + 4 * scale
	if popup_searchable(p) {top += PALETTE_POPUP_SEARCH * scale}
	return top
}

@(private)
popup_row_at :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> int {
	popup := palette_popup_rect(p, l)
	if !contains(popup, x, y) {return -1}
	top := popup_list_top(p, popup, l.scale)
	if y < top {return -1}
	index := p.edit.scroll + int((y - top) / (PALETTE_POPUP_ROW * l.scale))
	return index < len(p.edit.matches) ? index : -1
}

@(private)
popup_search_box :: proc(p: ^Palette, popup: render.Rect, text: ^Text, scale: f32) -> Field_Box {
	return {
		field = &p.edit.filter, text = text,
		rect = {popup.x + 4 * scale, popup.y + 4 * scale, popup.width - 8 * scale, 28 * scale},
		inset = 10, caret_width = 1, radius = 4, style = .Input, scale = scale,
	}
}

@(private)
text_entry_box :: proc(p: ^Palette, control: render.Rect, text: ^Text, scale: f32) -> Field_Box {
	return {
		field = &p.edit.field, text = text, rect = control,
		inset = 8, caret_width = 1, radius = 6, style = .Input, scale = scale,
	}
}

// A press on a setting row's control. The second result is false when the press missed it.
@(private)
control_press :: proc(p: ^Palette, l: Palette_Layout, index: int, x, y: f32) -> (Outcome, bool) {
	s := result_setting(p, index)
	if s == nil || s.control == .None {return .None, false}
	row, ok := row_rect(p, l, index)
	if !ok {return .None, false}
	control := control_rect(s, row, l.scale)
	// The toggle takes a slightly taller target than it draws.
	target := control
	target.y, target.height = row.y, row.height
	if !contains(target, x, y) {return .None, false}
	setting := p.results[index].setting
	p.selected = index
	#partial switch s.control {
	case .Slider:
		if contains(slider_number_rect(control, l.scale), x, y) {return open_text(p, setting), true}
		palette_edit_cancel(p)
		p.edit.kind, p.edit.setting = .Slider, setting
		track := slider_track(control, l.scale)
		p.edit.number = snap(s, slider_value(s.minimum, s.maximum, (x - track.x) / max(1, track.width)))
		return .Changed, true
	}
	return control_activate(p, setting), true
}

palette_slider_dragging :: proc(p: ^Palette) -> bool {return p.edit.kind == .Slider}

palette_slider_drag :: proc(p: ^Palette, l: Palette_Layout, x: f32) -> Outcome {
	if p.edit.kind != .Slider {return .None}
	s := &p.settings[p.edit.setting]
	track := slider_track(edit_control(p, l), l.scale)
	if track.width <= 0 {return .None}
	number := snap(s, slider_value(s.minimum, s.maximum, (x - track.x) / track.width))
	if number == p.edit.number {return .None}
	p.edit.number = number
	return .Changed
}

// Ends a pointer gesture: a released slider saves the value it shows.
palette_pointer_release :: proc(p: ^Palette) -> Outcome {
	p.query.dragging, p.edit.field.dragging, p.edit.filter.dragging = false, false, false
	if p.edit.kind != .Slider {return .None}
	return choose_number(p, &p.settings[p.edit.setting], p.edit.number)
}

@(private)
popup_wheel :: proc(p: ^Palette, rows: int) -> Outcome {
	limit := max(0, len(p.edit.matches) - PALETTE_POPUP_ROWS)
	scroll := clamp(p.edit.scroll - rows, 0, limit)
	if scroll == p.edit.scroll {return .None}
	p.edit.scroll = scroll
	p.edit.index = clamp(p.edit.index, scroll, scroll + PALETTE_POPUP_ROWS - 1)
	return .Changed
}

// Mouse presses while a choice list or text entry is open. The second result is false when the
// press should fall through to the palette after the edit ended.
@(private)
edit_press :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, y: f32) -> (Outcome, bool) {
	switch p.edit.kind {
	case .None, .Slider:
		return .None, false
	case .Choice:
		popup := palette_popup_rect(p, l)
		if contains(popup, x, y) {
			if index := popup_row_at(p, l, x, y); index >= 0 {return popup_choose(p, index), true}
			if text != nil && popup_searchable(p) {
				box := popup_search_box(p, popup, text, l.scale)
				if contains(box.rect, x, y) {
					_ = field_pointer(&p.edit.filter, field_box_offset(box, x), true, false)
				}
			}
			return .Changed, true
		}
		// A press on the open control closes the list, like the Settings page.
		closing := contains(edit_control(p, l), x, y)
		palette_edit_cancel(p)
		return .Changed, closing
	case .Text:
		control := edit_control(p, l)
		if contains(control, x, y) {
			if text != nil {
				box := text_entry_box(p, control, text, l.scale)
				_ = field_pointer(&p.edit.field, field_box_offset(box, x), true, false)
			}
			return .Changed, true
		}
		palette_edit_cancel(p)
		return .Changed, false
	}
	return .None, false
}

palette_edit_drag :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x: f32) -> Outcome {
	if p.edit.kind == .Text && p.edit.field.dragging {
		box := text_entry_box(p, edit_control(p, l), text, l.scale)
		return field_pointer(&p.edit.field, field_box_offset(box, x), false, true) == .None ? .None : .Changed
	}
	if p.edit.kind == .Choice && p.edit.filter.dragging {
		box := popup_search_box(p, palette_popup_rect(p, l), text, l.scale)
		return field_pointer(&p.edit.filter, field_box_offset(box, x), false, true) == .None ? .None : .Changed
	}
	return .None
}

palette_edit_text_dragging :: proc(p: ^Palette) -> bool {
	return p.edit.field.dragging || p.edit.filter.dragging
}

// The pointer shape over a setting control or an open edit; ok is false elsewhere.
@(private)
control_pointer :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> (platform.Cursor_Shape, bool) {
	switch p.edit.kind {
	case .Choice:
		popup := palette_popup_rect(p, l)
		if contains(popup, x, y) {
			if popup_row_at(p, l, x, y) >= 0 {return .Hand, true}
			return y < popup_list_top(p, popup, l.scale) ? .Text : .Arrow, true
		}
	case .Text:
		if contains(edit_control(p, l), x, y) {return .Text, true}
	case .Slider:
		return .Hand, true
	case .None:
	}
	index := row_at(p, l, x, y)
	s := result_setting(p, index)
	if s == nil {return .Arrow, false}
	if reset_at(p, l, x, y) == index {return .Hand, true}
	if s.control == .None {return .Arrow, false}
	row, _ := row_rect(p, l, index)
	if contains(control_rect(s, row, l.scale), x, y) {return .Hand, true}
	return .Arrow, false
}

@(private)
draw_control :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
	setting: int,
	row: render.Rect,
) -> glyphs.Result {
	s := &p.settings[setting]
	scale := l.scale
	control := control_rect(s, row, scale)
	if control.width <= 0 {return .Ok}
	editing := p.edit.setting == setting
	value, label := setting_value(p, s)
	input_text := text_styled(text, .Input)
	baseline := control.y + (control.height - input_text.line_height) / 2 + input_text.ascent
	if editing && p.edit.kind == .Text {
		box := text_entry_box(p, control, text, scale)
		box_draw(list, control, theme, true, scale)
		result := field_box_draw(box, list, theme, field_box_baseline(box), true, "Empty")
		// The field leaves its clip pushed; later rows draw in the list again.
		_ = render.push_layer(list, l.list)
		return result
	}
	switch s.control {
	case .None:
	case .Toggle:
		switch_draw(list, control, value == "true", false, theme, scale)
	case .Slider:
		number := editing && p.edit.kind == .Slider ? p.edit.number : setting_number(p, s)
		slider_draw(list, slider_track(control, scale), slider_fraction(s.minimum, s.maximum, number), theme, scale)
		shown := number_text(s.step > 0 ? s.step : 1, number)
		number_box := slider_number_rect(control, scale)
		width := text_width(&input_text, shown)
		return draw_text(&input_text, list, shown, number_box.x + number_box.width - width, baseline,
			theme.muted, number_box.width)
	case .Choice:
		box_draw(list, control, theme, editing && p.edit.kind == .Choice, scale)
		if result := draw_text(&input_text, list, label, control.x + 10 * scale, baseline, theme.text,
			max(1, control.width - 36 * scale)); result != .Ok {return result}
		chevron := render.Rect{control.x + control.width - 26 * scale, control.y, 20 * scale, control.height}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
	case .Text:
		box_draw(list, control, theme, false, scale)
		shown, color := value, theme.text
		if shown == "" {shown, color = "Empty", theme.faint}
		return draw_text(&input_text, list, shown, control.x + 8 * scale, baseline, color,
			max(1, control.width - 16 * scale))
	}
	return .Ok
}

@(private)
draw_popup :: proc(
	p: ^Palette,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	l: Palette_Layout,
) -> glyphs.Result {
	popup := palette_popup_rect(p, l)
	if popup.width <= 0 {return .Ok}
	scale := l.scale
	if render.push_layer(list, popup) != .None {return .Ok}
	draw_rect(list, {rect = popup, color = theme.pane, radius = 7 * scale})
	draw_rect(list, {rect = popup, color = theme.border, radius = 7 * scale, stroke = scale})
	e := &p.edit
	if popup_searchable(p) {
		box := popup_search_box(p, popup, text, scale)
		box_draw(list, box.rect, theme, true, scale)
		if result := field_box_draw(box, list, theme, field_box_baseline(box), true, "Search");
		   result != .Ok {return result}
		if render.push_layer(list, popup) != .None {return .Ok}
	}
	top := popup_list_top(p, popup, scale)
	row_height := PALETTE_POPUP_ROW * scale
	item_text := text_styled(text, .Small)
	if len(e.matches) == 0 {
		baseline := top + (row_height - item_text.line_height) / 2 + item_text.ascent
		return draw_text(&item_text, list, "No matches", popup.x + 12 * scale, baseline, theme.muted)
	}
	current, _ := setting_value(p, &p.settings[e.setting])
	for i := e.scroll; i < len(e.matches) && i < e.scroll + PALETTE_POPUP_ROWS; i += 1 {
		choice := e.matches[i]
		row := render.Rect{popup.x + 3 * scale, top + f32(i - e.scroll) * row_height, popup.width - 6 * scale,
			row_height}
		if i == e.index {
			draw_rect(list, {rect = row, color = theme.selection, radius = 4 * scale})
		} else if i == e.hover {
			draw_rect(list, {rect = row, color = theme.hover, radius = 4 * scale})
		}
		label := e.labels[choice] != "" ? e.labels[choice] : e.choices[choice]
		saved := e.choices[choice] == current
		baseline := row.y + (row.height - item_text.line_height) / 2 + item_text.ascent
		if saved {
			check := render.Rect{row.x + row.width - 24 * scale, row.y, 20 * scale, row.height}
			icon_draw(list, .Check, check, theme.accent, ICON_INDICATOR, scale)
		}
		if result := draw_text(&item_text, list, label, row.x + 9 * scale, baseline,
			saved ? theme.text : theme.muted, max(1, row.width - 40 * scale)); result != .Ok {return result}
	}
	return .Ok
}
