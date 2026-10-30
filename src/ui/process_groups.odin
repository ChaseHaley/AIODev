package ui

import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"

Process_Field :: enum {
	None,
	Group,
	Name,
	Padding,
	Program,
	Add_Program,
	Add_Group,
	Fallback,
}

Process_Parts :: struct {
	handle, expand, remove: render.Rect,
}

editor_process_parts :: proc(row: render.Rect, scale: f32) -> Process_Parts {
	s := scale
	size := min(28 * s, row.width / 4)
	return {
		handle = {row.x + 4 * s, row.y + (row.height - size) / 2, size, size},
		expand = {row.x + size + 8 * s, row.y, max(0, row.width - size * 2 - 16 * s), row.height},
		remove = {row.x + row.width - size - 4 * s, row.y + (row.height - size) / 2, size, size},
	}
}

@(private)
process_key :: proc(id: int, suffix: string = "") -> string {
	return fmt.tprintf("process.group.%d%s", id, suffix)
}

@(private)
process_row_add :: proc(
	p: ^Editor, id: int, field: Process_Field, suffix, title, value: string,
) -> runtime.Allocator_Error {
	kind: Row_Kind = .Text
	if field == .Group {kind = .Process_Group}
	if field == .Add_Group || field == .Add_Program || field == .Fallback {kind = .Action}
	return editor_add(p, {
		key = process_key(id, suffix), title = title, value = value,
		kind = kind, process = id, process_field = field, detail = settings.PADDING_GROUPS_KEY,
	}, "Processes")
}

@(require_results)
editor_process_load :: proc(p: ^Editor, value: string, fallback: int) -> runtime.Allocator_Error {
	p.process_source = strings.clone(value) or_return
	p.process_fallback = fallback
	groups := settings.padding_groups_scan(value)
	for group, more := settings.padding_groups_next(&groups); more;
	    group, more = settings.padding_groups_next(&groups) {
		if !group.valid {continue}
		p.process_next += 1
		id := p.process_next
		process_row_add(p, id, .Group, "", group.name, fmt.tprintf("%d", group.padding)) or_return
		header := &p.rows[len(p.rows) - 1]
		detail := strings.concatenate({settings.PADDING_GROUPS_KEY, " ", group.processes}) or_return
		delete(header.detail)
		header.detail = detail
		process_row_add(p, id, .Name, ".name", "Name", group.name) or_return
		process_row_add(p, id, .Padding, ".padding", "Padding", fmt.tprintf("%d", group.padding)) or_return
		names := settings.Padding_Processes{rest = group.processes}
		index := 0
		for name, has_name := settings.padding_processes_next(&names); has_name;
		    name, has_name = settings.padding_processes_next(&names) {
			index += 1
			process_row_add(p, id, .Program, fmt.tprintf(".program.%d", index), "Program", name) or_return
		}
		process_row_add(p, id, .Add_Program, ".add", "", "+ Add program") or_return
	}
	process_row_add(p, 0, .Add_Group, ".add", "", "+ Add group") or_return
	process_row_add(p, 0, .Fallback, ".fallback", "", "") or_return
	return nil
}

// Rows own the drafts. Capture before switching fields, so a newly inserted program can be filled
// without discarding the name entered just before it. Disk writes still require a valid whole list.
editor_process_capture :: proc(p: ^Editor) -> bool {
	row := editor_row(p)
	if row == nil || row.process == 0 || p.focus != .Control || !text_kind(row.kind) {return true}
	value := field_string(&p.value)
	if value == row.value {return true}
	owned, err := strings.clone(value)
	if err != nil {editor_message(p, "Could not keep the program draft.", true); return false}
	caption: string
	if row.process_field == .Name || row.process_field == .Padding {
		caption, err = strings.clone(value)
		if err != nil {
			delete(owned)
			editor_message(p, "Could not keep the program draft.", true)
			return false
		}
	}
	defer delete(caption)
	delete(row.value)
	row.value = owned
	p.process_dirty = true
	if row.process_field == .Name || row.process_field == .Padding {
		for &header in p.rows {
			if header.process != row.process || header.process_field != .Group {continue}
			if row.process_field == .Name {delete(header.title); header.title = caption}
			else {delete(header.value); header.value = caption}
			caption = ""
			break
		}
	}
	return true
}

@(private)
process_remove_row :: proc(p: ^Editor, index: int) {
	editor_row_destroy(&p.rows[index])
	ordered_remove(&p.rows, index)
}

@(private)
process_select :: proc(p: ^Editor, key: string, focus: bool = false) {
	// Items contain row offsets; discard them before rebuilding after structural row edits.
	clear(&p.items)
	editor_rebuild(p)
	if editor_reveal(p, key) && focus {p.focus = .Control; field_select_all(&p.value)}
}

