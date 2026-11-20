package main

import "aio:line_match"
import "aio:ui"
import "core:fmt"
import "core:strings"

// The diff filter of an Agent changes pane: space-separated terms, each a case-insensitive regular
// expression on a file's path as the diff header shows it, matched by find's rules. A file shows when it
// matches every plain term and no `!term`; no terms show every file.

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

// Replaces the terms with those of `text`. A term that does not compile leaves the filter empty, so it
// hides nothing, and `error` names it; `error` is in temporary memory. A lone `!` is no term.
@(require_results)
changes_filter_set :: proc(f: ^Changes_Filter, text: string) -> (ok: bool, error: string) {
	changes_filter_destroy(f)
	rest := text
	for word in strings.fields_iterator(&rest) {
		exclude := word[0] == '!'
		pattern := exclude ? word[1:] : word
		if pattern == "" {continue}
		term := Changes_Filter_Term {
			exclude = exclude,
		}
		// The matcher keeps a copy of the pattern even when it fails to compile.
		switch line_match.init(&term.matcher, pattern, {regex = true}) {
		case .Ok:
		case .Invalid:
			line_match.destroy(&term.matcher)
			changes_filter_destroy(f)
			return false, fmt.tprintf("Invalid regular expression: %s", word)
		case .Out_Of_Memory:
			line_match.destroy(&term.matcher)
			changes_filter_destroy(f)
			return false, "Out of memory."
		}
		if _, err := append(&f.terms, term); err != nil {
			line_match.destroy(&term.matcher)
			changes_filter_destroy(f)
			return false, "Out of memory."
		}
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

// Parses the pane's filter text and shows the result in the view's filter state.
@(private)
changes_filter_parse :: proc(pane: ^Changes_Pane) {
	ok, error := changes_filter_set(&pane.filter, changes_filter_text(pane))
	delete(pane.filter_error)
	pane.filter_error = ""
	if error != "" {pane.filter_error, _ = strings.clone(error)}
	view := &pane.model.view
	view.filter_invalid = !ok
	view.filter_active = ok && len(pane.filter.terms) > 0
	view.filter_error = pane.filter_error
	view.filter_editor = &pane.filter_editor
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
	for path in pane.revealed {delete(path)}
	delete(pane.revealed)
	pane.filter_editor, pane.filter_error, pane.revealed = {}, "", nil
}
