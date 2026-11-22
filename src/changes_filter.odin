package main

import "cosmos:line_match"
import "aio:settings"
import "aio:ui"
import "core:fmt"
import "core:strings"

// The diff filter of an Agent changes pane: words separated by spaces. A plain word is a case-insensitive
// regular expression on a file's path as the diff header shows it, matched by find's rules; a file shows
// when it matches every plain word and no `!word`. A word `@id` is a token that refers to a saved filter
// (`turns.saved_filters`) by its id, `~@id` one that is off: a token that is on adds the saved filter's own
// words to the terms, so a file must pass the text and every token that is on. The pill shows the filter's
// current name, so renaming or editing a filter in Settings changes every pane at once.
// Empty text shows every file.

Changes_Filter_Term :: struct {
	matcher: line_match.Matcher,
	exclude: bool,
}

Changes_Filter :: struct {
	terms: [dynamic]Changes_Filter_Term,
}

changes_filter_destroy :: proc(f: ^Changes_Filter) {
	for &term in f.terms {line_match.destroy(&term.matcher)}
	delete(f.terms)
	f^ = {}
}

// Adds the term `word` stands for. A lone `!` is no term.
@(private = "file", require_results)
changes_filter_term_add :: proc(f: ^Changes_Filter, word: string) -> (ok: bool, error: string) {
	exclude := word[0] == '!'
	pattern := exclude ? word[1:] : word
	if pattern == "" {return true, ""}
	term := Changes_Filter_Term {
		exclude = exclude,
	}
	// The matcher keeps a copy of the pattern even when it fails to compile.
	switch line_match.init(&term.matcher, pattern, {regex = true}) {
	case .Ok:
	case .Invalid:
		line_match.destroy(&term.matcher)
		return false, fmt.tprintf("Invalid regular expression: %s", word)
	case .Out_Of_Memory:
		line_match.destroy(&term.matcher)
		return false, "Out of memory."
	}
	if _, err := append(&f.terms, term); err != nil {
		line_match.destroy(&term.matcher)
		return false, "Out of memory."
	}
	return true, ""
}

// Replaces the terms with those of `text`, resolving its tokens against `library` (the saved filters' setting
// value) and listing them in `tokens` when it is given. A term that does not compile, in the text or in the
// pattern of a token that is on, leaves the filter empty, so it hides nothing, and `error` names it; a token
// referring to no saved filter adds nothing. `error` is in temporary memory. The words from `pending_from` to
// `pending_to` are an `@` still being typed, which is neither a token nor a term yet.
@(require_results)
changes_filter_set :: proc(
	f: ^Changes_Filter,
	text: string,
	library := "",
	tokens: ^[dynamic]ui.Filter_Token = nil,
	pending_from := -1,
	pending_to := -1,
) -> (
	ok: bool,
	error: string,
) {
	changes_filter_destroy(f)
	if tokens != nil {clear(tokens)}
	at := 0
	for {
		word, more := settings.filter_word_next(text, at)
		if !more {break}
		at = word.end
		if word.start < pending_to && word.end > pending_from {continue}
		if !word.token {
			if error != "" {continue}
			term_ok, term_error := changes_filter_term_add(f, text[word.start:word.end])
			if !term_ok {error = term_error}
			continue
		}
		token := ui.Filter_Token {
			start = word.start,
			end   = word.end,
			id    = word.name,
			name  = word.name,
			off   = word.off,
		}
		filter, _, known := settings.saved_filters_find_id(library, word.name)
		if known {token.name = settings.saved_filter_label(filter)}
		switch {
		case !known:
			token.state = .Unknown
		case !word.off && error == "":
			rest := filter.pattern
			for pattern in strings.fields_iterator(&rest) {
				term_ok, term_error := changes_filter_term_add(f, pattern)
				if term_ok {continue}
				token.state = .Invalid
				error = fmt.tprintf("%s (in saved filter %s)", term_error, token.name)
				break
			}
		}
		if tokens != nil {_, _ = append(tokens, token)}
	}
	if error != "" {
		changes_filter_destroy(f)
		return false, error
	}
	return true, ""
}

// Whether a file with `path` passes every term. A renamed or copied file also goes by `old_path`: a term
// matches it when it matches either path.
@(require_results)
changes_filter_shows :: proc(f: ^Changes_Filter, path: string, old_path := "") -> bool {
	for &term in f.terms {
		line_match.begin(&term.matcher, path)
		_, _, found := line_match.next(&term.matcher)
		if !found && old_path != "" {
			line_match.begin(&term.matcher, old_path)
			_, _, found = line_match.next(&term.matcher)
		}
		if found == term.exclude {return false}
	}
	return true
}

