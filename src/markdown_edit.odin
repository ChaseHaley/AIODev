package main

import "aio:layout"
import "aio:markdown"
import "aio:platform"
import "aio:ui"
import "core:log"
import "core:os"
import "core:time"
import "core:unicode/utf8"

// Editing a Markdown pane's file in place, shown as Obsidian's Live Preview shows it (WORK-441,
// D-094): every line rendered but the caret's. Edits save shortly after typing stops.

// How long after the last edit the file saves, as Obsidian waits.
@(private)
MARKDOWN_SAVE_DELAY :: 1 * time.Second
// After a failed save, when to try again.
@(private)
MARKDOWN_SAVE_RETRY :: 5 * time.Second

// A pane in edit mode: the file's text being edited and the live preview the pane shows of it. Owned by
// its pane.
Markdown_Editor :: struct {
	buffer:         markdown.Edit_Buffer,
	live:           markdown.Live,
	document:       markdown.Document,
	// What `document` was built for: the buffer's revision and the lines the selection touches.
	built_revision: u64,
	built_from:     int,
	built_to:       int,
	built:          bool,
	// When the edits save; zero while nothing waits to be saved.
	save_at:        time.Tick,
	// A failed save was reported, so retries stay quiet until one succeeds.
	save_failed:    bool,
	// Where Up and Down keep the caret across shorter lines, in the view's coordinates; negative once a
	// sideways move or an edit sets a new one.
	goal_x:         f32,
	// The caret moved, so the next draw scrolls it into view.
	reveal:         bool,
}

@(private)
markdown_editor_destroy :: proc(e: ^Markdown_Editor) {
	markdown.edit_buffer_destroy(&e.buffer)
	markdown.live_destroy(&e.live)
	markdown.document_destroy(&e.document)
	free(e)
}

// Whether the pane is editing its file.
@(require_results)
markdown_editing :: proc(pane: ^Markdown_Pane) -> bool {
	return pane != nil && pane.editor != nil
}

// Edit Markdown: turns the focused pane's edit mode on or off.
markdown_edit_toggle :: proc(app: ^App, w: ^Window) {
	pane := markdown_focused(app, w)
	if pane == nil {return}
	if pane.editor != nil {
		markdown_edit_end(app, pane)
	} else {
		markdown_edit_begin(app, w, pane)
	}
	w.dirty = true
}

// Starts editing the loaded file with the caret at the top of what the pane shows.
@(private = "file")
markdown_edit_begin :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane) {
	loaded, ok := &pane.load.(Markdown_Loaded)
	if !ok {
		notify(app, .Info, "Only a file the pane shows can be edited.")
		return
	}
	e, err := new(Markdown_Editor)
	if err != nil || !markdown.edit_buffer_init(&e.buffer, string(loaded.source)) {
		if e != nil {markdown_editor_destroy(e)}
		notify(app, .Error, "Could not edit the file.")
		return
	}
	e.goal_x = -1
	top := 0
	if shown, found := markdown_pane_rect(w, pane.id); found {
		g := markdown_geometry_of(w, shown)
		top = ui.markdown_offset_at(&pane.view, &loaded.document, g, g.left, g.area.y)
	}
	// The properties stay rendered: the caret starts in the text below them.
	text := markdown.edit_string(&e.buffer)
	body := e.buffer.floor + markdown.frontmatter_end(text[e.buffer.floor:])
	markdown.edit_move(&e.buffer, max(body, markdown.document_source(&loaded.document, top)))
	e.reveal = true
	pane.editor = e
	ui.markdown_selection_clear(&pane.view)
	markdown_editor_sync(pane)
}

// Saves what waits to be saved and shows the file as read again.
@(private)
markdown_edit_end :: proc(app: ^App, pane: ^Markdown_Pane) {
	e := pane.editor
	if e == nil {return}
	if e.save_at != {} && !markdown_edit_save(app, pane) {
		notify(app, .Error, "Could not save the file; it stays in edit mode.")
		return
	}
	// The reading view parses what was saved, which the poll would otherwise read only when the stamp
	// it keeps changes.
	if loaded, ok := &pane.load.(Markdown_Loaded); ok {
		next: markdown.Document
		if markdown.parse(markdown.edit_string(&e.buffer), &next) {
			source, cloned := clone_bytes(e.buffer.text[:])
			if cloned {
				markdown.document_destroy(&loaded.document)
				delete(loaded.source)
				loaded.document, loaded.source = next, source
			} else {
				markdown.document_destroy(&next)
			}
		}
	}
	pane.editor = nil
	markdown_editor_destroy(e)
	pane.revision += 1
	ui.markdown_selection_clear(&pane.view)
	markdown.search_restart(&pane.search)
}

