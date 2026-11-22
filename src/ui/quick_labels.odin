package ui

import "cosmos:colour"
import "cosmos:input"
import "cosmos:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

QUICK_LABEL_ADD_KEY :: "label.add"
QUICK_LABEL_RESET_KEY :: "label.reset"

// The labels Alt+1 to Alt+9 apply: the first nine, in order.
QUICK_LABEL_HOTKEYS :: 9

// The field of a label a row edits.
Label_Field :: enum u8 {
	None,
	Name,
	Color,
	Instruction,
}

// The quick label table's state on the settings page: the one label whose fields are open, counted
// from 1 in page order. Zero is none. Rows own the label text, and every committed edit rebuilds
// the whole setting from them, so the table keeps no draft.
Quick_Label_State :: struct {
	label_expanded: int,
}

// A change to the label list the page owner saves as the whole setting.
Label_Edit_Kind :: enum u8 {
	// `key` names a field row; `value` is its new text.
	Field,
	Add,
	Reset,
	Remove,
	// Moves label `id` into the gap before `slot`, counted among the labels before the move.
	Move,
}

Label_Edit :: struct {
	kind:      Label_Edit_Kind,
	id, slot:  int,
	key, value: string,
}

@(private)
LABEL_SWATCH :: f32(14)
@(private)
LABEL_PRESET_STRIP :: f32(36)

@(require_results)
label_key :: proc(id: int, suffix: string = "") -> string {
	return fmt.tprintf("label.%d%s", id, suffix)
}

@(private, require_results)
label_row_add :: proc(
	p: ^Editor,
	id: int,
	field: Label_Field,
	title, value, description: string,
) -> runtime.Allocator_Error {
	suffix := ""
	kind := Row_Kind.Text
	switch field {
	case .None:
		kind = .Quick_Label
	case .Name:
		suffix = ".name"
	case .Color:
		suffix, kind = ".color", .Color
	case .Instruction:
		suffix = ".instruction"
	}
	return editor_add(
		p,
		{
			key = label_key(id, suffix),
			title = title,
			value = value,
			default_value = value,
			description = description,
			kind = kind,
			label = id,
			label_field = field,
			detail = settings.QUICK_LABELS_KEY,
		},
		settings.group_title(settings.QUICK_LABELS_KEY),
	)
}

// Adds a table line and its three field rows per label, then the Add label and Reset labels rows.
@(require_results)
editor_quick_labels_load :: proc(p: ^Editor, value: string) -> runtime.Allocator_Error {
	cursor := settings.quick_labels_scan(value)
	id := 0
	next := settings.quick_labels_next
	for label, more := next(&cursor); more; label, more = next(&cursor) {
		id += 1
		label_row_add(p, id, .None, label.name, label.colour, "") or_return
		head := &p.rows[len(p.rows) - 1]
		// Search reads the instruction too, so a label is found by what it tells the agent.
		detail := strings.concatenate({settings.QUICK_LABELS_KEY, " ", label.instruction}) or_return
		delete(head.detail)
		head.detail = detail
		label_row_add(p, id, .Name, "Name", label.name, "Shown on the label and in the toolbar.") or_return
		label_row_add(
			p,
			id,
			.Color,
			"Color",
			label.colour,
			"A preset follows the theme; the wheel or a hex value picks any other color.",
		) or_return
		label_row_add(
			p,
			id,
			.Instruction,
			"Instruction",
			label.instruction,
			"Sent to the agent with the label. Optional.",
		) or_return
	}
	group := settings.group_title(settings.QUICK_LABELS_KEY)
	editor_add(
		p,
		{
			key = QUICK_LABEL_ADD_KEY,
			title = "Add label",
			description = "The first nine labels take Alt+1 to Alt+9 in order.",
			value = "Add label",
			kind = .Action,
			action = .Label_Add,
			detail = settings.QUICK_LABELS_KEY,
		},
		group,
	) or_return
	return editor_add(
		p,
		{
			key = QUICK_LABEL_RESET_KEY,
			title = "Reset labels",
			description = "Return the labels, their colors and instructions to the defaults.",
			value = "Reset",
			kind = .Action,
			action = .Label_Reset,
			detail = settings.QUICK_LABELS_KEY,
		},
		group,
	)
}

@(private)
editor_has_label_row :: proc(p: ^Editor, id: int) -> bool {
	for row in p.rows {
		if row.kind == .Quick_Label && row.label == id {return true}
	}
	return false
}

