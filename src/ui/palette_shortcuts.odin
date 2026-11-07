package ui

import "aio:commands"
import "aio:input"
import "aio:render"
import "core:strings"

// Match the Settings shortcut row so capture, physical positions and its popup share geometry.
palette_binding_parts :: proc(row: render.Rect, scale: f32) -> Row_Parts {
	s := scale
	parts := Row_Parts {
		row = row, reset = reset_slot(row, s),
	}
	shortcut_parts(&parts, s, true)
	return parts
}

// The open row's alternatives list, below its field, or nothing while it is closed.
@(private)
palette_binding_popup :: proc(p: ^Palette, binding: ^Shortcut_Edit, l: Palette_Layout) -> render.Rect {
	row, _ := row_rect(p, l, binding.result)
	parts := palette_binding_parts(row, l.scale)
	return shortcut_capture_popup_rect(&binding.capture, parts, l.viewport, binding.saved, l.scale)
}

palette_binding_open :: proc(p: ^Palette, index: int) -> Outcome {
	if index < 0 || index >= len(p.results) || p.results[index].command == nil {return .None}
	command := p.results[index].command
	edit_set(p, nil)
	binding := Shortcut_Edit {
		key      = strings.concatenate({"keys.", command.name}),
		saved    = commands.shortcut_set_text(command.shortcuts),
		defaults = commands.shortcut_set_text(command.defaults),
		result   = index,
	}
	field_set(&binding.draft, binding.saved)
	binding.capture.leader = p.leader
	shortcut_capture_open(&binding.capture)
	p.selected = index
	edit_set(p, binding)
	return .Changed
}

@(private)
palette_binding_outcome :: proc(
	p: ^Palette,
	binding: ^Shortcut_Edit,
	outcome: Shortcut_Capture_Outcome,
) -> Outcome {
	switch outcome {
	case .None, .Changed, .Hinted, .Positions:
	case .Save:
		return choose_setting(p, binding.key, field_string(&binding.draft), copy_key = true)
	case .Cancel:
		edit_set(p, nil)
	}
	return .Changed
}

// Keep a refused binding available to correct; saving ends only the inline row.
palette_binding_saved :: proc(p: ^Palette, saved: bool) {
	binding, open := &p.edit.(Shortcut_Edit)
	if !open {return}
	if saved {edit_set(p, nil)} else {shortcut_capture_resume(&binding.capture)}
}

// The row stays open while its capture records, lists alternatives, or leaves the keyboard on the
// Key positions switch, which takes keys as on the Settings page.
@(private)
palette_binding_key :: proc(p: ^Palette, binding: ^Shortcut_Edit, raw: input.Key_Event) -> Outcome {
	c := &binding.capture
	if c.state != .Idle {
		return palette_binding_outcome(p, binding, shortcut_capture_key(c, &binding.draft, binding.saved,
		                               .Alternatives, raw))
	}
	e := raw
	e.key = commands.logical_key(raw.key, raw.unshifted)
	#partial switch e.key {
	case .Enter, .Numpad_Enter, .Space:
		c.physical = !c.physical
		return .Changed
	case .Tab:
		// Shift+Tab returns to the field, which lists the alternatives again; Tab leaves the row.
		if .Shift in e.modifiers {shortcut_capture_open(c)} else {edit_set(p, nil)}
		return .Changed
	case .Escape, .Page_Up, .Page_Down:
		edit_set(p, nil)
		return .Changed
	case .R:
		if .Control in e.modifiers && .Alt not_in e.modifiers {
			return choose_setting(p, binding.key, binding.defaults, copy_key = true)
		}
	}
	if list_step(e) != 0 {edit_set(p, nil)}
	return .Changed
}

