package ui

import "aio:input"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "core:math"
import "core:strconv"
import "core:strings"

@(private) PALETTE_SLIDER_WIDTH :: 112
@(private) PALETTE_SLIDER_VALUE :: 44
@(private) PALETTE_BOX_HEIGHT :: HEIGHT_COMPACT
@(private) PALETTE_CHOICE_WIDTH :: 176
@(private) PALETTE_TEXT_WIDTH :: 196
@(private) PALETTE_POPUP_ROW :: MENU_ROW_HEIGHT
// The reset button matches the Settings page: a square at the row's right edge, before the control.
@(private) PALETTE_RESET_SIZE :: HEIGHT_COMPACT
@(private) PALETTE_RESET_INSET :: SPACE_2
@(private) PALETTE_RESET_GAP :: SPACE_3
@(private) PALETTE_POPUP_SEARCH :: HEIGHT_STANDARD
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

// What palette_editing reports. A slider is edited only while the pointer drags it, so its state is
// Slider_Drag in Palette_Drag rather than a Palette_Edit variant.
Palette_Edit_Kind :: enum {
	None,
	Slider,
	Choice,
	Text,
	Shortcut,
}

// The one control open in place: a setting's choice list or text entry, or a command's shortcut
// row. nil when none is. edit_set is the only writer.
Palette_Edit :: union {
	Choice_Edit,
	Text_Edit,
	Shortcut_Edit,
}

// `list` holds the highlighted match and the first match shown; `hover` is the match under the
// pointer, or -1.
Choice_Edit :: struct {
	setting: int,
	list:    Choice_List,
	hover:   int,
}

Text_Edit :: struct {
	setting: int,
}

// The inline shortcut row of result `result`. Its capture records chords and lists alternatives
// exactly as a Settings shortcut row does. It owns the setting key, the saved alternatives the list
// shows, the defaults a reset restores and the draft a save sends.
Shortcut_Edit :: struct {
	capture:              Shortcut_Capture,
	key, saved, defaults: string,
	draft:                Text_Field,
	result:               int,
}

// Storage the open edit fills: the text entry, the choice list's filter, owned copies of the
// choices and their labels, and the choices the filter matches. Each is meaningful only while the
// edit that fills it is open; it outlives edits so opening one reuses its capacity.
Edit_Buffers :: struct {
	field, filter:   Text_Field,
	choices, labels: [dynamic]string,
	matches:         [dynamic]int,
}

// What the pointer holds, one thing at a time: a selection drag in the query, the text entry or the
// choice filter, the results' scrollbar thumb, or a slider with the value it shows. A press starts
// it; palette_pointer_release ends it, and palette_drag_cancel drops it without saving. drag_set is
// the only writer.
Palette_Drag :: union {
	Query_Drag,
	Field_Drag,
	Filter_Drag,
	Scrollbar_Drag,
	Slider_Drag,
}

Query_Drag :: struct {}

Field_Drag :: struct {}

Filter_Drag :: struct {}

Scrollbar_Drag :: struct {
	grab: f32,
}

Slider_Drag :: struct {
	setting: int,
	number:  f64,
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
		resettable    = entry.control != .Group,
	}
	#partial switch row.kind {
	case .Toggle:
		s.control = .Toggle
	case .Integer, .Number:
		s.control = .Slider
	case .Choice:
		// A multiple choice keeps its popup open between options, so it is edited on the page.
		s.control = row.multiple ? .None : .Choice
	case .Text:
		s.control = entry.control == .Group ? .None : .Text
	}
	return s
}

palette_set_values :: proc(p: ^Palette, values: Palette_Values) {p.values = values}

palette_editing :: proc(p: ^Palette) -> Palette_Edit_Kind {
	if _, sliding := p.drag.(Slider_Drag); sliding {return .Slider}
	switch _ in p.edit {
	case Choice_Edit:
		return .Choice
	case Text_Edit:
		return .Text
	case Shortcut_Edit:
		return .Shortcut
	}
	return .None
}

@(private)
edit_init :: proc(b: ^Edit_Buffers, allocator := context.allocator) {
	b.field.bytes = make([dynamic]u8, allocator)
	b.filter.bytes = make([dynamic]u8, allocator)
	b.choices = make([dynamic]string, allocator)
	b.labels = make([dynamic]string, allocator)
	b.matches = make([dynamic]int, allocator)
}