// What the user is told when a label field cannot be stored.
@(private)
quick_label_problem_text :: proc(problem: settings.Quick_Label_Problem) -> string {
	switch problem {
	case .Name:
		return "Enter a label name without ; or |."
	case .Colour:
		return "Use a preset color name or a hex color such as #2ea043."
	case .Instruction:
		return "The instruction cannot contain ; or |."
	case .Too_Long:
		return "The labels are too long to store."
	}
	return ""
}

// The setting text after `edit`, read from the page's rows, and the row to show afterwards. Moving,
// adding and removing also move the open label with its block, since a reload numbers labels by
// position. A problem is the message for a field the setting cannot hold; nothing is saved then.
// A `kept` field is one the user typed into and left without Enter. Its key names a position, which
// this edit may renumber, so it is applied to the rows here, before the edit, or dropped with its
// label or a reset, instead of being saved afterwards under whatever label took the position.
@(require_results)
editor_quick_labels_value :: proc(
	p: ^Editor,
	edit: Label_Edit,
	kept: Editor_Kept = {},
) -> (
	value, select_key, problem: string,
) {
	if edit.kind == .Reset {
		p.label_expanded = 0
		return settings.QUICK_LABELS_DEFAULT, QUICK_LABEL_RESET_KEY, ""
	}
	kept_label := 0
	if kept.key != "" {
		for row in p.rows {
			if row.key == kept.key && row.label_field != .None {kept_label = row.label}
		}
	}
	if edit.kind == .Remove && edit.id == kept_label {kept_label = 0}
	drafts := make([dynamic]settings.Quick_Label_Draft, context.temp_allocator)
	for head in p.rows {
		if head.kind != .Quick_Label {continue}
		draft: settings.Quick_Label_Draft
		for row in p.rows {
			if row.label != head.label || row.label_field == .None {continue}
			text := row.value
			if kept_label != 0 && row.key == kept.key {text = kept.value}
			if edit.kind == .Field && row.key == edit.key {text = edit.value}
			switch row.label_field {
			case .None:
			case .Name:
				draft.name = text
			case .Color:
				draft.colour = text
			case .Instruction:
				draft.instruction = text
			}
		}
		append(&drafts, draft)
	}
	select_key = edit.key
	count := len(drafts)
	switch edit.kind {
	case .Field, .Reset:
	case .Add:
		presets := settings.QUICK_LABEL_PRESETS
		append(&drafts, settings.Quick_Label_Draft{"New label", presets[count % len(presets)], ""})
		p.label_expanded = count + 1
		select_key = label_key(count + 1, ".name")
	case .Remove:
		if edit.id >= 1 && edit.id <= count {
			ordered_remove(&drafts, edit.id - 1)
			if p.label_expanded == edit.id {p.label_expanded = 0}
			else if p.label_expanded > edit.id {p.label_expanded -= 1}
		}
		select_key = QUICK_LABEL_ADD_KEY
	case .Move:
		from := edit.id - 1
		slot := edit.slot > from ? edit.slot - 1 : edit.slot
		select_key = label_key(edit.id)
		if from >= 0 && from < count && slot >= 0 && slot < count && slot != from {
			moved := drafts[from]
			ordered_remove(&drafts, from)
			inject_at(&drafts, slot, moved)
			// A reload numbers labels by position, so the open label and the blocks still easing into
			// place are renumbered to follow their label.
			if p.label_expanded > 0 {
				p.label_expanded = label_index_after_move(p.label_expanded - 1, from, slot) + 1
			}
			select_key = label_key(slot + 1)
			label_positions_follow(p, from, slot)
		}
	}
	text, refusal, err := settings.quick_labels_text(drafts[:], context.temp_allocator)
	if err != nil {return "", "", "Could not keep the label edit."}
	if refused, has_problem := refusal.?; has_problem {return "", "", quick_label_problem_text(refused)}
	return text, select_key, ""
}

// Whether `kept` is the text of one of the label page's fields.
@(require_results)
editor_kept_is_label :: proc(p: ^Editor, kept: Editor_Kept) -> bool {
	if kept.key == "" {return false}
	for row in p.rows {
		if row.key == kept.key {return row.label_field != .None}
	}
	return false
}

// Puts the page state `editor_quick_labels_value` changed for `edit` back, after the setting it
// built was not saved: the open label as it was (`expanded`) and the blocks' drawn positions.
editor_quick_labels_undo :: proc(p: ^Editor, edit: Label_Edit, expanded: int) {
	p.label_expanded = expanded
	if edit.kind != .Move {return}
	count := 0
	for row in p.rows {
		if row.kind == .Quick_Label {count += 1}
	}
	from := edit.id - 1
	slot := edit.slot > from ? edit.slot - 1 : edit.slot
	if from >= 0 && from < count && slot >= 0 && slot < count && slot != from {
		label_positions_follow(p, slot, from)
	}
}

