package main

import "aio:input"
import "aio:platform"

@(private)
Clipboard_Chord :: enum {
	None,
	Copy,
	Cut,
	Paste,
}

// Clipboard chords for text fields, including the terminal's Ctrl+Shift forms.
@(private)
clipboard_chord :: proc(e: input.Key_Event) -> Clipboard_Chord {
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