@(private)
edit_choices_clear :: proc(b: ^Edit_Buffers) {
	for s in b.choices {delete(s, b.choices.allocator)}
	for s in b.labels {delete(s, b.labels.allocator)}
	clear(&b.choices)
	clear(&b.labels)
	clear(&b.matches)
}

@(private)
edit_destroy :: proc(b: ^Edit_Buffers) {
	edit_choices_clear(b)
	delete(b.field.bytes)
	delete(b.filter.bytes)
	delete(b.choices)
	delete(b.labels)
	delete(b.matches)
}

// Leaving an edit frees what it owned and ends its selection drag. Opening one drops any pointer
// hold without saving, since keys and presses now go to the edit.
@(private)
edit_set :: proc(p: ^Palette, next: Palette_Edit) {
	switch &e in p.edit {
	case Choice_Edit:
		edit_choices_clear(&p.buffers)
	case Text_Edit:
	case Shortcut_Edit:
		delete(e.key)
		delete(e.saved)
		delete(e.defaults)
		delete(e.draft.bytes)
	}
	#partial switch _ in p.drag {
	case Field_Drag, Filter_Drag:
		drag_set(p, nil)
	}
	if next != nil {drag_set(p, nil)}
	palette_choose(p, nil)
	p.edit = next
}

// The only writer of p.drag. The palette's text fields move by its drag state, never by their own
// `dragging` flag.
@(private)
drag_set :: proc(p: ^Palette, next: Palette_Drag) {p.drag = next}

// Drops whatever the pointer holds without saving, as when the window loses the pointer capture.
palette_drag_cancel :: proc(p: ^Palette) {drag_set(p, nil)}

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
	edit_set(p, nil)
	if value == current {return .Changed}
	return choose_setting(p, s.key, value)
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
choice_filter_update :: proc(p: ^Palette, c: ^Choice_Edit) {
	b := &p.buffers
	choice_matches_filter(&b.matches, b.choices[:], b.labels[:], field_string(&b.filter))
	c.list = {}
}

@(private)
open_choice :: proc(p: ^Palette, setting: int) -> Outcome {
	s := &p.settings[setting]
	choices, labels := static_or_live_choices(p, s)
	if len(choices) == 0 {return .None}
	edit_set(p, nil)
	b := &p.buffers
	allocator := b.choices.allocator
	current, _ := setting_value(p, s)
	for choice, i in choices {
		label := i < len(labels) ? labels[i] : ""
		append(&b.choices, strings.clone(choice, allocator))
		append(&b.labels, label != "" && label != choice ? strings.clone(label, allocator) : "")
	}
	field_set(&b.filter, "")
	edit_set(p, Choice_Edit{setting = setting, hover = -1})
	c := &p.edit.(Choice_Edit)
	choice_filter_update(p, c)
	for match, i in b.matches {if b.choices[match] == current {c.list.index = i}}
	choice_list_keep_visible(&c.list, len(b.matches))
	return .Changed
}

@(private)
open_text :: proc(p: ^Palette, setting: int) -> Outcome {
	s := &p.settings[setting]
	edit_set(p, nil)
	value, _ := setting_value(p, s)
	field_set(&p.buffers.field, value)
	field_select_all(&p.buffers.field)
	edit_set(p, Text_Edit{setting})
	return .Changed
}

@(private)
popup_choose :: proc(p: ^Palette, c: ^Choice_Edit, index: int) -> Outcome {
	b := &p.buffers
	if index < 0 || index >= len(b.matches) {return .None}
	value := strings.clone(b.choices[b.matches[index]], context.temp_allocator)
	return choose_value(p, &p.settings[c.setting], value)
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
edit_key :: proc(p: ^Palette, e: input.Key_Event) -> Outcome {
	#partial switch e.key {
	case .Escape:
		edit_set(p, nil)
		return .Changed
	case .Tab:
		return .None
	}
	b := &p.buffers
	#partial switch &edit in p.edit {
	case Text_Edit:
		#partial switch e.key {
		case .Enter, .Numpad_Enter:
			s := &p.settings[edit.setting]
			value := strings.clone(field_string(&b.field), context.temp_allocator)
			if s.control == .Slider {
				number, ok := strconv.parse_f64(strings.trim_space(value))
				// An unreadable number still goes to the owner, which reports why it was refused.
				if ok {return choose_number(p, s, number)}
			}
			return choose_value(p, s, value)
		}
		return field_key(&b.field, e) == .None ? .None : .Changed
	case Choice_Edit:
		if choice_list_key(&edit.list, e, len(b.matches)) {return .Changed}
		if e.key == .Enter || e.key == .Numpad_Enter {return popup_choose(p, &edit, edit.list.index)}
		if !p.settings[edit.setting].searchable {return .None}
		if field_key(&b.filter, e) == .Edited {choice_filter_update(p, &edit)}
		return .Changed
	}
	return .None
}