// Where the label that was at `old` is after the label at `from` moved to `slot`.
@(private)
label_index_after_move :: proc(old, from, slot: int) -> int {
	switch {
	case old == from:
		return slot
	case from < slot && old > from && old <= slot:
		return old - 1
	case from > slot && old >= slot && old < from:
		return old + 1
	}
	return old
}

// Renames the drawn positions of label blocks after a move, so the blocks keep easing from where
// they are drawn when the reload gives them new keys.
@(private)
label_positions_follow :: proc(p: ^Editor, from, slot: int) {
	for &entry in p.profile_positions {
		number, ok := strconv.parse_int(strings.trim_prefix(entry.id, "label."))
		if !ok || !strings.has_prefix(entry.id, "label.") {continue}
		renamed, err := strings.clone(label_key(label_index_after_move(number - 1, from, slot) + 1))
		if err != nil {continue}
		delete(entry.id)
		entry.id = renamed
	}
}

// Opens or closes one label's fields, closing any other, and selects its table line.
editor_label_toggle :: proc(p: ^Editor, id: int) {
	p.label_expanded = p.label_expanded == id ? 0 : id
	editor_rebuild(p)
	for item, index in p.items {
		if item.row < 0 {continue}
		row := &p.rows[item.row]
		if row.kind == .Quick_Label && row.label == id {editor_select(p, index); return}
	}
}

// Keys on a label's table line: Enter or Right and Left open and close its fields, Delete from the
// line's controls removes it, and Ctrl+Up or Down moves it one place.
editor_label_key :: proc(p: ^Editor, row: ^Editor_Row, e: input.Key_Event) -> (Editor_Outcome, bool) {
	if row == nil || row.kind != .Quick_Label {return .None, false}
	if .Control in e.modifiers && (e.key == .Arrow_Up || e.key == .Arrow_Down) {
		// Search hides lines, so a move could not show where the label lands.
		if filtering(p) {return .Changed, true}
		count := 0
		for candidate in p.rows {if candidate.kind == .Quick_Label {count += 1}}
		from := row.label - 1
		slot := e.key == .Arrow_Up ? from - 1 : from + 2
		if slot < 0 || slot > count {return .Changed, true}
		editor_request_set(p, Label_Edit{kind = .Move, id = row.label, slot = slot})
		return .Label_Action, true
	}
	#partial switch e.key {
	case .Enter, .Numpad_Enter:
		editor_label_toggle(p, row.label)
		return .Changed, true
	case .Arrow_Right:
		if p.label_expanded != row.label {editor_label_toggle(p, row.label)}
		return .Changed, true
	case .Arrow_Left:
		if p.label_expanded == row.label {editor_label_toggle(p, row.label)}
		return .Changed, true
	case .Delete:
		if editor_editing(p) {
			editor_request_set(p, Label_Edit{kind = .Remove, id = row.label})
			return .Label_Action, true
		}
	}
	return .None, false
}

// A press on a label's table line: the grip starts a reorder drag, the trash removes it, and the
// rest opens or closes its fields.
@(private)
editor_label_press :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	index: int,
	x, y, scale: f32,
) -> Editor_Outcome {
	cells := editor_block_parts(parts.row, scale)
	if render.rect_contains(cells.handle, x, y) {
		if filtering(p) {return .Changed}
		grab := (y - parts.row.y) / parts.row.height
		order_begin(p, Order_Label{row.label}, block_index_at(p, index, .Quick_Labels), grab)
		return .Changed
	}
	if render.rect_contains(cells.remove, x, y) {
		editor_mode_set(p, Editor_Editing{})
		editor_request_set(p, Label_Edit{kind = .Remove, id = row.label})
		return .Label_Action
	}
	editor_label_toggle(p, row.label)
	return .Changed
}

