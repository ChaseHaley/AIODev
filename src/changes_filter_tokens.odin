package main

import "aio:fuzzy"
import "aio:input"
import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Saved filters in the diff filter's field (changes_filter.odin has the grammar): typing `@` offers the saved
// filters, a token is clicked or toggled with Space while selected to turn it on and off, and Ctrl+S saves
// the field's terms under a name and puts the filter in their place as a token.

// Sets the library the tokens are resolved against; false when it is the one the pane already has.
@(private)
changes_filter_library_set :: proc(pane: ^Changes_Pane, library: string) -> bool {
	if library == pane.filter_library {return false}
	kept, err := strings.clone(library)
	if err != nil {return false}
	delete(pane.filter_library)
	pane.filter_library = kept
	return true
}

// A settings revision may have changed the saved filters: every pane resolves its tokens again.
@(private)
changes_settings_applied :: proc(app: ^App) {
	for pane in app.changes_panes {
		if changes_filter_library_set(pane, app.settings.turns.saved_filters) {changes_filter_changed(pane)}
	}
	for w in app.windows {w.dirty = true}
}

@(private = "file")
filter_blank :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t'
}

// Where the `@` word the caret ends starts, or -1: a bare `@name` being typed, or a quoted name with its
// closing quote still to come.
@(private = "file")
changes_filter_pending_find :: proc(text: string, cursor: int) -> int {
	if cursor <= 0 || cursor > len(text) {return -1}
	start := cursor
	for start > 0 && !filter_blank(text[start - 1]) {start -= 1}
	if start < cursor && text[start] == '@' {return start}
	open := strings.last_index(text[:cursor], "@\"")
	if open < 0 || strings.contains_rune(text[open + 2:cursor], '"') {return -1}
	if open > 0 && !filter_blank(text[open - 1]) {return -1}
	return open
}

// The text typed after the `@`, which the saved filters are matched against.
@(private = "file")
changes_filter_query :: proc(pane: ^Changes_Pane) -> string {
	text := changes_filter_text(pane)
	from, to := pane.filter_pending + 1, pane.filter_editor.cursor
	if from > to || to > len(text) {return ""}
	return strings.trim_prefix(text[from:to], "\"")
}

@(private = "file", require_results)
changes_filter_has_token :: proc(pane: ^Changes_Pane, name: string) -> bool {
	for token in pane.filter_tokens {
		if strings.equal_fold(token.name, name) {return true}
	}
	return false
}

// Lists the saved filters an `@` being typed can complete to: those the field does not have yet whose name
// matches what was typed, best match first and in the user's order within a class of match.
@(private)
changes_filter_picks_build :: proc(pane: ^Changes_Pane) {
	clear(&pane.filter_picks)
	if !pane.filter_typing {return}
	query := changes_filter_query(pane)
	for class in fuzzy.Class.Exact ..= fuzzy.Class.Scattered {
		cursor := settings.saved_filters_scan(pane.filter_library)
		for filter in settings.saved_filters_next(&cursor) {
			if changes_filter_has_token(pane, filter.name) {continue}
			if query != "" && fuzzy.classify(query, filter.name) != class {continue}
			if query == "" && class != .Exact {continue}
			_, _ = append(&pane.filter_picks, ui.Filter_Pick{filter.name, filter.pattern})
		}
	}
	pane.filter_pick_row = clamp(pane.filter_pick_row, 0, len(pane.filter_picks))
}

// The words of the text that are plain terms, joined by single spaces; temporary memory.
@(private)
changes_filter_plain :: proc(pane: ^Changes_Pane) -> string {
	text := changes_filter_text(pane)
	from, to := -1, -1
	if pane.filter_typing {from, to = pane.filter_pending, pane.filter_editor.cursor}
	words := make([dynamic]string, context.temp_allocator)
	at := 0
	for {
		word, more := settings.filter_word_next(text, at)
		if !more {break}
		at = word.end
		if word.token || (word.start < to && word.end > from) {continue}
		_, _ = append(&words, text[word.start:word.end])
	}
	joined, _ := strings.join(words[:], " ", context.temp_allocator)
	return joined
}

// Ends an `@` being typed: its text stays and becomes a token, or a term when it is no token.
@(private)
changes_filter_typing_end :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if !pane.filter_typing {return}
	pane.filter_typing, pane.filter_pending = false, 0
	changes_filter_edited(app, w, pane)
}

// An edit of the text: whether an `@` is being typed follows what the caret now ends. After typing or a paste
// the word the caret ends starts it; while deleting, an `@` already being typed carries on.
@(private)
changes_filter_typing :: proc(pane: ^Changes_Pane, inserted: bool) {
	start := changes_filter_pending_find(changes_filter_text(pane), pane.filter_editor.cursor)
	pane.filter_typing = start >= 0 && (inserted || pane.filter_typing)
	pane.filter_pending = pane.filter_typing ? start : 0
	pane.filter_pick_row = 0
}