// The field typed text and pastes go to while an edit is open: the text entry, or a searchable
// choice list's filter.
@(private)
edit_field :: proc(p: ^Palette) -> ^Text_Field {
	#partial switch edit in p.edit {
	case Text_Edit:
		return &p.buffers.field
	case Choice_Edit:
		return p.settings[edit.setting].searchable ? &p.buffers.filter : nil
	}
	return nil
}

@(private)
edit_text :: proc(p: ^Palette, text: string) -> Outcome {
	field := edit_field(p)
	if field == nil {return .None}
	change := field_text(field, text)
	if c, listing := &p.edit.(Choice_Edit); listing && change == .Edited {choice_filter_update(p, c)}
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
		w, h := SWITCH_WIDTH * scale, SWITCH_HEIGHT * scale
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
	return render.rect_contains(reset_rect(s, row, l.scale), x, y) ? index : -1
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
) -> render.Build_Status {
	s := result_setting(p, index)
	rect := reset_rect(s, row, l.scale)
	if rect.width <= 0 {return .Ok}
	hovered := render.rect_contains(rect, pointer.x, pointer.y)
	modified, selected := setting_modified(p, s), index == p.selected
	_ = reset_button_draw(list, theme, rect, modified, hovered, selected, pointer, l.scale)
	return .Ok
}

@(private)
slider_track :: proc(control: render.Rect, scale: f32) -> render.Rect {
	half := SLIDER_THUMB / 2 * scale
	return {control.x + half, control.y, PALETTE_SLIDER_WIDTH * scale - 2 * half, control.height}
}

@(private)
slider_number_rect :: proc(control: render.Rect, scale: f32) -> render.Rect {
	w := PALETTE_SLIDER_VALUE * scale
	return {control.x + control.width - w, control.y, w, control.height}
}

// The rectangle of result `index` when it is on screen.
@(private)
row_rect :: proc(p: ^Palette, l: Palette_Layout, index: int) -> (render.Rect, bool) {
	if index < p.scroll || index >= len(p.results) || index - p.scroll >= l.rows {return {}, false}
	return {l.list.x, l.list.y + f32(index - p.scroll) * l.row_height, l.list.width, l.row_height}, true
}

@(private)
setting_row :: proc(p: ^Palette, l: Palette_Layout, setting: int) -> (render.Rect, bool) {
	for result, i in p.results {
		if result.kind == .Setting && result.setting == setting {return row_rect(p, l, i)}
	}
	return {}, false
}

@(private)
edit_control :: proc(p: ^Palette, l: Palette_Layout, setting: int) -> render.Rect {
	row, ok := setting_row(p, l, setting)
	if !ok {return {}}
	return control_rect(&p.settings[setting], row, l.scale)
}

// The open choice list or shortcut alternatives, or nothing.
palette_popup_rect :: proc(p: ^Palette, l: Palette_Layout) -> render.Rect {
	#partial switch &edit in p.edit {
	case Shortcut_Edit:
		return palette_binding_popup(p, &edit, l)
	case Choice_Edit:
		return choice_popup_rect(p, &edit, l)
	}
	return {}
}

// The choice list, below its control or above it when the window has no room below.
@(private)
choice_popup_rect :: proc(p: ^Palette, c: ^Choice_Edit, l: Palette_Layout) -> render.Rect {
	control := edit_control(p, l, c.setting)
	if control.width <= 0 {return {}}
	s := l.scale
	rows := min(CHOICE_LIST_ROWS, max(1, len(p.buffers.matches)))
	height := (f32(rows) * PALETTE_POPUP_ROW + 2 * OVERLAY_PADDING) * s
	if p.settings[c.setting].searchable {height += PALETTE_POPUP_SEARCH * s}
	width := max(control.width, 220 * s)
	x := clamp(control.x + control.width - width, s, max(s, l.viewport.width - width - s))
	y := control.y + control.height + 4 * s
	if y + height > l.viewport.height - s {y = max(s, control.y - height - 4 * s)}
	return {x, y, width, height}
}