// A pane's filter text: what its field holds.
@(require_results)
changes_filter_text :: proc(pane: ^Changes_Pane) -> string {
	return ui.field_string(&pane.filter_editor)
}

// Parses the pane's filter text and shows the result in the view's filter state. The tokens become the
// field's atoms, so the caret and Backspace treat each as one character.
@(private)
changes_filter_parse :: proc(pane: ^Changes_Pane) {
	from, to := -1, -1
	if pane.filter_typing && pane.filter_pending >= 0 {from, to = pane.filter_pending, pane.filter_editor.cursor}
	ok, error := changes_filter_set(
		&pane.filter, changes_filter_text(pane), pane.filter_library, &pane.filter_tokens, from, to,
	)
	clear(&pane.filter_atoms)
	for token in pane.filter_tokens {_, _ = append(&pane.filter_atoms, ui.Field_Atom{token.start, token.end})}
	pane.filter_editor.atoms = pane.filter_atoms[:]
	delete(pane.filter_error)
	pane.filter_error = ""
	if error != "" {pane.filter_error, _ = strings.clone(error)}
	delete(pane.filter_notice)
	pane.filter_notice = ""
	changes_filter_picks_build(pane)
	view := &pane.model.view
	view.filter_invalid = !ok
	view.filter_active = ok && len(pane.filter.terms) > 0
	view.filter_error = pane.filter_error
	view.filter_unknown = ""
	for token in pane.filter_tokens {
		if token.state == .Unknown {
			view.filter_unknown = token.name
			break
		}
	}
	pane.filter_savable = ok && changes_filter_plain(pane) != ""
	changes_filter_on_labels(pane)
	changes_filter_view(pane)
}

// What the bar under the header row names as filtering: the tokens that are on, `@one + @two`, and "filter
// text" after them when the text holds terms too; "" while no token is on.
@(private = "file")
changes_filter_on_labels :: proc(pane: ^Changes_Pane) {
	delete(pane.filter_on_labels)
	pane.filter_on_labels = ""
	b := strings.builder_make(context.temp_allocator)
	for token in pane.filter_tokens {
		if token.off || token.state == .Unknown {continue}
		if strings.builder_len(b) > 0 {strings.write_string(&b, " + ")}
		strings.write_byte(&b, '@')
		strings.write_string(&b, token.name)
	}
	if strings.builder_len(b) == 0 {return}
	if changes_filter_plain(pane) != "" {strings.write_string(&b, " + filter text")}
	pane.filter_on_labels, _ = strings.clone(strings.to_string(b))
}

// Points the view at the pane's token and list state, which a frame draws from. The parse computes
// everything else.
@(private)
changes_filter_view :: proc(pane: ^Changes_Pane) {
	view := &pane.model.view
	view.filter_editor = &pane.filter_editor
	view.filter_tokens = pane.filter_tokens[:]
	view.filter_pick_open = pane.filter_typing
	view.filter_picks = pane.filter_picks[:]
	view.filter_pick_row = pane.filter_pick_row
	view.filter_notice = pane.filter_notice
	view.filter_savable = pane.filter_savable
	view.filter_on_labels = pane.filter_on_labels
}

// The filter text changed: files picked past the old filter hide again, and the view shows what the new
// one lets through.
changes_filter_changed :: proc(pane: ^Changes_Pane) {
	changes_filter_parse(pane)
	for path in pane.revealed {delete(path)}
	clear(&pane.revealed)
	changes_model_refilter(pane)
}

// Shows a file the filter hides, until the filter text changes.
changes_filter_reveal :: proc(pane: ^Changes_Pane, path: string) {
	if path in pane.revealed {return}
	key, err := strings.clone(path)
	if err != nil {return}
	pane.revealed[key] = {}
	changes_model_refilter(pane)
}

// Frees the pane's filter, its field and the files picked past it.
@(private)
changes_filter_release :: proc(pane: ^Changes_Pane) {
	changes_filter_destroy(&pane.filter)
	delete(pane.filter_editor.bytes)
	delete(pane.filter_error)
	delete(pane.filter_notice)
	delete(pane.filter_library)
	delete(pane.filter_on_labels)
	delete(pane.filter_tokens)
	delete(pane.filter_atoms)
	delete(pane.filter_picks)
	for path in pane.revealed {delete(path)}
	delete(pane.revealed)
	pane.filter_editor, pane.revealed = {}, nil
	pane.filter_error, pane.filter_notice, pane.filter_library, pane.filter_on_labels = "", "", "", ""
	pane.filter_tokens, pane.filter_atoms, pane.filter_picks = nil, nil, nil
}