editor_process_toggle :: proc(p: ^Editor, id: int) {
	if !editor_process_capture(p) {return}
	p.process_expanded = p.process_expanded == id ? 0 : id
	process_select(p, process_key(id))
}

@(private)
process_insert_added :: proc(p: ^Editor, added_at, before: int) {
	if before >= added_at {return}
	row := p.rows[added_at]
	copy(p.rows[before + 1:added_at + 1], p.rows[before:added_at])
	p.rows[before] = row
}

editor_process_activate :: proc(p: ^Editor, row: ^Editor_Row) -> Editor_Outcome {
	id, field := row.process, row.process_field
	if !editor_process_capture(p) {return .Changed}
	#partial switch field {
	case .Group:
		editor_process_toggle(p, id)
	case .Add_Group:
		start := len(p.rows)
		p.process_next += 1
		id = p.process_next
		failed := process_row_add(p, id, .Group, "", "New group", fmt.tprintf("%d", p.process_fallback))
		if failed == nil {failed = process_row_add(p, id, .Name, ".name", "Name", "New group")}
		if failed == nil {
			failed = process_row_add(p, id, .Padding, ".padding", "Padding", fmt.tprintf("%d", p.process_fallback))
		}
		if failed == nil {failed = process_row_add(p, id, .Program, ".program.1", "Program", "")}
		if failed == nil {failed = process_row_add(p, id, .Add_Program, ".add", "", "+ Add program")}
		if failed != nil {
			for len(p.rows) > start {process_remove_row(p, len(p.rows) - 1)}
			editor_message(p, "Could not add a group.", true)
			return .Changed
		}
		before := start
		for candidate, i in p.rows[:start] {if candidate.process_field == .Add_Group {before = i; break}}
		for i in start ..< len(p.rows) {process_insert_added(p, i, before + i - start)}
		p.process_expanded, p.process_dirty = id, true
		process_select(p, process_key(id, ".name"), true)
	case .Add_Program:
		before := len(p.rows)
		for candidate, i in p.rows {
			if candidate.process != id {continue}
			if candidate.process_field == .Add_Program {before = i}
		}
		// The serial is independent of the visible count, so removing a program never reuses a key.
		p.process_next_program += 1
		key := fmt.tprintf(".program.new%d", p.process_next_program)
		if process_row_add(p, id, .Program, key, "Program", "") != nil {
			editor_message(p, "Could not add a program.", true)
			return .Changed
		}
		process_insert_added(p, len(p.rows) - 1, before)
		p.process_dirty = true
		process_select(p, process_key(id, key), true)
	case:
	}
	return .Changed
}

editor_process_program_remove :: proc(p: ^Editor, key: string) -> Editor_Outcome {
	if !editor_process_capture(p) {return .Changed}
	for row, index in p.rows {
		if row.key != key {continue}
		id := row.process
		process_remove_row(p, index)
		p.process_dirty = true
		process_select(p, process_key(id, ".add"))
		return .Process_Save
	}
	return .Changed
}

editor_process_group_remove :: proc(p: ^Editor, id: int) {
	for index := len(p.rows) - 1; index >= 0; index -= 1 {
		if p.rows[index].process == id {process_remove_row(p, index)}
	}
	p.process_dirty = true
	if p.process_expanded == id {p.process_expanded = 0}
	process_select(p, process_key(0, ".add"))
}

// Moves one whole block, including hidden fields, without reallocating any of its strings.
editor_process_move :: proc(p: ^Editor, id, slot: int) {
	if !editor_process_capture(p) {return}
	ordered := make([dynamic]Editor_Row, 0, len(p.rows), context.temp_allocator)
	headers := make([dynamic]int, context.temp_allocator)
	for row in p.rows {if row.process_field == .Group && row.process != id {append(&headers, row.process)}}
	at := clamp(slot, 0, len(headers))
	for i in 0 ..= len(headers) {
		if i == at {for row in p.rows {if row.process == id {append(&ordered, row)}}}
		if i < len(headers) {for row in p.rows {if row.process == headers[i] {append(&ordered, row)}}}
	}
	index := 0
	for &row in p.rows {if row.process > 0 {row = ordered[index]; index += 1}}
	p.process_dirty = true
	process_select(p, process_key(id))
}