// A label's table line: the grip, its colour dot, its name, its Alt+N keycap while it has one, the
// chevron of its fields and remove.
@(private)
editor_label_draw :: proc(
	p: ^Editor,
	row: ^Editor_Row,
	parts: Row_Parts,
	selected: bool,
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	pointer: [2]f32,
	scale: f32,
) -> render.Build_Status {
	s, r := scale, parts.row
	cells := editor_block_parts(r, s)
	small := text_styled(text, .Detail)
	grip_ink := selected || editor_order_dragging(p, .Quick_Labels) ? theme.muted : theme.faint
	icon_draw(list, .Grip, cells.handle, grip_ink, ICON_BUTTON, s)
	remove_hovered := editor_row_control_hovered(p, row, cells.remove, pointer)
	if table_button_draw(list, cells.remove, .Trash, ICON_BUTTON, theme, s, false, remove_hovered, selected,
		   pointer) != .None {return .Ok}
	chevron := render.Rect{cells.remove.x - HEIGHT_COMPACT * s, r.y, HEIGHT_COMPACT * s, r.height}
	expanded := p.label_expanded == row.label
	icon_draw(list, expanded ? .Chevron_Down : .Chevron_Right, chevron, theme.muted, ICON_INDICATOR, s)
	right := chevron.x - SPACE_2 * s
	if row.label <= QUICK_LABEL_HOTKEYS {
		buffer: [8]u8
		label := fmt.bprintf(buffer[:], "Alt+%d", row.label)
		right -= keycap_width(&small, label, s)
		if result := keycap_draw(list, &small, theme, label, right, r.y, r.height, s); result != .Ok {
			return result
		}
		right -= SPACE_3 * s
	}
	size := LABEL_SWATCH * s
	dot := render.Rect{cells.expand.x, r.y + (r.height - size) / 2, size, size}
	draw_rect(list, {rect = dot, color = quick_label_color(theme, row.value), radius = RADIUS_CONTROL * s})
	x := dot.x + size + SPACE_3 * s
	baseline := r.y + (r.height - text.line_height) / 2 + text.ascent
	return draw_text(text, list, row.title, x, baseline, theme.text, max(1, right - x))
}

// The swatch beside a colour row's field: a label's colour resolves its preset names against the
// theme; every other row shows what its text parses to.
@(private)
row_swatch_color :: proc(theme: Theme, row: ^Editor_Row, value: string) -> (render.Color, bool) {
	if row.label_field == .Color {return quick_label_color(theme, strings.trim_space(value)), true}
	return swatch_color(value)
}

// The colour a label's text names, as the hex text the picker's swatch reads.
@(private)
quick_label_hex :: proc(theme: Theme, value: string) -> string {
	c := quick_label_color(theme, strings.trim_space(value))
	channel :: proc(v: f32) -> u8 {return u8(clamp(v, 0, 1) * 255 + 0.5)}
	buffer := make([]u8, colour.HEX_LENGTH, context.temp_allocator)
	return colour.format({channel(c.r), channel(c.g), channel(c.b)}, buffer)
}

@(private)
color_popup_height :: proc(row: ^Editor_Row) -> f32 {
	if row.label_field == .Color {return 166 + LABEL_PRESET_STRIP}
	return row.kind == .Optional_Color ? 206 : 166
}

// The picker's parts for `row`: a label's colour adds a strip of presets above the wheel and moves
// the rest down.
@(private)
editor_color_parts :: proc(row: ^Editor_Row, popup: render.Rect, scale: f32) -> Color_Parts {
	c := color_parts(popup, row.kind == .Optional_Color, scale)
	if row.label_field != .Color {return c}
	shift := LABEL_PRESET_STRIP * scale
	c.wheel.y += shift
	c.ramp.y += shift
	c.swatch.y += shift
	c.presets = {popup.x + 12 * scale, popup.y + 12 * scale, 268 * scale, 24 * scale}
	return c
}

// A preset chip is a circle as tall as the strip, spread evenly across its width.
@(private)
label_preset_rect :: proc(strip: render.Rect, index: int) -> render.Rect {
	count := len(settings.QUICK_LABEL_PRESETS)
	step := (strip.width - strip.height) / f32(count - 1)
	return {strip.x + step * f32(index), strip.y, strip.height, strip.height}
}

// The preset name under a point of a label's colour popup, or "".
@(private)
label_preset_at :: proc(c: Color_Parts, row: ^Editor_Row, x, y: f32) -> string {
	if row.label_field != .Color || c.presets.width == 0 {return ""}
	presets := settings.QUICK_LABEL_PRESETS
	for preset, i in presets {
		if render.rect_contains(label_preset_rect(c.presets, i), x, y) {return preset}
	}
	return ""
}

@(private)
label_presets_draw :: proc(list: ^render.Draw_List, theme: Theme, strip: render.Rect, value: string, s: f32) {
	presets := settings.QUICK_LABEL_PRESETS
	chosen := strings.trim_space(value)
	for preset, i in presets {
		slot := label_preset_rect(strip, i)
		chip := render.Rect{slot.x + 2 * s, slot.y + 2 * s, slot.width - 4 * s, slot.height - 4 * s}
		draw_rect(list, {rect = chip, color = quick_label_color(theme, preset), radius = RADIUS_CONTROL * s})
		if preset == chosen {
			draw_rect(list, {rect = slot, color = theme.text, radius = RADIUS_CONTROL * s, stroke = 2 * s})
		}
	}
}
