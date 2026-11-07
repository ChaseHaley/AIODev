package main

import "aio:input"
import "aio:platform"
import "aio:ui"

Field_Edit :: struct {
	change: ui.Field_Change,
	// A successful paste still belongs to the caller when the field accepts no runes.
	pasted: bool,
}

field_edit_key :: proc(app: ^App, field: ^ui.Text_Field, e: input.Key_Event) -> Field_Edit {
	switch clipboard_chord(e) {
	case .Copy:
		clipboard_copy(app, ui.field_selected_text(field))
	case .Cut:
		if clipboard_copy(app, ui.field_selected_text(field)) {
			return {change = ui.field_text(field, "")}
		}
	case .Paste:
		if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
			return {change = ui.field_text(field, text), pasted = true}
		}
	case .None:
		return {change = ui.field_key(field, e)}
	}
	return {}
}