palette_popup_contains :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> bool {
	return render.rect_contains(palette_popup_rect(p, l), x, y)
}

// Searchable lists, such as installed fonts, have a filter field at the top of the popup.
@(private)
popup_list_top :: proc(p: ^Palette, c: ^Choice_Edit, popup: render.Rect, scale: f32) -> f32 {
	top := popup.y + 4 * scale
	if p.settings[c.setting].searchable {top += PALETTE_POPUP_SEARCH * scale}
	return top
}

@(private)
popup_row_at :: proc(p: ^Palette, c: ^Choice_Edit, l: Palette_Layout, x, y: f32) -> int {
	popup := choice_popup_rect(p, c, l)
	if !render.rect_contains(popup, x, y) {return -1}
	top := popup_list_top(p, c, popup, l.scale)
	count := len(p.buffers.matches)
	return choice_list_at(c.list, top, PALETTE_POPUP_ROW * l.scale, y, count, CHOICE_LIST_ROWS)
}

@(private)
popup_search_box :: proc(p: ^Palette, popup: render.Rect, text: ^Text, scale: f32) -> Field_Box {
	return {
		field = &p.buffers.filter, text = text,
		rect = {popup.x + 4 * scale, popup.y + 4 * scale, popup.width - 8 * scale, HEIGHT_TOOLBAR * scale},
		inset = CONTROL_INSET, caret_width = 1, radius = RADIUS_CONTROL, style = .Body, scale = scale,
	}
}

@(private)
text_entry_box :: proc(p: ^Palette, control: render.Rect, text: ^Text, scale: f32) -> Field_Box {
	return {
		field = &p.buffers.field, text = text, rect = control,
		inset = CONTROL_INSET, caret_width = 1, radius = RADIUS_CONTROL, style = .Body, scale = scale,
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
	if !render.rect_contains(target, x, y) {return .None, false}
	setting := p.results[index].setting
	p.selected = index
	#partial switch s.control {
	case .Slider:
		if render.rect_contains(slider_number_rect(control, l.scale), x, y) {return open_text(p, setting), true}
		edit_set(p, nil)
		track := slider_track(control, l.scale)
		number := snap(s, slider_value(s.minimum, s.maximum, (x - track.x) / max(1, track.width)))
		drag_set(p, Slider_Drag{setting, number})
		return .Changed, true
	}
	return control_activate(p, setting), true
}

palette_slider_drag :: proc(p: ^Palette, l: Palette_Layout, x: f32) -> Outcome {
	drag, sliding := &p.drag.(Slider_Drag)
	if !sliding {return .None}
	s := &p.settings[drag.setting]
	track := slider_track(edit_control(p, l, drag.setting), l.scale)
	if track.width <= 0 {return .None}
	number := snap(s, slider_value(s.minimum, s.maximum, (x - track.x) / track.width))
	if number == drag.number {return .None}
	drag.number = number
	return .Changed
}

// Moves what the pointer holds while the left button is down; otherwise the move is a hover.
palette_pointer_move :: proc(
	p: ^Palette,
	l: Palette_Layout,
	text: ^Text,
	x, y: f32,
	held: bool,
) -> Outcome {
	if !held {return palette_mouse_move(p, l, x, y)}
	switch _ in p.drag {
	case Query_Drag:
		return palette_input_drag(p, l, text, x, l.scale)
	case Field_Drag:
		entry, open := p.edit.(Text_Edit)
		if !open {return .None}
		box := text_entry_box(p, edit_control(p, l, entry.setting), text, l.scale)
		return field_move(&p.buffers.field, field_box_offset(box, x), true) == .None ? .None : .Changed
	case Filter_Drag:
		choice, open := &p.edit.(Choice_Edit)
		if !open {return .None}
		box := popup_search_box(p, choice_popup_rect(p, choice, l), text, l.scale)
		return field_move(&p.buffers.filter, field_box_offset(box, x), true) == .None ? .None : .Changed
	case Scrollbar_Drag:
		return palette_scrollbar_drag(p, l, x, y)
	case Slider_Drag:
		return palette_slider_drag(p, l, x)
	}
	return palette_mouse_move(p, l, x, y)
}

