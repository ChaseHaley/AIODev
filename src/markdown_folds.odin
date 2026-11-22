package main

import "aio:markdown"
import "aio:views"
import "core:strings"

// Collapsed headings in a Markdown pane (WORK-447): a heading's chevron folds its section, everything up
// to the next heading of the same level or above, in reading and editing alike. A fold is kept by the
// heading's text and which of the headings with that text it is, so it outlasts reloads and edits
// elsewhere in the file.

Markdown_Fold :: struct {
	// Owned.
	text: string,
	nth:  int,
}

// A pane's folds and, by block of the document it shows, which headings they collapse.
Markdown_Folds :: struct {
	folds:    [dynamic]Markdown_Fold,
	folded:   [dynamic]bool,
	// The pane revision `folded` was worked out for.
	revision: u64,
}

markdown_folds_destroy :: proc(f: ^Markdown_Folds) {
	for fold in f.folds {delete(fold.text)}
	delete(f.folds)
	delete(f.folded)
	f^ = {}
}

// A heading's text without the markup the caret's line shows, so a heading folds the same whether or
// not the caret is on it.
@(private = "file")
heading_text :: proc(doc: ^markdown.Document, block: markdown.Block) -> string {
	out := strings.builder_make(context.temp_allocator)
	for span in doc.spans[block.first_span:][:block.span_count] {
		if .Markup not_in span.style {strings.write_string(&out, string(doc.text[span.start:span.end]))}
	}
	return strings.trim_space(strings.to_string(out))
}

// The fold key of each heading block, by block; other blocks have nth -1. Temporary.
@(private = "file")
heading_keys :: proc(doc: ^markdown.Document) -> []Markdown_Fold {
	keys := make([]Markdown_Fold, len(doc.blocks), context.temp_allocator)
	seen := make(map[string]int, allocator = context.temp_allocator)
	for block, index in doc.blocks {
		keys[index].nth = -1
		if block.kind != .Heading {continue}
		text := heading_text(doc, block)
		keys[index] = {text, seen[text]}
		seen[text] += 1
	}
	return keys
}

@(private = "file")
fold_index :: proc(f: ^Markdown_Folds, key: Markdown_Fold) -> int {
	for fold, index in f.folds {if fold.nth == key.nth && fold.text == key.text {return index}}
	return -1
}

// Works out which blocks of the shown document are folded headings, once per pane revision.
markdown_folds_sync :: proc(pane: ^Markdown_Pane) {
	f := &pane.folds
	document := markdown_document(pane)
	if document == nil {
		clear(&f.folded)
		return
	}
	if f.revision == pane.revision && len(f.folded) == len(document.blocks) {return}
	f.revision = pane.revision
	resize(&f.folded, len(document.blocks))
	if len(f.folds) == 0 {
		for &folded in f.folded {folded = false}
		return
	}
	for key, index in heading_keys(document) {f.folded[index] = key.nth >= 0 && fold_index(f, key) >= 0}
}

// Folds or unfolds heading block `heading` of the shown document.
markdown_fold_toggle :: proc(pane: ^Markdown_Pane, heading: int) {
	document := markdown_document(pane)
	if document == nil || heading < 0 || heading >= len(document.blocks) {return}
	key := heading_keys(document)[heading]
	if key.nth < 0 {return}
	f := &pane.folds
	if at := fold_index(f, key); at >= 0 {
		delete(f.folds[at].text)
		ordered_remove(&f.folds, at)
	} else {
		owned, err := strings.clone(key.text)
		if err != nil {return}
		if _, append_error := append(&f.folds, Markdown_Fold{owned, key.nth}); append_error != nil {
			delete(owned)
			return
		}
	}
	pane.revision += 1
}

// The folded heading whose section hides block `block`, or -1 when it shows.
@(private = "file")
fold_covering :: proc(document: ^markdown.Document, folded: []bool, block: int) -> int {
	cover, level := -1, 0
	for current, index in document.blocks[:block + 1] {
		if cover >= 0 && current.kind == .Heading && current.level <= level {cover = -1}
		if index == block {return cover}
		if cover < 0 && current.kind == .Heading && index < len(folded) && folded[index] {
			cover, level = index, current.level
		}
	}
	return -1
}

// Unfolds whatever hides the text at `offset` of the shown document, as a jump to a heading or a caret
// moving into a folded section needs. Returns whether anything unfolded.
markdown_fold_reveal :: proc(pane: ^Markdown_Pane, offset: int) -> bool {
	document := markdown_document(pane)
	if document == nil || len(pane.folds.folds) == 0 {return false}
	block := markdown.block_at(document, offset)
	if block < 0 {return false}
	revealed := false
	for {
		markdown_folds_sync(pane)
		cover := fold_covering(document, pane.folds.folded[:], block)
		if cover < 0 {return revealed}
		markdown_fold_toggle(pane, cover)
		revealed = true
	}
}

// The pane's view laid out for the document it shows, folds included, as its draw lays it out.
markdown_view_fitted :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	document: ^markdown.Document,
	g: views.Markdown_Geometry,
) {
	markdown_folds_sync(pane)
	views.markdown_view_fit(
		&pane.view, document, pane.revision, &w.ui_text, app.family, g.width, w.scale, pane.folds.folded[:],
		app.markdown_style,
	)
}