// Serializes staged fields through the existing grammar. Empty/invalid drafts never reach disk.
@(require_results)
editor_process_value :: proc(p: ^Editor) -> (value, problem: string) {
	if !editor_process_capture(p) {return "", "Could not keep the program draft."}
	builder := strings.builder_make(context.temp_allocator)
	first := true
	for header in p.rows {
		if header.process_field != .Group {continue}
		name, padding: string
		programs := make([dynamic]string, context.temp_allocator)
		for row in p.rows {
			if row.process != header.process {continue}
			#partial switch row.process_field {
			case .Name: name = strings.trim_space(row.value)
			case .Padding: padding = strings.trim_space(row.value)
			case .Program:
				program := strings.trim_space(row.value)
				if program == "" || strings.contains_any(program, ",;:/\\*?\"\r\n") {
					return "", "Enter one executable name per program."
				}
				for other in programs {
					if strings.equal_fold(settings.executable_stem(other), settings.executable_stem(program)) {
						return "", "This program is already in the group."
					}
				}
				append(&programs, program)
			case:
			}
		}
		if name == "" || strings.contains_any(name, ":;\r\n") {return "", "Enter a group name without : or ;."}
		number, ok := strconv.parse_int(padding)
		if !ok || number < 0 || number > 1024 {return "", "Padding must be a whole number from 0 to 1024."}
		if len(programs) == 0 {return "", "Add a program or delete the group."}
		if !first {strings.write_byte(&builder, ';')}
		first = false
		strings.write_string(&builder, fmt.tprintf("%s:%d:%s", name, number,
			strings.join(programs[:], ",", context.temp_allocator)))
	}
	return strings.to_string(builder), ""
}

// Publication can refresh other settings while keeping the complete unsaved process list.
@(require_results)
editor_process_copy_draft :: proc(from, to: ^Editor) -> runtime.Allocator_Error {
	for index := len(to.rows) - 1; index >= 0; index -= 1 {
		if to.rows[index].process_field != .None {process_remove_row(to, index)}
	}
	for row in from.rows {
		if row.process_field == .None {continue}
		editor_add(to, row, "Processes") or_return
	}
	to.process_next, to.process_next_program = from.process_next, from.process_next_program
	to.process_expanded, to.process_dirty = from.process_expanded, from.process_dirty
	return nil
}

editor_process_field_parts :: proc(row: ^Editor_Row, parts: Row_Parts, scale: f32) -> Row_Parts {
	result := parts
	s, r := scale, parts.row
	result.reset, result.slider = {}, {}
	if row.process_field == .Group || row.process_field == .Fallback {return result}
	left := min(r.x + 120 * s, r.x + r.width * 0.38)
	right := r.x + r.width - 40 * s
	width := max(0, right - left)
	if row.process_field == .Padding {width = min(width, 90 * s)}
	result.field = {left, r.y + (r.height - 30 * s) / 2, width, 30 * s}
	result.text_right = left - 8 * s
	if row.process_field == .Program {
		result.clear = {r.x + r.width - 32 * s, r.y + (r.height - 26 * s) / 2, 26 * s, 26 * s}
	}
	if row.process_field == .Add_Group || row.process_field == .Add_Program {
		result.field = {r.x + 36 * s, r.y + (r.height - 30 * s) / 2, min(140 * s, r.width - 40 * s), 30 * s}
	}
	return result
}

editor_process_key :: proc(
	p: ^Editor, row: ^Editor_Row, e: platform.Key_Event,
) -> (Editor_Outcome, bool) {
	if p.drag == .Process_Order && e.key == .Escape {p.drag = .None; return .Changed, true}
	if row == nil || row.kind != .Process_Group {return .None, false}
	if .Control in e.modifiers && (e.key == .Arrow_Up || e.key == .Arrow_Down) {
		if !editor_process_orderable(p) {return .Changed, true}
		slot, count := 0, 0
		for candidate in p.rows {
			if candidate.process_field != .Group {continue}
			if candidate.process == row.process {slot = count}
			count += 1
		}
		editor_process_move(p, row.process, clamp(slot + (e.key == .Arrow_Up ? -1 : 1), 0, count - 1))
		return .Process_Save, true
	}
	#partial switch e.key {
	case .Enter, .Numpad_Enter:
		editor_process_toggle(p, row.process)
		return .Changed, true
	case .Arrow_Right:
		if p.process_expanded != row.process {editor_process_toggle(p, row.process)}
		return .Changed, true
	case .Arrow_Left:
		if p.process_expanded == row.process {editor_process_toggle(p, row.process)}
		return .Changed, true
	case .Delete:
		if p.focus == .Control {
			p.process_remove = row.process
			return .Process_Remove, true
		}
	}
	return .None, false
}

