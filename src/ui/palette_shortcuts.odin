package ui

import "aio:commands"
import "aio:glyphs"
import "aio:platform"
import "aio:render"
import "core:fmt"

// Match the Settings shortcut row so capture, physical positions and its popup share geometry.
palette_binding_parts :: proc(row: render.Rect, scale: f32) -> Row_Parts {
	s := scale
	parts := Row_Parts {
		row = row, reset = reset_slot(row, s),
	}
	shortcut_parts(&parts, s, true)
	return parts
}

// The single embedded Settings row sits exactly over the selected palette command.
palette_binding_layout :: proc(p: ^Palette, l: Palette_Layout) -> Editor_Layout {
	row, _ := row_rect(p, l, p.binding_result)
	return {
		page = l.viewport, list = {row.x, row.y - l.row_height, row.width, 2 * l.row_height},
		row_height = l.row_height, scale = l.scale, rows = 2,
	}
}

palette_binding_open :: proc(p: ^Palette, index: int) -> Outcome {
	if index < 0 || index >= len(p.results) || p.results[index].command == nil {return .None}
	command := p.results[index].command
	palette_edit_cancel(p)
	value := commands.shortcut_set_text(command.shortcuts, context.temp_allocator)
	defaults := commands.shortcut_set_text(command.defaults, context.temp_allocator)
	if editor_add(&p.binding, {
		key = fmt.tprintf("keys.%s", command.name), title = command.title,
		value = value, default_value = defaults, kind = .Shortcut,
	}, "Shortcuts") != nil {
		editor_destroy(&p.binding)
		return .None
	}
	editor_filter(&p.binding)
	editor_select_key(&p.binding, p.binding.rows[0].key)
	p.binding.leader = p.leader
	p.binding.visible_rows = 2
	p.binding.scroll = 0
	p.selected, p.binding_result = index, index
	p.edit.kind = .Shortcut
	open_shortcuts(&p.binding)
	return .Changed
}

palette_binding_outcome :: proc(p: ^Palette, outcome: Editor_Outcome) -> Outcome {
	if outcome == .Save || outcome == .Reset {
		row := editor_row(&p.binding)
		value := outcome == .Reset ? row.default_value : field_string(&p.binding.value)
		clear(&p.chosen_key)
		append(&p.chosen_key, row.key)
		p.chosen = string(p.chosen_key[:])
		clear(&p.chosen_value)
		append(&p.chosen_value, value)
		return .Set_Setting
	}
	b := &p.binding
	if editor_popup(b) == .None && !editor_capturing(b) && editor_focus(b) != .Positions {
		palette_edit_cancel(p)
	}
	return .Changed
}

// Keep a refused binding available to correct; saving ends only the inline editor.
palette_binding_saved :: proc(p: ^Palette, saved: bool) {
	if p.edit.kind != .Shortcut {return}
	if saved {palette_edit_cancel(p)} else {
		editor_mode_set(&p.binding, Editor_Capturing{})
	}
}

palette_binding_key :: proc(p: ^Palette, e: platform.Key_Event) -> Outcome {
	return palette_binding_outcome(p, editor_key(&p.binding, e))
}

palette_binding_reset :: proc(p: ^Palette, index: int) -> Outcome {
	if index < 0 || index >= len(p.results) || p.results[index].command == nil {return .None}
	p.selected = index
	if !palette_binding_modified(p.results[index].command) {return .Changed}
	if palette_binding_open(p, index) == .None {return .None}
	return palette_binding_outcome(p, .Reset)
}

palette_binding_press :: proc(p: ^Palette, l: Palette_Layout, text: ^Text, x, y: f32) -> Outcome {
	layout := palette_binding_layout(p, l)
	row, _ := row_rect(p, l, p.binding_result)
	parts := palette_binding_parts(row, l.scale)
	if editor_popup(&p.binding) != .None && contains(editor_popup_rect(&p.binding, layout), x, y) {
		return palette_binding_outcome(p, editor_press(&p.binding, layout, text, x, y, false))
	}
	if contains(parts.reset, x, y) {return palette_binding_outcome(p, .Reset)}
	if editor_popup(&p.binding) == .None && contains(parts.positions, x, y) {
		p.binding.physical = !p.binding.physical
		return .Changed
	}
	if contains(parts.field, x, y) {
		open_shortcuts(&p.binding)
		return .Changed
	}
	palette_edit_cancel(p)
	return .Changed
}

@(private)
palette_binding_modified :: proc(command: ^commands.Command) -> bool {
	modified := command.shortcuts.count != command.defaults.count
	if !modified {
		for shortcut, i in command.shortcuts.items[:command.shortcuts.count] {
			default := command.defaults.items[i]
			modified ||= shortcut.key != default.key || shortcut.modifiers != default.modifiers
		}
	}
	return modified
}

palette_binding_draw :: proc(
	p: ^Palette, command: ^commands.Command, index: int, row: render.Rect,
	list: ^render.Draw_List, text: ^Text, theme: Theme, l: Palette_Layout, pointer: [2]f32,
) -> glyphs.Result {
	parts := palette_binding_parts(row, l.scale)
	modified := palette_binding_modified(command)
	_ = reset_button_draw(list, theme, parts.reset, modified, contains(parts.reset, pointer.x, pointer.y),
	                      index == p.selected, pointer, l.scale)
	if p.edit.kind == .Shortcut && p.binding_result == index {
		if editor_popup(&p.binding) != .None {parts.positions = {}}
		result := control_draw(&p.binding, editor_row(&p.binding), parts, true, list, text, theme,
		                       l.viewport, l.scale)
		_ = render.push_layer(list, l.list)
		return result
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	summary := Shortcut_Summary{additional = max(0, command.shortcuts.count - 1)}
	if shortcuts := commands.active_shortcuts(command); len(shortcuts) > 0 {
		summary.first = commands.shortcut_text(shortcuts[0], buffer[:])
	}
	parts.positions = {}
	result := shortcut_field_draw(list, text, theme, parts, summary,
	                              {focused = contains(parts.field, pointer.x, pointer.y)}, l.viewport, l.scale)
	_ = render.push_layer(list, l.list)
	return result
}