// Types `text` at the caret. A token is a word of its own, so typing against one starts a new word rather
// than changing the token's name.
@(private)
changes_filter_type :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, text: string) {
	f := &pane.filter_editor
	lead, trail := "", ""
	if text != "" && f.anchor == f.cursor {
		first, _ := utf8.decode_rune_in_string(text)
		last, _ := utf8.decode_last_rune_in_string(text)
		for token in pane.filter_tokens {
			if f.cursor == token.end && !unicode.is_space(first) {lead = " "}
			if f.cursor == token.start && !unicode.is_space(last) {trail = " "}
		}
	}
	typed := text
	if lead != "" || trail != "" {typed = strings.concatenate({lead, text, trail}, context.temp_allocator)}
	if ui.field_text(f, typed) != .Edited {return}
	if trail != "" {f.cursor, f.anchor = f.cursor - 1, f.cursor - 1}
	changes_filter_typing(pane, true)
	changes_filter_edited(app, w, pane)
}

// Replaces bytes `from` to `to` of the filter text with `with`, putting the caret `caret` bytes after `from`.
@(private = "file")
changes_filter_splice :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, from, to: int, with: string, caret: int,
) {
	text := changes_filter_text(pane)
	spliced := strings.concatenate({text[:from], with, text[to:]}, context.temp_allocator)
	f := &pane.filter_editor
	if ui.field_set(f, spliced) != nil {return}
	f.cursor, f.anchor = from + caret, from + caret
	pane.filter_typing = false
	changes_filter_edited(app, w, pane)
}

// Completes the `@` being typed with the saved filter in `row`, as an `on` token and the space after it; the
// row past the last filter opens Settings on the saved filters and leaves the text as it was before the `@`.
@(private)
changes_filter_pick_choose :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, row: int) {
	if !pane.filter_typing {return}
	from, to := pane.filter_pending, pane.filter_editor.cursor
	if row < 0 || row >= len(pane.filter_picks) {
		changes_filter_splice(app, w, pane, from, to, "", 0)
		changes_filter_popover_close(app, w, pane)
		settings_reveal(app, w, {key = settings.SAVED_FILTERS_KEY, search = .Clear, focus = .Control})
		return
	}
	buffer: [settings.SAVED_FILTER_NAME_MAX + 8]u8
	token := settings.filter_token_format(buffer[:], pane.filter_picks[row].name, false)
	text := changes_filter_text(pane)
	space := to < len(text) && filter_blank(text[to]) ? "" : " "
	with := strings.concatenate({token, space}, context.temp_allocator)
	changes_filter_splice(app, w, pane, from, to, with, len(with))
}

// Flips token `index` between on and off, keeping the caret and the selection where they were.
@(private)
changes_filter_toggle :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, index: int) {
	if index < 0 || index >= len(pane.filter_tokens) {return}
	token, f := pane.filter_tokens[index], &pane.filter_editor
	text := changes_filter_text(pane)
	delta := token.off ? -1 : 1
	spliced: string
	if token.off {
		spliced = strings.concatenate({text[:token.start], text[token.start + 1:]}, context.temp_allocator)
	} else {
		spliced = strings.concatenate({text[:token.start], "~", text[token.start:]}, context.temp_allocator)
	}
	cursor, anchor := f.cursor, f.anchor
	if ui.field_set(f, spliced) != nil {return}
	f.cursor = cursor > token.start ? cursor + delta : cursor
	f.anchor = anchor > token.start ? anchor + delta : anchor
	pane.filter_typing = false
	changes_filter_edited(app, w, pane)
}

// Takes token `index` out of the text, with one of the spaces beside it.
@(private)
changes_filter_remove :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, index: int) {
	if index < 0 || index >= len(pane.filter_tokens) {return}
	token := pane.filter_tokens[index]
	text := changes_filter_text(pane)
	to := token.end
	if to < len(text) && filter_blank(text[to]) {to += 1}
	changes_filter_splice(app, w, pane, token.start, to, "", 0)
}

// Space on a token that is the selection toggles it; false when the selection is anything else.
@(private)
changes_filter_toggle_selected :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) -> bool {
	low, high := ui.field_selection(&pane.filter_editor)
	for token, i in pane.filter_tokens {
		if token.start == low && token.end == high {
			changes_filter_toggle(app, w, pane, i)
			return true
		}
	}
	return false
}

// A press or drag at `x` in the filter field: a token toggles, or goes with its ×, and anywhere else the
// caret goes under the pointer or the selection extends to it.
@(private)
changes_filter_point :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, g: ui.Changes_Geometry, x: f32, pressed, extend: bool,
) {
	box, visible := ui.changes_filter_box(g, &pane.model.view, &w.ui_text)
	if !visible {return}
	if pressed {
		if pane.state.filter_naming {changes_filter_name_end(w, pane)}
		if index, close := ui.filter_field_token_at(box, pane.filter_tokens[:], x); index >= 0 {
			if close {changes_filter_remove(app, w, pane, index)} else {changes_filter_toggle(app, w, pane, index)}
			return
		}
		if pane.filter_typing {changes_filter_typing_end(app, w, pane)}
	}
	at := ui.filter_field_offset(box, pane.filter_tokens[:], x)
	if ui.field_pointer(&pane.filter_editor, at, pressed, extend) != .None {w.dirty = true}
}

