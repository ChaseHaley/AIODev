package main

import "cosmos:input"
import "aio:platform"
import "aio:ui"

Field_Edit :: struct {
	change: ui.Field_Change,
	// A successful paste still belongs to the caller when the field accepts no runes.
	pasted: bool,
}

field_edit_key :: proc(app: ^App, field: ^ui.Text_Field, e: input.Key_Event) -> Field_Edit {
	switch clipboard_chord(e) {
	case .Copy: return field_edit_command(app, field, .Copy)
	case .Cut: return field_edit_command(app, field, .Cut)
	case .Paste: return field_edit_command(app, field, .Paste)
	case .None:
		return {change = ui.field_key(field, e)}
	}
	return {}
}

// Whether `command` would do anything to `field` now, for an edit menu's disabled rows. A field keeps no
// undo history.
@(require_results)
field_edit_enabled :: proc(app: ^App, field: ^ui.Text_Field, command: Text_Edit_Command) -> bool {
	switch command {
	case .Undo, .Redo: return false
	case .Cut, .Copy: return ui.field_selected_text(field) != ""
	case .Paste:
		text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
		return ok && text != ""
	case .Select_All: return len(field.bytes) > 0
	}
	return false
}

// Applies a clipboard or selection command to `field`, as its chord does.
field_edit_command :: proc(app: ^App, field: ^ui.Text_Field, command: Text_Edit_Command) -> Field_Edit {
	switch command {
	case .Undo, .Redo:
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
	case .Select_All:
		ui.field_select_all(field)
		return {change = .Moved}
	}
	return {}
}