// Ends a pointer gesture: a released slider saves the value it shows.
palette_pointer_release :: proc(p: ^Palette) -> Outcome {
	drag := p.drag
	drag_set(p, nil)
	#partial switch d in drag {
	case Scrollbar_Drag:
		return .Changed
	case Slider_Drag:
		return choose_number(p, &p.settings[d.setting], d.number)
	}
	return .None
}

@(private)
popup_wheel :: proc(p: ^Palette, c: ^Choice_Edit, rows: int) -> Outcome {
	moved := choice_list_scroll_to(&c.list, c.list.scroll - rows, len(p.buffers.matches), CHOICE_LIST_ROWS)
	return moved ? .Changed : .None
}

// Mouse presses while a choice list or text entry is open. The second result is false when the
// press should fall through to the palette after the edit ended.
@(private)
edit_press :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, y: f32) -> (Outcome, bool) {
	#partial switch &edit in p.edit {
	case Choice_Edit:
		popup := choice_popup_rect(p, &edit, l)
		if render.rect_contains(popup, x, y) {
			if index := popup_row_at(p, &edit, l, x, y); index >= 0 {
				return popup_choose(p, &edit, index), true
			}
			if text != nil && p.settings[edit.setting].searchable {
				box := popup_search_box(p, popup, text, l.scale)
				if render.rect_contains(box.rect, x, y) {
					_ = field_move(&p.buffers.filter, field_box_offset(box, x), false)
					drag_set(p, Filter_Drag{})
				}
			}
			return .Changed, true
		}
		// A press on the open control closes the list, like the Settings page.
		closing := render.rect_contains(edit_control(p, l, edit.setting), x, y)
		edit_set(p, nil)
		return .Changed, closing
	case Text_Edit:
		control := edit_control(p, l, edit.setting)
		if render.rect_contains(control, x, y) {
			if text != nil {
				box := text_entry_box(p, control, text, l.scale)
				_ = field_move(&p.buffers.field, field_box_offset(box, x), false)
				drag_set(p, Field_Drag{})
			}
			return .Changed, true
		}
		edit_set(p, nil)
		return .Changed, false
	}
	return .None, false
}

