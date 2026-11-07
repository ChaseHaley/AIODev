package ui

import "aio:commands"
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

// The single embedded Settings row sits exactly over palette result `result`.
@(private)
palette_binding_layout :: proc(p: ^Palette, l: Palette_Layout, result: int) -> Editor_Layout {
	row, _ := row_rect(p, l, result)
	return {
		page = l.viewport, list = {row.x, row.y - l.row_height, row.width, 2 * l.row_height},
		row_height = l.row_height, scale = l.scale, rows = 2,
	}
}

palette_binding_open :: proc(p: ^Palette, index: int) -> Outcome {
	if index < 0 || index >= len(p.results) || p.results[index].command == nil {return .None}
	command := p.results[index].command
	edit_set(p, nil)
	value := commands.shortcut_set_text(command.shortcuts, context.temp_allocator)
	defaults := commands.shortcut_set_text(command.defaults, context.temp_allocator)
	binding: Editor
	if editor_add(&binding, {
		key = fmt.tprintf("keys.%s", command.name), title = command.title,
		value = value, default_value = defaults, kind = .Shortcut,
	}, "Shortcuts") != nil {
		editor_destroy(&binding)
		return .None
	}
	editor_filter(&binding)
	editor_select_key(&binding, binding.rows[0].key)
	binding.leader = p.leader
	binding.visible_rows = 2
	// The synthetic group header stays above the inline row; selection must not scroll it away.
	binding.scroll = 0
	open_shortcuts(&binding)
	p.selected = index
	edit_set(p, Shortcut_Edit{editor = binding, result = index})
	return .Changed
}

// The row stays open while its editor captures, lists alternatives or has the keyboard on key
// positions; the editor leaving those states ends the inline edit.
@(private)
binding_open :: proc(b: ^Editor) -> bool {
	switch _ in b.mode {
	case Editor_Capturing, Editor_Shortcuts_Popup, Editor_Choice_Popup, Editor_Color_Popup, Editor_Positions:
		return true
	case Editor_Browsing, Editor_Editing, Editor_Reset_All, Editor_Profile_Menu:
	}
	return false
}

@(private)
palette_binding_outcome :: proc(p: ^Palette, binding: ^Shortcut_Edit, outcome: Editor_Outcome) -> Outcome {
	if outcome == .Save || outcome == .Reset {
		row := editor_row(&binding.editor)
		value := outcome == .Reset ? row.default_value : field_string(&binding.editor.value)
		return choose_setting(p, row.key, value, copy_key = true)
	}
	if !binding_open(&binding.editor) {edit_set(p, nil)}
	return .Changed
}

// Keep a refused binding available to correct; saving ends only the inline editor.
palette_binding_saved :: proc(p: ^Palette, saved: bool) {
	binding, open := &p.edit.(Shortcut_Edit)
	if !open {return}
	if saved {edit_set(p, nil)} else {
		editor_mode_set(&binding.editor, Editor_Capturing{})
	}
}

@(private)
palette_binding_key :: proc(p: ^Palette, binding: ^Shortcut_Edit, e: platform.Key_Event) -> Outcome {
	return palette_binding_outcome(p, binding, editor_key(&binding.editor, e))
}

palette_binding_reset :: proc(p: ^Palette, index: int) -> Outcome {
	if index < 0 || index >= len(p.results) || p.results[index].command == nil {return .None}
	p.selected = index
	if !palette_binding_modified(p.results[index].command) {return .Changed}
	if palette_binding_open(p, index) == .None {return .None}
	return palette_binding_outcome(p, &p.edit.(Shortcut_Edit), .Reset)
}

@(private)
palette_binding_press :: proc(
	p: ^Palette,
	binding: ^Shortcut_Edit,
	l: Palette_Layout,
	text: ^Text,
	x, y: f32,
) -> Outcome {
	b := &binding.editor
	layout := palette_binding_layout(p, l, binding.result)
	row, _ := row_rect(p, l, binding.result)
	parts := palette_binding_parts(row, l.scale)
	if editor_popup(b) != .None && render.rect_contains(editor_popup_rect(b, layout), x, y) {
		return palette_binding_outcome(p, binding, editor_press(b, layout, text, x, y, false))
	}
	if render.rect_contains(parts.reset, x, y) {return palette_binding_outcome(p, binding, .Reset)}
	if editor_popup(b) == .None && render.rect_contains(parts.positions, x, y) {
		b.physical = !b.physical
		return .Changed
	}
	if render.rect_contains(parts.field, x, y) {
		open_shortcuts(b)
		return .Changed
	}
	edit_set(p, nil)
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
) -> render.Build_Status {
	parts := palette_binding_parts(row, l.scale)
	modified := palette_binding_modified(command)
	reset_hovered := render.rect_contains(parts.reset, pointer.x, pointer.y)
	_ = reset_button_draw(list, theme, parts.reset, modified, reset_hovered,
	                      index == p.selected, pointer, l.scale)
	if binding, open := &p.edit.(Shortcut_Edit); open && binding.result == index {
		b := &binding.editor
		if editor_popup(b) != .None {parts.positions = {}}
		result := control_draw(b, editor_row(b), parts, true, list, text, theme, l.viewport, l.scale)
		_ = render.push_layer(list, l.list)
		return result
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	summary := Shortcut_Summary{additional = max(0, command.shortcuts.count - 1)}
	if shortcuts := commands.active_shortcuts(command); len(shortcuts) > 0 {
		summary.first = commands.shortcut_text(shortcuts[0], buffer[:])
	}
	parts.positions = {}
	focused := render.rect_contains(parts.field, pointer.x, pointer.y)
	result := shortcut_field_draw(list, text, theme, parts, summary,
	                              {focused = focused}, l.viewport, l.scale)
	_ = render.push_layer(list, l.list)
	return result
}
