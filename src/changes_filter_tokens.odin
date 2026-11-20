package main

import "aio:fuzzy"
import "aio:input"
import "aio:settings"
import "aio:ui"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

// Saved filters in the diff filter's field (changes_filter.odin has the grammar): the field's @ button, or
// an `@` typed in it, lists the saved filters; a token is clicked, or toggled with Space while selected, to
// turn it on and off; and one action saves the field's terms as a saved filter, named by those terms, and
// puts the filter in their place as a token.

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

// A settings revision may have changed the saved filters: every pane resolves its tokens again, so a renamed
// or edited filter shows and filters at once in every pane. A token whose filter is gone leaves the field: it
// has nothing left to show or switch, and a filter made later has an id of its own, so the token could never
// refer to anything again. Nothing is removed while the saved filters could not be read, since the revision
// then holds none and the filters are back once the file is fixed.
@(private)
changes_settings_applied :: proc(app: ^App) {
	readable := app.settings_read_error == nil
	for diagnostic in app.settings_diagnostics {
		if diagnostic.key == settings.SAVED_FILTERS_KEY {readable = false}
	}
	for pane in app.changes_panes {
		if !changes_filter_library_set(pane, app.settings.turns.saved_filters) {continue}
		if readable {changes_filter_forget_removed(pane)}
		changes_filter_changed(pane)
	}
	for w in app.windows {w.dirty = true}
}

// Takes the tokens that were resolved to a saved filter the library no longer has out of the pane's field,
// each with one of the spaces beside it, keeping the caret and the selection with the text they were in.
@(private = "file")
changes_filter_forget_removed :: proc(pane: ^Changes_Pane) {
	text := changes_filter_text(pane)
	kept := strings.builder_make(context.temp_allocator)
	f := &pane.filter_editor
	before_cursor, before_anchor, from := 0, 0, 0
	for token in pane.filter_tokens {
		if token.state == .Unknown {continue}
		if _, _, found := settings.saved_filters_find_id(pane.filter_library, token.id); found {continue}
		to := token.end
		if to < len(text) && filter_blank(text[to]) {to += 1}
		strings.write_string(&kept, text[from:token.start])
		from = to
		before_cursor += clamp(f.cursor - token.start, 0, to - token.start)
		before_anchor += clamp(f.anchor - token.start, 0, to - token.start)
	}
	if from == 0 {return}
	strings.write_string(&kept, text[from:])
	cursor, anchor := f.cursor - before_cursor, f.anchor - before_anchor
	if ui.field_set(f, strings.to_string(kept)) != nil {return}
	f.cursor, f.anchor = cursor, anchor
	if pane.filter_pending >= 0 {pane.filter_typing = false}
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

// The text typed after the `@`, which the saved filters are matched against; none when the list was opened
// by the button.
@(private = "file")
changes_filter_query :: proc(pane: ^Changes_Pane) -> string {
	if pane.filter_pending < 0 {return ""}
	text := changes_filter_text(pane)
	from, to := pane.filter_pending + 1, pane.filter_editor.cursor
	if from > to || to > len(text) {return ""}
	return strings.trim_prefix(text[from:to], "\"")
}

@(private = "file", require_results)
changes_filter_has_token :: proc(pane: ^Changes_Pane, id: string) -> bool {
	for token in pane.filter_tokens {
		if token.id == id {return true}
	}
	return false
}

// How many files the pane's diff would hide under `pattern` alone.
@(private = "file", require_results)
changes_filter_hides :: proc(pane: ^Changes_Pane, pattern: string) -> int {
	f: Changes_Filter
	defer changes_filter_destroy(&f)
	if ok, _ := changes_filter_set(&f, pattern); !ok {return 0}
	hidden := 0
	for file in pane.model.diff.files {
		if !changes_filter_shows(&f, changes_file_path(file), changes_file_old_path(file)) {hidden += 1}
	}
	return hidden
}

// Lists the saved filters the list can insert: those the field does not have yet whose label matches what
// was typed after the `@`, best match first and in the user's order within a class of match.
@(private)
changes_filter_picks_build :: proc(pane: ^Changes_Pane) {
	clear(&pane.filter_picks)
	if !pane.filter_typing {return}
	query := changes_filter_query(pane)
	for class in fuzzy.Class.Exact ..= fuzzy.Class.Scattered {
		cursor := settings.saved_filters_scan(pane.filter_library)
		for filter in settings.saved_filters_next(&cursor) {
			label := settings.saved_filter_label(filter)
			if changes_filter_has_token(pane, filter.id) {continue}
			if query != "" && fuzzy.classify(query, label) != class {continue}
			if query == "" && class != .Exact {continue}
			pick := ui.Filter_Pick {
				id      = filter.id,
				label   = label,
				pattern = filter.pattern,
				hides   = changes_filter_hides(pane, filter.pattern),
			}
			_, _ = append(&pane.filter_picks, pick)
		}
	}
	pane.filter_pick_row = clamp(pane.filter_pick_row, 0, max(0, len(pane.filter_picks) - 1))
}

// The words of the text that are plain terms, joined by single spaces; temporary memory.
@(private)
changes_filter_plain :: proc(pane: ^Changes_Pane) -> string {
	text := changes_filter_text(pane)
	from, to := -1, -1
	if pane.filter_typing && pane.filter_pending >= 0 {from, to = pane.filter_pending, pane.filter_editor.cursor}
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

// Ends the list and an `@` being typed: the typed text stays and becomes a token, or a term when it is no
// token.
@(private)
changes_filter_typing_end :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if !pane.filter_typing {return}
	pane.filter_typing, pane.filter_pending = false, 0
	changes_filter_edited(app, w, pane)
}

// Escape in the list: closes it, and takes out an `@` that was being typed rather than leaving it as a term.
@(private)
changes_filter_list_cancel :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if !pane.filter_typing {return}
	if pane.filter_pending < 0 {
		changes_filter_typing_end(app, w, pane)
		return
	}
	changes_filter_splice(app, w, pane, pane.filter_pending, pane.filter_editor.cursor, "", 0)
}