editor_process_press :: proc(
	p: ^Editor, row: ^Editor_Row, parts: Row_Parts, x, y, scale: f32,
) -> (Editor_Outcome, bool) {
	if row.kind == .Process_Group {
		cells := editor_process_parts(parts.row, scale)
		if contains(cells.handle, x, y) {
			if !editor_process_orderable(p) {return .Changed, true}
			p.process_drag_id = row.process
			p.process_drag_from = 0
			for candidate in p.rows {
				if candidate.process_field != .Group {continue}
				if candidate.process == row.process {break}
				p.process_drag_from += 1
			}
			p.drag, p.drag_target = .Process_Order, p.process_drag_from
			return .Changed, true
		}
		if contains(cells.remove, x, y) {
			p.process_remove = row.process
			return .Process_Remove, true
		}
		editor_process_toggle(p, row.process)
		return .Changed, true
	}
	if row.process_field == .Program && contains(parts.clear, x, y) {
		return editor_process_program_remove(p, row.key), true
	}
	if row.process_field == .Fallback {return .Changed, true}
	return .None, false
}

editor_process_orderable :: proc(p: ^Editor) -> bool {
	total, visible := 0, 0
	for row in p.rows {if row.process_field == .Group {total += 1}}
	for item in p.items {
		if item.row >= 0 && p.rows[item.row].process_field == .Group {visible += 1}
	}
	return total == visible
}

editor_process_drag :: proc(p: ^Editor, l: Editor_Layout, x, y: f32) -> bool {
	previous := p.drag_target
	p.drag_target = -1
	if !contains(l.list, x, y) {return previous != -1}
	slot := 0
	for item, index in p.items {
		if item.row < 0 || p.rows[item.row].process_field != .Group {continue}
		top := l.list.y + f32(index - p.scroll) * l.row_height
		if y < top + l.row_height / 2 {break}
		slot += 1
	}
	p.drag_target = slot
	return previous != slot
}

editor_process_drag_draw :: proc(p: ^Editor, l: Editor_Layout, list: ^render.Draw_List, theme: Theme) {
	if p.drag_target < 0 {return}
	slot := 0
	y := l.list.y
	for item, index in p.items {
		if item.row < 0 || p.rows[item.row].process_field != .Group {continue}
		y = l.list.y + f32(index - p.scroll) * l.row_height
		if slot == p.drag_target {break}
		y += l.row_height
		slot += 1
	}
	draw_rect(list, {rect = {l.list.x + 8 * l.scale, y - l.scale,
		l.list.width - 16 * l.scale, 2 * l.scale}, color = theme.accent})
}

editor_process_draw :: proc(
	p: ^Editor, row: ^Editor_Row, parts: Row_Parts, selected: bool,
	list: ^render.Draw_List, text: ^Text, theme: Theme, scale: f32,
) -> glyphs.Result {
	s, r := scale, parts.row
	baseline := r.y + (r.height - text.line_height) / 2 + text.ascent
	buffer: [128]u8
	if row.process_field == .Fallback {
		return draw_text(text, list, fmt.bprintf(buffer[:], "Other programs use Content Padding · %d DIP.",
			p.process_fallback), r.x + 12 * s, baseline, theme.muted, max(1, r.width - 24 * s))
	}
	if row.process_field == .Group {
		cells := editor_process_parts(r, s)
		profile_grip_draw(list, cells.handle, theme, s, selected || p.drag == .Process_Order)
		if result := draw_icon(text, list, ICON_TRASH, cells.remove, theme.muted, 0.9); result != .Ok {
			return result
		}
		chevron := render.Rect{cells.remove.x - 26 * s, r.y + (r.height - 26 * s) / 2, 24 * s, 26 * s}
		if result := draw_icon(text, list,
			p.process_expanded == row.process ? ICON_CHEVRON_DOWN : ICON_CHEVRON_RIGHT,
			chevron, theme.muted, 0.8); result != .Ok {return result}
		amount := fmt.bprintf(buffer[:], "%s DIP", row.value)
		x := chevron.x - 8 * s - text_width(text, amount)
		if result := draw_text(text, list, amount, x, baseline, theme.muted, max(1, chevron.x - x));
		   result != .Ok {return result}
		return draw_text(text, list, row.title, cells.expand.x, baseline, theme.text,
			max(1, x - cells.expand.x - 12 * s))
	}
	if row.process_field != .Add_Group && row.process_field != .Add_Program {
		label := row.title
		if row.process_field == .Program {
			label = "Programs"
			for candidate in p.rows {
				if candidate.process != row.process || candidate.process_field != .Program {continue}
				if candidate.key != row.key {label = ""}
				break
			}
		}
		if result := draw_text(text, list, label, r.x + 36 * s, baseline, theme.text,
			max(1, parts.text_right - r.x - 36 * s)); result != .Ok {return result}
	}
	if row.process_field == .Program {
		if result := draw_icon(text, list, ICON_CLEAR, parts.clear, theme.muted, 0.8); result != .Ok {
			return result
		}
	}
	return control_draw(p, row, parts, selected, list, text, theme, r, scale)
}