@(private = "file")
changes_filter_popover_close :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	changes_filter_popover(app, w, pane, false)
}

// Starts naming the field's terms (Ctrl+S): a name field under the field takes the keys until Enter or
// Escape.
@(private)
changes_filter_name_begin :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if !pane.filter_savable {return}
	changes_filter_typing_end(app, w, pane)
	_ = ui.field_set(&pane.filter_name, "")
	delete(pane.filter_notice)
	pane.filter_notice = ""
	pane.state.filter_naming = true
	w.dirty = true
}

@(private)
changes_filter_name_end :: proc(w: ^Window, pane: ^Changes_Pane) {
	pane.state.filter_naming = false
	_ = ui.field_release(&pane.filter_name)
	w.dirty = true
}

@(private = "file")
changes_filter_refuse :: proc(pane: ^Changes_Pane, w: ^Window, message: string) {
	delete(pane.filter_notice)
	pane.filter_notice, _ = strings.clone(message)
	w.dirty = true
}

@(private = "file")
changes_filter_problem_text :: proc(problem: settings.Saved_Filter_Problem) -> string {
	switch problem {
	case .Name:
		return "Use a name of up to 32 characters without ; | or quotes."
	case .Duplicate:
		return "A saved filter already has that name."
	case .Pattern:
		return "A saved pattern cannot hold ;."
	case .Too_Long:
		return "The saved filters are too long to store."
	}
	return ""
}

// Saves the field's terms under the name typed, as the last of the saved filters, and replaces them in the
// field with the filter as a token that is on. A refusal says why under the name and keeps the field.
@(private)
changes_filter_name_save :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	drafts := make([dynamic]settings.Saved_Filter_Draft, context.temp_allocator)
	cursor := settings.saved_filters_scan(app.settings.turns.saved_filters)
	for filter in settings.saved_filters_next(&cursor) {
		_, _ = append(&drafts, settings.Saved_Filter_Draft{filter.name, filter.pattern})
	}
	name := strings.trim_space(ui.field_string(&pane.filter_name))
	_, _ = append(&drafts, settings.Saved_Filter_Draft{name, changes_filter_plain(pane)})
	value, problem, err := settings.saved_filters_text(drafts[:], context.temp_allocator)
	if err != nil {
		changes_filter_refuse(pane, w, "Could not keep the filter.")
		return
	}
	if refused, has_problem := problem.?; has_problem {
		changes_filter_refuse(pane, w, changes_filter_problem_text(refused))
		return
	}
	result := settings_change(app, Setting_Value{settings.SAVED_FILTERS_KEY, value}, Settings_Current{})
	if result.status != .Applied {
		changes_filter_refuse(pane, w, result.message != "" ? result.message : "Could not save the filter.")
		return
	}
	_ = changes_filter_library_set(pane, app.settings.turns.saved_filters)
	words := make([dynamic]string, context.temp_allocator)
	text := changes_filter_text(pane)
	for token in pane.filter_tokens {_, _ = append(&words, text[token.start:token.end])}
	buffer: [settings.SAVED_FILTER_NAME_MAX + 8]u8
	_, _ = append(&words, settings.filter_token_format(buffer[:], name, false))
	joined, _ := strings.join(words[:], " ", context.temp_allocator)
	changes_filter_name_end(w, pane)
	changes_filter_splice(app, w, pane, 0, len(text), joined, len(joined))
}

// Keys while a name is being typed: Enter saves, Escape goes back to the field, the rest edits the name.
@(private)
changes_filter_name_key :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, logical, e: input.Key_Event,
) -> bool {
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	#partial switch logical.key {
	case .Enter, .Numpad_Enter:
		if modifiers == {} {
			changes_filter_name_save(app, w, pane)
			return true
		}
	case .Escape:
		if modifiers == {} {
			changes_filter_name_end(w, pane)
			return true
		}
	}
	if field_edit_key(app, &pane.filter_name, logical).change != .None {
		delete(pane.filter_notice)
		pane.filter_notice = ""
	}
	w.dirty = true
	return true
}

// Typed text goes to the name while one is being typed, else to the field.
@(private)
changes_filter_text_in :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, text: string) {
	if !pane.state.filter_naming {
		changes_filter_type(app, w, pane, text)
		return
	}
	if ui.field_text(&pane.filter_name, text) == .Edited {
		delete(pane.filter_notice)
		pane.filter_notice = ""
	}
	w.dirty = true
}

// A press in the name field puts the caret under the pointer, or extends the selection to it.
@(private)
changes_filter_name_point :: proc(
	w: ^Window, pane: ^Changes_Pane, g: ui.Changes_Geometry, x: f32, extend: bool,
) {
	box := ui.field_box_standard(&pane.filter_name, &w.ui_text, g.filter_name, w.scale)
	if ui.field_pointer(&pane.filter_name, ui.field_box_offset(box, x), true, extend) != .None {w.dirty = true}
}