// An edit of the text: an `@` the caret ends opens the list for it. After typing or a paste the word the
// caret ends starts it; while deleting, an `@` already being typed carries on, and a list the button opened
// stays open.
@(private)
changes_filter_typing :: proc(pane: ^Changes_Pane, inserted: bool) {
	start := changes_filter_pending_find(changes_filter_text(pane), pane.filter_editor.cursor)
	switch {
	case start >= 0 && (inserted || (pane.filter_typing && pane.filter_pending >= 0)):
		pane.filter_typing, pane.filter_pending = true, start
	case pane.filter_typing && pane.filter_pending < 0:
	case:
		pane.filter_typing, pane.filter_pending = false, 0
	}
	pane.filter_pick_row = 0
}

// Opens or closes the saved filters list from the field's @ button.
@(private)
changes_filter_list_toggle :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if pane.filter_typing {
		changes_filter_typing_end(app, w, pane)
		return
	}
	pane.filter_typing, pane.filter_pending, pane.filter_pick_row = true, -1, 0
	changes_filter_edited(app, w, pane)
}

// Types `text` at the caret. A token is a word of its own, so typing against one starts a new word rather
// than changing the token.
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
	pane.filter_typing, pane.filter_pending = false, 0
	changes_filter_edited(app, w, pane)
}

// Completes the `@` being typed, or inserts at the caret when the button opened the list, with the saved
// filter in `row`, as an on token and the space after it.
@(private)
changes_filter_pick_choose :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane, row: int) {
	if !pane.filter_typing || row < 0 || row >= len(pane.filter_picks) {return}
	text := changes_filter_text(pane)
	from, to := pane.filter_editor.cursor, pane.filter_editor.cursor
	if pane.filter_pending >= 0 {from = pane.filter_pending}
	buffer: [settings.SAVED_FILTER_ID_LEN + 8]u8
	token := settings.filter_token_format(buffer[:], pane.filter_picks[row].id, false)
	lead := from > 0 && !filter_blank(text[from - 1]) ? " " : ""
	space := to < len(text) && filter_blank(text[to]) ? "" : " "
	with := strings.concatenate({lead, token, space}, context.temp_allocator)
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
		if index, close := ui.filter_field_token_at(box, pane.filter_tokens[:], x); index >= 0 {
			if close {changes_filter_remove(app, w, pane, index)} else {changes_filter_toggle(app, w, pane, index)}
			return
		}
		if pane.filter_typing && pane.filter_pending >= 0 {changes_filter_typing_end(app, w, pane)}
	}
	at := ui.filter_field_offset(box, pane.filter_tokens[:], x)
	if ui.field_pointer(&pane.filter_editor, at, pressed, extend) != .None {w.dirty = true}
}

@(private = "file")
changes_filter_refuse :: proc(pane: ^Changes_Pane, w: ^Window, message: string) {
	delete(pane.filter_notice)
	pane.filter_notice, _ = strings.clone(message)
	w.dirty = true
}

