package main

import "aio:layout"
import "aio:markdown"
import "aio:ui"
import "core:log"
import "core:os"
import "core:time"
import "cosmos:textedit"

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
	buffer:         textedit.Buffer,
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
	textedit.destroy(&e.buffer)
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
	if err != nil || !textedit.init(&e.buffer, string(loaded.source)) {
		if e != nil {markdown_editor_destroy(e)}
		notify(app, .Error, "Could not edit the file.")
		return
	}
	e.goal_x = -1
	top := 0
	if shown, found := markdown_pane_rect(w, pane.id); found {
		g := markdown_geometry_of(app, w, shown)
		top = ui.markdown_offset_at(&pane.view, &loaded.document, g, g.left, g.area.y)
	}
	// The properties stay rendered: the caret starts in the text below them.
	text := textedit.to_string(&e.buffer)
	body := e.buffer.floor + markdown.frontmatter_end(text[e.buffer.floor:])
	textedit.move(&e.buffer, max(body, markdown.document_source(&loaded.document, top)))
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
		if markdown.parse(textedit.to_string(&e.buffer), &next) {
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
	// A new editor numbers its revisions from the start again, so nothing may stay marked as followed.
	for other in app.markdown_panes {
		if other.followed.editor == pane.id {other.followed = {}}
	}
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
	from, to := textedit.selection(b)
	first, last := textedit.line_start(b, from), textedit.line_end(b, to)
	if !e.built || e.built_revision != b.revision || e.built_from != first || e.built_to != last {
		if !markdown.live_build(&e.live, textedit.to_string(b), first, last, &e.document) {
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

// After an edit: the live view follows, panes reading the file follow it too, and the file saves once
// typing pauses.
@(private = "file")
markdown_edited :: proc(app: ^App, pane: ^Markdown_Pane) {
	e := pane.editor
	e.save_at = time.tick_add(clock_now(&app.clock), MARKDOWN_SAVE_DELAY)
	e.goal_x, e.reveal = -1, true
	markdown_editor_sync(pane)
	for other in app.markdown_panes {
		if other != pane && other.editor == nil && document_same(other.path, pane.path) {
			// The reader may be in another window.
			mark_all_dirty(app)
			break
		}
	}
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
		stamp := Markdown_Stamp{info.modification_time, info.size}
		if loaded, ok := &pane.load.(Markdown_Loaded); ok {loaded.stamp = stamp}
		// A reading pane that shows these very edits has nothing to read back either.
		for other in app.markdown_panes {
			if loaded, ok := &other.load.(Markdown_Loaded); ok && other.followed == {pane.id, e.buffer.revision} {
				loaded.stamp = stamp
			}
		}
	}
	return true
}

// What a reading pane shows of an editor's text: the editing pane and the buffer's revision.
Markdown_Followed :: struct {
	editor:   u32,
	revision: u64,
}

// A pane reading a file that another pane edits shows the edits as they are made, not once they are
// saved and the poll reads them: the next draw parses the editor's text for it. Panes that edit the
// same file keep their own text.
@(private)
markdown_follow_edits :: proc(app: ^App, pane: ^Markdown_Pane) {
	loaded, ok := &pane.load.(Markdown_Loaded)
	if !ok || pane.editor != nil {return}
	for other in app.markdown_panes {
		e := other.editor
		if e == nil || other == pane || !document_same(other.path, pane.path) {continue}
		followed := Markdown_Followed{other.id, e.buffer.revision}
		if pane.followed == followed {return}
		next: markdown.Document
		if !markdown.parse(textedit.to_string(&e.buffer), &next) {
			log.error("parsing the Markdown edits for another pane ran out of memory")
			return
		}
		source, cloned := clone_bytes(e.buffer.text[:])
		if !cloned {
			markdown.document_destroy(&next)
			return
		}
		markdown.document_destroy(&loaded.document)
		delete(loaded.source)
		loaded.document, loaded.source = next, source
		pane.revision += 1
		pane.followed = followed
		ui.markdown_selection_clear(&pane.view)
		markdown.search_restart(&pane.search)
		return
	}
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
	if e.save_at == {} && !textedit.reset(&e.buffer, string(loaded.source)) {return}
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
	kind := text_edit_type(&pane.editor.buffer, text)
	if kind == .Edited {markdown_edited(app, pane)}
	return kind != .Ignored
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

// Moves the caret to the text under a point, or extends the selection to it. Returns where the caret is.
@(private)
markdown_edit_point :: proc(
	w: ^Window,
	pane: ^Markdown_Pane,
	g: ui.Markdown_Geometry,
	x, y: f32,
	extend: bool,
) -> int {
	e := pane.editor
	offset := ui.markdown_offset_at(&pane.view, &e.document, g, x, y)
	textedit.move(&e.buffer, markdown.live_source(&e.document, offset), extend)
	e.goal_x = -1
	markdown_editor_sync(pane)
	w.dirty = true
	return e.buffer.caret
}

// Selects the word or line at source offset `at`, as a double or triple click does, and returns the
// range. The pointer's own position is not asked: the click that placed `at` has since changed the layout.
@(private)
markdown_edit_unit :: proc(
	w: ^Window,
	pane: ^Markdown_Pane,
	unit: textedit.Unit,
	at: int,
) -> (
	from, to: int,
) {
	e := pane.editor
	from, to = textedit.unit_at(&e.buffer, at, unit)
	e.buffer.anchor, e.buffer.caret = from, to
	e.goal_x = -1
	markdown_editor_sync(pane)
	w.dirty = true
	return
}

// A drag after a double or triple click: the selection is the unit the click selected, `from`..`to`,
// grown by whole units to the one under the point.
@(private)
markdown_edit_unit_drag :: proc(
	w: ^Window,
	pane: ^Markdown_Pane,
	g: ui.Markdown_Geometry,
	x, y: f32,
	unit: textedit.Unit,
	from, to: int,
) {
	e := pane.editor
	offset := ui.markdown_offset_at(&pane.view, &e.document, g, x, y)
	textedit.select_unit(&e.buffer, from, to, unit, markdown.live_source(&e.document, offset))
	e.goal_x = -1
	markdown_editor_sync(pane)
	w.dirty = true
}

// The pane laid out as its next draw lays it out, so keys that move by lines see the lines shown.
@(private = "file")
markdown_edit_fitted :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane) -> (ui.Markdown_Geometry, bool) {
	shown, found := markdown_pane_rect(w, pane.id)
	if !found {return {}, false}
	g := markdown_geometry_of(app, w, shown)
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
	display := markdown.live_display(&e.document, e.buffer.caret)
	rect, row, found := ui.markdown_caret_at(view, &e.document, display)
	if !found {return}
	// The row's own extent, not the caret's, which is only text high on a blank line's gap.
	row_top, row_height := ui.markdown_line_band(view, row)
	x := e.goal_x >= 0 ? e.goal_x : rect.x
	y := row_top + row_height / 2
	if pages != 0 {
		page := g.area.height - f32(ui.markdown_line(view))
		y += f32(pages) * page
		_ = ui.markdown_scroll_by(view, int(f32(pages) * page), int(g.area.height))
	} else {
		y = lines < 0 ? row_top - 1 : row_top + row_height + 1
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
	textedit.move(&e.buffer, target, extend)
	markdown_editor_sync(pane)
	e.goal_x, e.reveal = x, true
}

// Home or End: to the start or end of the caret's row as the pane lays it out, which differs from the
// line's on a soft-wrapped one; the shared rules take it from there.
@(private = "file")
markdown_edit_row_edge :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane, end, extend: bool) {
	e := pane.editor
	b := &e.buffer
	row_start, row_end := textedit.line_start(b, b.caret), textedit.line_end(b, b.caret)
	if _, fitted := markdown_edit_fitted(app, w, pane); fitted {
		document := &e.document
		display := markdown.live_display(document, b.caret)
		if start, stop, found := ui.markdown_row_edges(&pane.view, document, display); found {
			row_start, row_end = markdown.live_source(document, start), markdown.live_source(document, stop)
		}
	}
	target := end ? textedit.end_target(b, row_end) : textedit.home_target(b, row_start)
	textedit.move(b, target, extend)
}

// The keys of a pane in edit mode. False for keys it leaves to shortcuts and the pane.
@(require_results)
markdown_edit_key :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane, key: Content_Key) -> bool {
	e := pane.editor
	result := text_edit_key(app, &e.buffer, key)
	switch result.kind {
	case .Ignored:
		return false
	case .Handled:
	case .Moved:
		e.goal_x, e.reveal = -1, true
		markdown_editor_sync(pane)
	case .Edited:
		markdown_edited(app, pane)
	case .Vertical:
		markdown_edit_vertical(app, w, pane, result.lines, result.pages, result.extend)
	case .Row_Edge:
		markdown_edit_row_edge(app, w, pane, result.end, result.extend)
		e.goal_x, e.reveal = -1, true
		markdown_editor_sync(pane)
	case .Scroll:
		if shown, found := markdown_pane_rect(w, pane.id); found {
			markdown_scroll(w, pane, shown, result.lines * ui.markdown_line(&pane.view))
		}
	}
	w.dirty = true
	return true
}

// A right-click on the page's text in edit mode: the caret goes to the pointer first unless the point is
// inside the selection, which stays, and then the edit menu opens there.
@(private)
markdown_edit_menu_open :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	g: ui.Markdown_Geometry,
	x, y: f32,
) {
	e := pane.editor
	at := markdown.live_source(&e.document, ui.markdown_offset_at(&pane.view, &e.document, g, x, y))
	from, to := textedit.selection(&e.buffer)
	if from == to || at < from || at > to {
		textedit.move(&e.buffer, at)
		e.goal_x = -1
		markdown_editor_sync(pane)
	}
	edit_menu_open(app, w, pane.id, &e.buffer, x, y)
}

// A choice from the edit menu, applied to the text of the pane it was opened for.
@(private)
markdown_edit_command :: proc(app: ^App, w: ^Window, id: u32, command: Text_Edit_Command) {
	pane := markdown_find(app, id)
	if !markdown_editing(pane) {return}
	e := pane.editor
	#partial switch text_edit_command(app, &e.buffer, command) {
	case .Edited:
		markdown_edited(app, pane)
	case .Moved:
		e.goal_x, e.reveal = -1, true
		markdown_editor_sync(pane)
	}
	w.dirty = true
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