palette_binding_reset :: proc(p: ^Palette, index: int) -> Outcome {
	if index < 0 || index >= len(p.results) || p.results[index].command == nil {return .None}
	p.selected = index
	command := p.results[index].command
	if commands.shortcut_set_equal(command.shortcuts, command.defaults) {return .Changed}
	if palette_binding_open(p, index) == .None {return .None}
	binding := &p.edit.(Shortcut_Edit)
	return choose_setting(p, binding.key, binding.defaults, copy_key = true)
}

@(private)
palette_binding_press :: proc(
	p: ^Palette, binding: ^Shortcut_Edit, l: Palette_Layout, x, y: f32,
) -> Outcome {
	c := &binding.capture
	row, _ := row_rect(p, l, binding.result)
	parts := palette_binding_parts(row, l.scale)
	if popup := palette_binding_popup(p, binding, l); render.rect_contains(popup, x, y) {
		outcome := shortcut_capture_press(c, &binding.draft, binding.saved, popup, x, y, l.scale)
		return palette_binding_outcome(p, binding, outcome)
	}
	if render.rect_contains(parts.reset, x, y) {
		return choose_setting(p, binding.key, binding.defaults, copy_key = true)
	}
	if c.state != .Alternatives && render.rect_contains(parts.positions, x, y) {
		c.physical = !c.physical
		return .Changed
	}
	if render.rect_contains(parts.field, x, y) {
		shortcut_capture_open(c)
		return .Changed
	}
	edit_set(p, nil)
	return .Changed
}

@(private)
palette_binding_hover :: proc(
	p: ^Palette, binding: ^Shortcut_Edit, l: Palette_Layout, x, y: f32,
) -> Outcome {
	popup := palette_binding_popup(p, binding, l)
	moved := shortcut_capture_hover(&binding.capture, popup, l.viewport, binding.saved, x, y, l.scale)
	return moved ? .Changed : .None
}

palette_binding_draw :: proc(
	p: ^Palette, command: ^commands.Command, index: int, row: render.Rect,
	list: ^render.Draw_List, text: ^Text, theme: Theme, l: Palette_Layout, pointer: [2]f32,
) -> render.Build_Status {
	parts := palette_binding_parts(row, l.scale)
	modified := !commands.shortcut_set_equal(command.shortcuts, command.defaults)
	reset_hovered := render.rect_contains(parts.reset, pointer.x, pointer.y)
	_ = reset_button_draw(list, theme, parts.reset, modified, reset_hovered,
	                      index == p.selected, pointer, l.scale)
	if binding, open := &p.edit.(Shortcut_Edit); open && binding.result == index {
		c := &binding.capture
		if c.state == .Alternatives {parts.positions = {}}
		state := Shortcut_Field_State {
			capturing = shortcut_capture_recording(c), focused = c.state != .Idle,
			positions_focused = c.state == .Idle, physical = c.physical, empty_label = "Add shortcut",
		}
		summary := shortcut_summary(field_string(&binding.draft))
		return shortcut_field_draw(list, text, theme, parts, summary, state, l.viewport, l.scale)
	}
	buffer: [commands.SHORTCUT_TEXT_CAP]u8
	summary := Shortcut_Summary{additional = max(0, command.shortcuts.count - 1)}
	if shortcuts := commands.active_shortcuts(command); len(shortcuts) > 0 {
		summary.first = commands.shortcut_text(shortcuts[0], buffer[:])
	}
	parts.positions = {}
	focused := render.rect_contains(parts.field, pointer.x, pointer.y)
	return shortcut_field_draw(list, text, theme, parts, summary, {focused = focused}, l.viewport, l.scale)
}

// The open row's alternatives list, over everything else in the palette.
@(private)
palette_binding_popup_draw :: proc(
	p: ^Palette, binding: ^Shortcut_Edit, l: Palette_Layout,
	list: ^render.Draw_List, text: ^Text, theme: Theme, pointer: [2]f32,
) -> render.Build_Status {
	popup := palette_binding_popup(p, binding, l)
	return shortcut_capture_popup_draw(&binding.capture, list, text, theme, popup, l.viewport, binding.saved,
	                                   pointer, l.scale)
}