// A token typed or pasted with a filter's name rather than its id (the form this field's text had before ids)
// refers to that filter by id from then on, so a later rename cannot lose it. The `@` still being typed is
// left alone, and the caret and the selection stay with the text they were in.
@(private)
changes_filter_ids_resolve :: proc(pane: ^Changes_Pane) {
	text := changes_filter_text(pane)
	pending_from, pending_to := -1, -1
	if pane.filter_typing && pane.filter_pending >= 0 {
		pending_from, pending_to = pane.filter_pending, pane.filter_editor.cursor
	}
	resolved := strings.builder_make(context.temp_allocator)
	buffer: [settings.SAVED_FILTER_ID_LEN + 8]u8
	f := &pane.filter_editor
	grown_cursor, grown_anchor, copied, at := 0, 0, 0, 0
	for {
		word, more := settings.filter_word_next(text, at)
		if !more {break}
		at = word.end
		if !word.token || (word.start < pending_to && word.end > pending_from) {continue}
		if _, _, found := settings.saved_filters_find_id(pane.filter_library, word.name); found {continue}
		filter, _, found := settings.saved_filters_find(pane.filter_library, word.name)
		if !found {continue}
		token := settings.filter_token_format(buffer[:], filter.id, word.off)
		strings.write_string(&resolved, text[copied:word.start])
		strings.write_string(&resolved, token)
		copied = word.end
		grown := len(token) - (word.end - word.start)
		if f.cursor >= word.end {grown_cursor += grown}
		if f.anchor >= word.end {grown_anchor += grown}
	}
	if copied == 0 {return}
	strings.write_string(&resolved, text[copied:])
	cursor, anchor := f.cursor + grown_cursor, f.anchor + grown_anchor
	if ui.field_set(f, strings.to_string(resolved)) != nil {return}
	f.cursor, f.anchor = cursor, anchor
}

@(private = "file")
changes_filter_problem_text :: proc(problem: settings.Saved_Filter_Problem) -> string {
	switch problem {
	case .Id:
		return "A saved filter has an id that is not valid."
	case .Name:
		return "A saved filter's name cannot hold ; | or quotes."
	case .Duplicate:
		return "A saved filter already has that name."
	case .Pattern:
		return "A saved filter holds up to 120 characters without ; or quotes."
	case .Too_Long:
		return "The saved filters are too long to store."
	}
	return ""
}

// Saves the field's plain terms as a saved filter and replaces them in the field with the filter as a token
// that is on. The filter has no name, so its token shows the terms; a filter already saved with these terms
// is reused. A refusal says why under the field and keeps the text as it was.
@(private)
changes_filter_save :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	if !pane.filter_savable {return}
	changes_filter_typing_end(app, w, pane)
	pattern := strings.clone(changes_filter_plain(pane), context.temp_allocator)
	id := ""
	if saved, _, found := settings.saved_filters_find_pattern(app.settings.turns.saved_filters, pattern); found {
		id = strings.clone(saved.id, context.temp_allocator)
	} else {
		drafts := make([dynamic]settings.Saved_Filter_Draft, context.temp_allocator)
		cursor := settings.saved_filters_scan(app.settings.turns.saved_filters)
		for filter in settings.saved_filters_next(&cursor) {
			draft := settings.Saved_Filter_Draft{filter.id, filter.name, filter.pattern, filter.default}
			_, _ = append(&drafts, draft)
		}
		id = settings.saved_filter_id_make(drafts[:])
		_, _ = append(&drafts, settings.Saved_Filter_Draft{id, "", pattern, false})
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
	}
	words := make([dynamic]string, context.temp_allocator)
	text := changes_filter_text(pane)
	for token in pane.filter_tokens {
		if token.id != id {_, _ = append(&words, text[token.start:token.end])}
	}
	buffer: [settings.SAVED_FILTER_ID_LEN + 8]u8
	_, _ = append(&words, settings.filter_token_format(buffer[:], id, false))
	joined, _ := strings.join(words[:], " ", context.temp_allocator)
	changes_filter_splice(app, w, pane, 0, len(text), joined, len(joined))
}

// Closes the popover and opens Settings on the saved filters.
@(private)
changes_filter_manage :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) {
	changes_filter_popover(app, w, pane, false)
	settings_reveal(app, w, {key = settings.SAVED_FILTERS_KEY, search = .Clear, focus = .Control})
}

// Down in an empty field opens the saved filters list, as the @ button does.
@(private)
changes_filter_open_list_by_key :: proc(app: ^App, w: ^Window, pane: ^Changes_Pane) -> bool {
	if pane.filter_typing || changes_filter_text(pane) != "" {return false}
	changes_filter_list_toggle(app, w, pane)
	return true
}

// Applies an editing key to the field; false when it was none.
@(private)
changes_filter_key_edit :: proc(
	app: ^App, w: ^Window, pane: ^Changes_Pane, logical: input.Key_Event,
) -> bool {
	edit := field_edit_key(app, &pane.filter_editor, logical)
	switch edit.change {
	case .Edited:
		changes_filter_typing(pane, edit.pasted)
		changes_filter_edited(app, w, pane)
	case .Moved:
		if pane.filter_pending >= 0 {changes_filter_typing_end(app, w, pane)}
		w.dirty = true
	case .None:
		return false
	}
	return true
}

// The filter a new Agent changes pane starts with: every saved filter marked on by default, as on tokens, in
// the library's order; temporary memory.
@(private)
changes_default_filter :: proc(app: ^App) -> string {
	text, _ := settings.saved_filters_default_text(app.settings.turns.saved_filters, context.temp_allocator)
	return text
}