@(private = "file")
clone_bytes :: proc(bytes: []u8) -> ([]u8, bool) {
	out, err := make([]u8, len(bytes))
	if err != nil {return nil, false}
	copy(out, bytes)
	return out, true
}

// Rebuilds the live document when the text or the lines the selection touches changed, and shows
// the selection in it.
@(private)
markdown_editor_sync :: proc(pane: ^Markdown_Pane) {
	e := pane.editor
	if e == nil {return}
	b := &e.buffer
	from, to := markdown.edit_selection(b)
	first, last := markdown.edit_line_start(b, from), markdown.edit_line_end(b, to)
	if !e.built || e.built_revision != b.revision || e.built_from != first || e.built_to != last {
		if !markdown.live_build(&e.live, markdown.edit_string(b), first, last, &e.document) {
			log.error("building the Markdown edit view ran out of memory")
		}
		e.built, e.built_revision, e.built_from, e.built_to = true, b.revision, first, last
		pane.revision += 1
		markdown.search_restart(&pane.search)
	}
	ui.markdown_select_at(&pane.view, markdown.live_display(&e.document, b.anchor), false)
	caret := markdown.live_display(&e.document, b.caret)
	ui.markdown_select_at(&pane.view, caret, true)
	// A caret has nowhere to show in a folded section, so moving into one unfolds it.
	_ = markdown_fold_reveal(pane, caret)
}

// After an edit: the live view follows and the file saves once typing pauses.
@(private = "file")
markdown_edited :: proc(app: ^App, pane: ^Markdown_Pane) {
	e := pane.editor
	e.save_at = time.tick_add(clock_now(&app.clock), MARKDOWN_SAVE_DELAY)
	e.goal_x, e.reveal = -1, true
	markdown_editor_sync(pane)
}

// Writes the edits to the file. The stamp the poll compares becomes the written file's, so the pane
// does not read its own save back.
@(private)
markdown_edit_save :: proc(app: ^App, pane: ^Markdown_Pane) -> bool {
	e := pane.editor
	if write_error := os.write_entire_file(pane.path, e.buffer.text[:]); write_error != nil {
		log.errorf("saving the Markdown file failed: %v", write_error)
		e.save_at = time.tick_add(clock_now(&app.clock), MARKDOWN_SAVE_RETRY)
		if !e.save_failed {notify(app, .Error, "Could not save the file; trying again.")}
		e.save_failed = true
		return false
	}
	e.save_at, e.save_failed = {}, false
	if info, stat_error := os.stat(pane.path, context.temp_allocator); stat_error == nil {
		if loaded, ok := &pane.load.(Markdown_Loaded); ok {
			loaded.stamp = {info.modification_time, info.size}
		}
	}
	return true
}

// Saves the panes whose edits have waited long enough.
@(private)
markdown_saves_due :: proc(app: ^App, now: time.Tick) {
	for pane in app.markdown_panes {
		e := pane.editor
		if e == nil || e.save_at == {} {continue}
		if time.tick_diff(now, e.save_at) <= 0 {_ = markdown_edit_save(app, pane)}
	}
}

// The file changed on disk. Without edits waiting to save, the editor takes the new text; with them,
// the edits win and their save overwrites it.
@(private)
markdown_edit_reloaded :: proc(pane: ^Markdown_Pane) {
	e := pane.editor
	loaded, ok := &pane.load.(Markdown_Loaded)
	if e == nil || !ok {return}
	if e.save_at == {} && !markdown.edit_buffer_reset(&e.buffer, string(loaded.source)) {return}
	// The load cleared the view's selection either way.
	markdown_editor_sync(pane)
}

