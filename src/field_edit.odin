package main

import "aio:platform"
import "aio:ui"

Field_Edit :: struct {
	change: ui.Field_Change,
	// A successful paste still belongs to the caller when the field accepts no runes.
	pasted: bool,
}

field_edit_key :: proc(app: ^App, field: ^ui.Text_Field, e: platform.Key_Event) -> Field_Edit {
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

@(private)
Clipboard_Chord :: enum {
	None,
	Copy,
	Cut,
	Paste,
}

// Clipboard chords for text fields, including the terminal's Ctrl+Shift forms.
@(private)
clipboard_chord :: proc(e: platform.Key_Event) -> Clipboard_Chord {
	if !e.pressed {return .None}
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	control := modifiers == {.Control} || modifiers == {.Control, .Shift}
	switch {
	case control && e.key == .C, modifiers == {.Control} && e.key == .Insert:
		return .Copy
	case control && e.key == .X, modifiers == {.Shift} && e.key == .Delete:
		return .Cut
	case control && e.key == .V, modifiers == {.Shift} && e.key == .Insert:
		return .Paste
	}
	return .None
}

@(private)
clipboard_copy :: proc(app: ^App, text: string) -> bool {
	if text == "" {return false}
	if !platform.clipboard_set_text(&app.platform, text) {
		notify(app, .Error, "Could not copy to the clipboard.")
		return false
	}
	return true
}
