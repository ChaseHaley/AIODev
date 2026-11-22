package main

import "cosmos:input"
import "aio:markdown"
import "cosmos:platform"
import "core:strings"
import "core:unicode/utf8"

// The keys of a multi-line text editor over a `markdown.Edit_Buffer`, shared by every pane or card that
// edits one: typing, the clipboard chords, undo, and the caret and edit keys. The host keeps what is
// its own: saving, scrolling, and the moves that need the lines as it lays them out (vertical moves, and
// Home and End on a soft-wrapped row).
// (probe)

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
	// Home or End without Ctrl: the host knows where the caret's visual row starts and ends, since a
	// soft-wrapped line has several, and moves the caret with `markdown.edit_home_target` or
	// `edit_end_target`.
	Row_Edge,
	// Ctrl+Up or Ctrl+Down: the host scrolls its view by a line without moving the caret.
	Scroll,
}

Text_Edit :: struct {
	kind:         Text_Edit_Kind,
	// For `.Vertical`: lines up (negative) or down, or pages, to move; one of them is set. For `.Scroll`
	// the lines to scroll by.
	lines, pages: int,
	// For `.Vertical` and `.Row_Edge`: the selection grows with the caret.
	extend:       bool,
	// For `.Row_Edge`: End rather than Home.
	end:          bool,
}

// Cut, copy or paste at the buffer's selection, as the chord or the edit menu asks.
@(require_results)
text_edit_clipboard :: proc(app: ^App, b: ^markdown.Edit_Buffer, chord: Clipboard_Chord) -> Text_Edit_Kind {
	switch chord {
	case .Copy:
		if text := markdown.edit_selected_text(b); text != "" {clipboard_copy(app, text)}
	case .Cut:
		if text := markdown.edit_selected_text(b); text != "" && clipboard_copy(app, text) {
			if markdown.edit_delete(b, false, false) {return .Edited}
		}
	case .Paste:
		if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
			if markdown.edit_insert(b, text_line_endings(text, b.newline)) {return .Edited}
		}
	case .None:
		return .Ignored
	}
	return .Handled
}

// What an editor's edit menu offers, each the same as its chord.
Text_Edit_Command :: enum u8 {
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
}

// Whether `command` would do anything to the buffer now, for the menu's disabled rows.
@(require_results)
text_edit_enabled :: proc(app: ^App, b: ^markdown.Edit_Buffer, command: Text_Edit_Command) -> bool {
	switch command {
	case .Undo: return len(b.undo) > 0
	case .Redo: return len(b.redo) > 0
	case .Cut, .Copy:
		from, to := markdown.edit_selection(b)
		return from != to
	case .Paste:
		text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
		return ok && text != ""
	case .Select_All: return len(b.text) > b.floor
	}
	return false
}

@(require_results)
text_edit_command :: proc(app: ^App, b: ^markdown.Edit_Buffer, command: Text_Edit_Command) -> Text_Edit_Kind {
	switch command {
	case .Undo: return markdown.edit_undo(b) ? .Edited : .Handled
	case .Redo: return markdown.edit_redo(b) ? .Edited : .Handled
	case .Cut: return text_edit_clipboard(app, b, .Cut)
	case .Copy: return text_edit_clipboard(app, b, .Copy)
	case .Paste: return text_edit_clipboard(app, b, .Paste)
	case .Select_All:
		markdown.edit_select_all(b)
		return .Moved
	}
	return .Handled
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

// Whether a character key held with `modifiers` types its text: with none or Shift, and with Ctrl+Alt, which
// is AltGr. Ctrl or Alt alone make chords, and Super never types.
text_key_types :: proc(modifiers: input.Modifiers) -> bool {
	chord := modifiers & {.Control, .Alt}
	return (chord == {} || chord == {.Control, .Alt}) && .Super not_in modifiers
}

// Applies a key to the buffer. The caller decides what Escape and an Enter that saves mean before
// asking, and follows the result: a `.Vertical` key is left for it to move as it lays its lines out.
@(require_results)
text_edit_key :: proc(app: ^App, b: ^markdown.Edit_Buffer, key: Content_Key) -> Text_Edit {
	logical := key.logical
	modifiers := logical.modifiers & {.Control, .Shift, .Alt, .Super}
	if text_key_types(modifiers) {
		if kind := text_edit_type(b, logical.text); kind != .Ignored {return {kind = kind}}
	}
	if .Alt in modifiers || .Super in modifiers {return {}}
	control, shift := .Control in modifiers, .Shift in modifiers
	if kind := text_edit_clipboard(app, b, key.clipboard); kind != .Ignored {return {kind = kind}}
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
		up := logical.key == .Arrow_Up
		if control {
			if shift {return {}}
			return {kind = .Scroll, lines = up ? -1 : 1}
		}
		return {kind = .Vertical, lines = up ? -1 : 1, extend = shift}
	case .Page_Up, .Page_Down:
		if control {return {}}
		return {kind = .Vertical, pages = logical.key == .Page_Up ? -1 : 1, extend = shift}
	case .Home:
		if !control {return {kind = .Row_Edge, extend = shift}}
		markdown.edit_move(b, b.floor, shift)
	case .End:
		if !control {return {kind = .Row_Edge, extend = shift, end = true}}
		markdown.edit_move(b, len(b.text), shift)
	case .Backspace, .Delete:
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

// Pasted text in the buffer's own line endings: the text itself when it already has them, which is
// the usual case and costs a scan, else a copy with each line break replaced.
@(private = "file")
text_line_endings :: proc(text, newline: string) -> string {
	if !text_foreign_endings(text, newline) {return text}
	out := make([dynamic]u8, 0, len(text) + len(text) / 8, context.temp_allocator)
	rest := text
	for len(rest) > 0 {
		at := strings.index_any(rest, "\r\n")
		if at < 0 {
			append(&out, rest)
			break
		}
		append(&out, rest[:at])
		append(&out, newline)
		skip := 1
		if rest[at] == '\r' && at + 1 < len(rest) && rest[at + 1] == '\n' {skip = 2}
		rest = rest[at + skip:]
	}
	if !utf8.valid_string(string(out[:])) {return text}
	return string(out[:])
}

// Whether `text` has a line break that is not `newline`, which is "\n" or "\r\n".
@(private = "file")
text_foreign_endings :: proc(text, newline: string) -> bool {
	if newline == "\n" {return strings.index_byte(text, '\r') >= 0}
	for i in 0 ..< len(text) {
		switch text[i] {
		case '\r':
			if i + 1 >= len(text) || text[i + 1] != '\n' {return true}
		case '\n':
			if i == 0 || text[i - 1] != '\r' {return true}
		}
	}
	return false
}