// Typed text goes in at the caret: a key's text from Windows, or text with no key of its own, such as an
// input method's. Control characters arrive as their keys instead.
markdown_text :: proc(app: ^App, w: ^Window, text: string) {
	pane := markdown_focused(app, w)
	if !markdown_editing(pane) {return}
	_ = markdown_type(app, pane, text)
	w.dirty = true
}

@(private = "file", require_results)
markdown_type :: proc(app: ^App, pane: ^Markdown_Pane, text: string) -> bool {
	if text == "" {return false}
	for r in text {
		if r < 0x20 || r == 0x7f {return false}
	}
	if markdown.edit_insert(&pane.editor.buffer, text, true) {markdown_edited(app, pane)}
	return true
}

// Ticks or clears the task whose mark is at file offset `mark`: an undoable edit while editing, else
// written to the file straight away.
@(private)
markdown_task_toggle :: proc(app: ^App, pane: ^Markdown_Pane, mark: int) {
	if e := pane.editor; e != nil {
		if markdown.edit_task_toggle(&e.buffer, mark) {markdown_edited(app, pane)}
		return
	}
	loaded, ok := &pane.load.(Markdown_Loaded)
	if !ok {return}
	// A file changed since it was read could have moved the mark; the poll shows the new text first.
	info, stat_error := os.stat(pane.path, context.temp_allocator)
	if stat_error != nil || (Markdown_Stamp{info.modification_time, info.size}) != loaded.stamp {
		notify(app, .Info, "The file changed on disk; it will be read again.")
		markdown_poll_soon(app)
		return
	}
	text, cloned := clone_bytes(loaded.source)
	if !cloned {return}
	defer delete(text)
	if !markdown.task_mark_flip(text, mark) {return}
	if write_error := os.write_entire_file(pane.path, text); write_error != nil {
		log.errorf("saving the Markdown task failed: %v", write_error)
		notify(app, .Error, "Could not save the file.")
		return
	}
	if markdown_pane_reload(pane) {mark_all_dirty(app)}
}

// Moves the caret to the text under a point, or extends the selection to it.
@(private)
markdown_edit_point :: proc(
	w: ^Window,
	pane: ^Markdown_Pane,
	g: ui.Markdown_Geometry,
	x, y: f32,
	extend: bool,
) {
	e := pane.editor
	offset := ui.markdown_offset_at(&pane.view, &e.document, g, x, y)
	markdown.edit_move(&e.buffer, markdown.live_source(&e.document, offset), extend)
	e.goal_x = -1
	markdown_editor_sync(pane)
	w.dirty = true
}

// The pane laid out as its next draw lays it out, so keys that move by lines see the lines shown.
@(private = "file")
markdown_edit_fitted :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane) -> (ui.Markdown_Geometry, bool) {
	shown, found := markdown_pane_rect(w, pane.id)
	if !found {return {}, false}
	g := markdown_geometry_of(w, shown)
	markdown_view_fitted(app, w, pane, &pane.editor.document, g)
	return g, true
}

// Up, Down, Page Up and Page Down: to the text `lines` lines (or `pages` viewports) away, keeping the
// caret's column across shorter lines.
@(private = "file")
markdown_edit_vertical :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	lines, pages: int,
	extend: bool,
) {
	e := pane.editor
	g, fitted := markdown_edit_fitted(app, w, pane)
	if !fitted {return}
	view := &pane.view
	rect, _, found := ui.markdown_caret_at(view, &e.document, markdown.live_display(&e.document, e.buffer.caret))
	if !found {return}
	x := e.goal_x >= 0 ? e.goal_x : rect.x
	y := rect.y + rect.height / 2
	if pages != 0 {
		page := g.area.height - f32(ui.markdown_line(view))
		y += f32(pages) * page
		_ = ui.markdown_scroll_by(view, int(f32(pages) * page), int(g.area.height))
	} else {
		y = lines < 0 ? rect.y - 1 : rect.y + rect.height + 1
	}
	target: int
	switch {
	case y < 0:
		target = e.buffer.floor
	case y >= view.height:
		target = len(e.buffer.text)
	case:
		target = markdown.live_source(&e.document, ui.markdown_offset_near(view, &e.document, x, y))
	}
	markdown.edit_move(&e.buffer, target, extend)
	markdown_editor_sync(pane)
	e.goal_x, e.reveal = x, true
}