// The pointer shape over a setting control or an open edit; ok is false elsewhere.
@(private)
control_pointer :: proc(p: ^Palette, l: Palette_Layout, x, y: f32) -> (platform.Cursor_Shape, bool) {
	if _, sliding := p.drag.(Slider_Drag); sliding {return .Hand, true}
	switch &edit in p.edit {
	case Shortcut_Edit:
		if render.rect_contains(palette_popup_rect(p, l), x, y) {return .Hand, true}
		row, _ := row_rect(p, l, edit.result)
		parts := palette_binding_parts(row, l.scale)
		if render.rect_contains(parts.field, x, y) ||
		   render.rect_contains(parts.positions, x, y) ||
		   render.rect_contains(parts.reset, x, y) {
			return .Hand, true
		}
		return .Arrow, false
	case Choice_Edit:
		popup := choice_popup_rect(p, &edit, l)
		if render.rect_contains(popup, x, y) {
			if popup_row_at(p, &edit, l, x, y) >= 0 {return .Hand, true}
			return y < popup_list_top(p, &edit, popup, l.scale) ? .Text : .Arrow, true
		}
	case Text_Edit:
		if render.rect_contains(edit_control(p, l, edit.setting), x, y) {return .Text, true}
	}
	index := row_at(p, l, x, y)
	s := result_setting(p, index)
	if s == nil {return .Arrow, false}
	if reset_at(p, l, x, y) == index {return .Hand, true}
	if s.control == .None {return .Arrow, false}
	row, _ := row_rect(p, l, index)
	if render.rect_contains(control_rect(s, row, l.scale), x, y) {return .Hand, true}
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
) -> render.Build_Status {
	s := &p.settings[setting]
	scale := l.scale
	control := control_rect(s, row, scale)
	if control.width <= 0 {return .Ok}
	value, label := setting_value(p, s)
	input_text := text_styled(text, .Body)
	baseline := control.y + (control.height - input_text.line_height) / 2 + input_text.ascent
	if entry, typing := p.edit.(Text_Edit); typing && entry.setting == setting {
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
		drag, sliding := p.drag.(Slider_Drag)
		number := sliding && drag.setting == setting ? drag.number : setting_number(p, s)
		slider_draw(list, slider_track(control, scale), slider_fraction(s.minimum, s.maximum, number), theme, scale)
		shown := number_text(s.step > 0 ? s.step : 1, number)
		number_box := slider_number_rect(control, scale)
		width := text_width(&input_text, shown)
		return draw_text(&input_text, list, shown, number_box.x + number_box.width - width, baseline,
			theme.muted, number_box.width)
	case .Choice:
		choice, listing := p.edit.(Choice_Edit)
		box_draw(list, control, theme, listing && choice.setting == setting, scale)
		inset := CONTROL_INSET * scale
		if result := draw_text(&input_text, list, label, control.x + inset, baseline, theme.text,
			max(1, control.width - 2 * inset - (ICON_INDICATOR + SPACE_1) * scale)); result != .Ok {return result}
		chevron := render.Rect {
			control.x + control.width - inset - ICON_INDICATOR * scale,
			control.y,
			ICON_INDICATOR * scale,
			control.height,
		}
		icon_draw(list, .Chevron_Down, chevron, theme.muted, ICON_INDICATOR, scale)
	case .Text:
		box_draw(list, control, theme, false, scale)
		shown, color := value, theme.text
		if shown == "" {shown, color = "Empty", theme.faint}
		return draw_text(&input_text, list, shown, control.x + CONTROL_INSET * scale, baseline, color,
			max(1, control.width - 2 * CONTROL_INSET * scale))
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
) -> render.Build_Status {
	c, listing := &p.edit.(Choice_Edit)
	if !listing {return .Ok}
	popup := choice_popup_rect(p, c, l)
	if popup.width <= 0 {return .Ok}
	scale := l.scale
	if render.push_layer(list, popup) != .None {return .Ok}
	draw_rect(list, {rect = popup, color = theme.pane, radius = RADIUS_OVERLAY * scale})
	draw_rect(list, {rect = popup, color = theme.border, radius = RADIUS_OVERLAY * scale, stroke = scale})
	b := &p.buffers
	if p.settings[c.setting].searchable {
		box := popup_search_box(p, popup, text, scale)
		box_draw(list, box.rect, theme, true, scale)
		if result := field_box_draw(box, list, theme, field_box_baseline(box), true, "Search");
		   result != .Ok {return result}
		if render.push_layer(list, popup) != .None {return .Ok}
	}
	top := popup_list_top(p, c, popup, scale)
	row_height := PALETTE_POPUP_ROW * scale
	item_text := text^
	if len(b.matches) == 0 {
		baseline := top + (row_height - item_text.line_height) / 2 + item_text.ascent
		return draw_text(&item_text, list, "No matches", popup.x + SPACE_3 * scale, baseline, theme.muted)
	}
	current, _ := setting_value(p, &p.settings[c.setting])
	shown := c.list
	for i := shown.scroll; i < len(b.matches) && i < shown.scroll + CHOICE_LIST_ROWS; i += 1 {
		choice := b.matches[i]
		pad := OVERLAY_PADDING * scale
		row := render.Rect {
			popup.x + pad, top + f32(i - shown.scroll) * row_height, popup.width - 2 * pad, row_height,
		}
		if i == shown.index {
			draw_rect(list, {rect = row, color = theme.selection, radius = RADIUS_CONTROL * scale})
		} else if i == c.hover {
			draw_rect(list, {rect = row, color = theme.hover, radius = RADIUS_CONTROL * scale})
		}
		label := b.labels[choice] != "" ? b.labels[choice] : b.choices[choice]
		saved := b.choices[choice] == current
		baseline := row.y + (row.height - item_text.line_height) / 2 + item_text.ascent
		if saved {
			check := render.Rect {
				row.x + row.width - (CONTROL_INSET + ICON_INDICATOR) * scale,
				row.y,
				ICON_INDICATOR * scale,
				row.height,
			}
			icon_draw(list, .Check, check, theme.accent, ICON_INDICATOR, scale)
		}
		inset := CONTROL_INSET * scale
		if result := draw_text(&item_text, list, label, row.x + inset, baseline,
			saved ? theme.text : theme.muted, max(1, row.width - 2 * inset - (ICON_INDICATOR + SPACE_2) * scale));
		   result != .Ok {return result}
	}
	return .Ok
}
