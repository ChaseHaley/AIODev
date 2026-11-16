package main

import "aio:markdown"
import "aio:platform"
import "core:unicode/utf8"

// The keys of a multi-line text editor over a `markdown.Edit_Buffer`, shared by every pane or card that
// edits one: typing, the clipboard chords, undo, and the caret and edit keys. The host keeps what is
// its own: saving, scrolling, and the vertical moves, which need the lines as it lays them out.

// What a key did, so the host can follow it.
Text_Edit_Kind :: enum {
	// The key is not the editor's; shortcuts and the pane may have it.
	Ignored,
	// The editor took the key and nothing on screen follows from it, such as a copy.
	Handled,
	// The caret or selection moved.
	Moved,
	// The text changed.
	Edited,
	// Up, Down, Page Up or Page Down: the host moves the caret as its lines lay out.
	Vertical,
}

Text_Edit :: struct {
	kind:         Text_Edit_Kind,
	// For `.Vertical`: lines up (negative) or down, or pages, to move; one of them is set.
	lines, pages: int,
	// For `.Vertical`: the selection grows with the caret.
	extend:       bool,
}

// Typed text goes in at the caret: a key's text from Windows, or text with no key of its own, such as an
// input method's. Control characters arrive as their keys instead, so they are not the editor's here.
@(require_results)
text_edit_type :: proc(b: ^markdown.Edit_Buffer, text: string) -> Text_Edit_Kind {
	if text == "" {return .Ignored}
	for r in text {
		if r < 0x20 || r == 0x7f {return .Ignored}
	}
	return markdown.edit_insert(b, text, true) ? .Edited : .Handled
}

// Applies a key to the buffer. The caller decides what Escape and an Enter that saves mean before
// asking, and follows the result: a `.Vertical` key is left for it to move as it lays its lines out.
@(require_results)
text_edit_key :: proc(app: ^App, b: ^markdown.Edit_Buffer, key: Content_Key) -> Text_Edit {
	logical := key.logical
	modifiers := logical.modifiers & {.Control, .Shift, .Alt, .Super}
	// A character key types its text; Ctrl+Alt is AltGr, which types too. Ctrl and Alt alone make chords.
	typing := modifiers & {.Control, .Alt} == {} || modifiers & {.Control, .Alt} == {.Control, .Alt}
	if typing && .Super not_in modifiers {
		if kind := text_edit_type(b, logical.text); kind != .Ignored {return {kind = kind}}
	}
	if .Alt in modifiers || .Super in modifiers {return {}}
	control, shift := .Control in modifiers, .Shift in modifiers
	switch key.clipboard {
	case .Copy:
		if text := markdown.edit_selected_text(b); text != "" {clipboard_copy(app, text)}
		return {kind = .Handled}
	case .Cut:
		if text := markdown.edit_selected_text(b); text != "" && clipboard_copy(app, text) {
			if markdown.edit_delete(b, false, false) {return {kind = .Edited}}
		}
		return {kind = .Handled}
	case .Paste:
		if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
			if markdown.edit_insert(b, text_line_endings(text, b.newline)) {return {kind = .Edited}}
		}
		return {kind = .Handled}
	case .None:
	}
	edited := false
	#partial switch logical.key {
	case .Z:
		if !control {return {}}
		edited = shift ? markdown.edit_redo(b) : markdown.edit_undo(b)
	case .Y:
		if !control || shift {return {}}
		edited = markdown.edit_redo(b)
	case .A:
		if !control || shift {return {}}
		markdown.edit_select_all(b)
	case .Arrow_Left:
		from, to := markdown.edit_selection(b)
		switch {
		case control: markdown.edit_move(b, markdown.edit_word_left(b, b.caret), shift)
		case !shift && from != to: markdown.edit_move(b, from)
		case: markdown.edit_move(b, markdown.edit_left(b, b.caret), shift)
		}
	case .Arrow_Right:
		from, to := markdown.edit_selection(b)
		switch {
		case control: markdown.edit_move(b, markdown.edit_word_right(b, b.caret), shift)
		case !shift && from != to: markdown.edit_move(b, to)
		case: markdown.edit_move(b, markdown.edit_right(b, b.caret), shift)
		}
	case .Arrow_Up, .Arrow_Down:
		if control {return {}}
		return {kind = .Vertical, lines = logical.key == .Arrow_Up ? -1 : 1, extend = shift}
	case .Page_Up, .Page_Down:
		if control {return {}}
		return {kind = .Vertical, pages = logical.key == .Page_Up ? -1 : 1, extend = shift}
	case .Home:
		markdown.edit_move(b, control ? b.floor : markdown.edit_line_start(b, b.caret), shift)
	case .End:
		markdown.edit_move(b, control ? len(b.text) : markdown.edit_line_end(b, b.caret), shift)
	case .Backspace, .Delete:
		if shift {return {}}
		edited = markdown.edit_delete(b, logical.key == .Delete, control)
	case .Enter, .Numpad_Enter:
		if control {return {}}
		// Shift+Enter breaks the line without continuing a list.
		edited = shift ? markdown.edit_insert(b, b.newline) : markdown.edit_newline(b)
	case .Tab:
		if control {return {}}
		edited = markdown.edit_indent(b, shift)
	case .Escape:
		if modifiers != {} {return {}}
		markdown.edit_move(b, b.caret)
	case:
		return {}
	}
	return {kind = edited ? .Edited : .Moved}
}

// Pasted text in the buffer's own line endings.
@(private = "file")
text_line_endings :: proc(text, newline: string) -> string {
	out := make([dynamic]u8, 0, len(text), context.temp_allocator)
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if c == '\r' {
			if i + 1 < len(text) && text[i + 1] == '\n' {i += 1}
			append(&out, newline)
			continue
		}
		if c == '\n' {
			append(&out, newline)
			continue
		}
		append(&out, c)
	}
	if !utf8.valid_string(string(out[:])) {return text}
	return string(out[:])
}