// The keys of a pane in edit mode. False for keys it leaves to shortcuts and the pane.
@(require_results)
markdown_edit_key :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane, key: Content_Key) -> bool {
	e := pane.editor
	b := &e.buffer
	logical := key.logical
	modifiers := logical.modifiers & {.Control, .Shift, .Alt, .Super}
	// A character key types its text; Ctrl+Alt is AltGr, which types too. Ctrl and Alt alone make chords.
	typing := modifiers & {.Control, .Alt} == {} || modifiers & {.Control, .Alt} == {.Control, .Alt}
	if typing && .Super not_in modifiers && markdown_type(app, pane, logical.text) {
		w.dirty = true
		return true
	}
	if .Alt in modifiers || .Super in modifiers {return false}
	control, shift := .Control in modifiers, .Shift in modifiers
	switch key.clipboard {
	case .Copy:
		if text := markdown.edit_selected_text(b); text != "" {clipboard_copy(app, text)}
		return true
	case .Cut:
		if text := markdown.edit_selected_text(b); text != "" && clipboard_copy(app, text) {
			if markdown.edit_delete(b, false, false) {markdown_edited(app, pane)}
		}
		return true
	case .Paste:
		if text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator); ok {
			if markdown.edit_insert(b, markdown_line_endings(text, b.newline)) {markdown_edited(app, pane)}
		}
		return true
	case .None:
	}
	moved := true
	edited := false
	#partial switch logical.key {
	case .Z:
		if !control {return false}
		edited = shift ? markdown.edit_redo(b) : markdown.edit_undo(b)
	case .Y:
		if !control || shift {return false}
		edited = markdown.edit_redo(b)
	case .A:
		if !control || shift {return false}
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
		if control {return false}
		markdown_edit_vertical(app, w, pane, logical.key == .Arrow_Up ? -1 : 1, 0, shift)
		w.dirty = true
		return true
	case .Page_Up, .Page_Down:
		if control {return false}
		markdown_edit_vertical(app, w, pane, 0, logical.key == .Page_Up ? -1 : 1, shift)
		w.dirty = true
		return true
	case .Home:
		markdown.edit_move(b, control ? b.floor : markdown.edit_line_start(b, b.caret), shift)
	case .End:
		markdown.edit_move(b, control ? len(b.text) : markdown.edit_line_end(b, b.caret), shift)
	case .Backspace, .Delete:
		if shift {return false}
		edited = markdown.edit_delete(b, logical.key == .Delete, control)
	case .Enter, .Numpad_Enter:
		if control {return false}
		// Shift+Enter breaks the line without continuing a list.
		edited = shift ? markdown.edit_insert(b, b.newline) : markdown.edit_newline(b)
	case .Tab:
		if control {return false}
		edited = markdown.edit_indent(b, shift)
	case .Escape:
		if modifiers != {} {return false}
		markdown.edit_move(b, b.caret)
	case:
		moved = false
	}
	if !moved {return false}
	if edited {
		markdown_edited(app, pane)
	} else {
		e.goal_x, e.reveal = -1, true
		markdown_editor_sync(pane)
	}
	w.dirty = true
	return true
}

// Pasted text in the file's own line endings.
@(private = "file")
markdown_line_endings :: proc(text, newline: string) -> string {
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

// Where the caret draws in a pane's view this frame: -1 unless the pane edits and has the keyboard.
@(private)
markdown_caret_shown :: proc(w: ^Window, pane: ^Markdown_Pane, shown: layout.Pane_Rect) -> int {
	if !markdown_editing(pane) || !pane_shows_focus(w, shown) {return -1}
	return markdown.live_display(&pane.editor.document, pane.editor.buffer.caret)
}

// Open in Default App: hands the focused pane's file to the program Windows opens Markdown with.
markdown_open_external :: proc(app: ^App, w: ^Window) {
	pane := markdown_focused(app, w)
	if pane == nil {return}
	if e := pane.editor; e != nil && e.save_at != {} {_ = markdown_edit_save(app, pane)}
	document_link_open_external(app, w, pane.path)
}
