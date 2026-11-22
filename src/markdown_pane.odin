package main

import "cosmos:colour"
import "aio:commands"
import "cosmos:font"
import "cosmos:input"
import "aio:layout"
import "aio:links"
import "aio:localpath"
import "aio:markdown"
import "cosmos:platform"
import "cosmos:render"
import "cosmos:search"
import "aio:turns"
import "aio:views"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "cosmos:textedit"
import "cosmos:ui"
import "cosmos:host"

// Markdown panes: one local file per pane, read-only, reloaded when the file changes (WORK-319).

@(private)
MARKDOWN_POLL :: 500 * time.Millisecond
// Far beyond any real document; a larger file would stall the frame that lays it out.
@(private)
MARKDOWN_SIZE_LIMIT :: 16 * 1024 * 1024

// What a pane shows of its file. No variant: the path has not passed the local-file checks yet; a
// path from the saved layout may be gone or point anywhere, so the poll must not read it until it
// does. Only Loaded holds a document: a pane showing a message has nothing to draw, find or copy.
// The others keep the stamp they last saw, so the poll reads the file again only once it changes.
Markdown_Load :: union {
	Markdown_Missing,
	Markdown_Loaded,
	Markdown_Too_Large,
	Markdown_Failed,
}
Markdown_Missing :: struct {}
Markdown_Loaded :: struct {
	stamp:    Markdown_Stamp,
	document: markdown.Document,
	// The file's bytes as read, which a checkbox click and edit mode change (WORK-437, WORK-441).
	source:   []u8,
}
Markdown_Too_Large :: struct {
	stamp: Markdown_Stamp,
}
// Parsing ran out of memory.
Markdown_Failed :: struct {
	stamp: Markdown_Stamp,
}
Markdown_Stamp :: struct {
	modified: time.Time,
	size:     i64,
}

// The pointer's hold on a Markdown pane in one window. No variant: nothing held. Selecting runs from
// the press that places the anchor to the release. A held scrollbar thumb is a pane scrollbar drag
// (pane_scrollbar.odin).
Markdown_Gesture :: union {
	Markdown_Selecting,
}
// A double or triple click holds its `unit`, which the drag grows the selection by, around the source
// range `from`..`to` the click selected. The view scrolls a step each time `scroll` is due while the
// pointer is past the page's top or bottom edge.
Markdown_Selecting :: struct {
	pane:     u32,
	unit:     Maybe(textedit.Unit),
	from, to: int,
	scroll:   ui.Edge_Scroll,
}

// What the pointer is over among a window's Markdown panes: a link, or a pane's heading outline, whose
// panel is open while it is. One value, so one pane at most shows either. The scrollbar under the
// pointer is a pane scrollbar hover.
Markdown_Hover :: union {
	Markdown_Link_Hover,
	Markdown_Outline_Hover,
	Markdown_Fold_Hover,
}
Markdown_Link_Hover :: struct {
	pane: u32,
	link: int,
}
// The pointer is on the outline's bars or its open panel; `heading` is the one under it, -1 for none.
Markdown_Outline_Hover :: struct {
	pane:    u32,
	heading: int,
}
// The pointer is on a heading's line, which shows the chevron that folds it (markdown_folds.odin).
Markdown_Fold_Hover :: struct {
	pane:    u32,
	heading: int,
}

// A window's pointer state over its Markdown panes; Window embeds it and this file is its only writer.
Markdown_Pointer :: struct {
	markdown_gesture: Markdown_Gesture,
	markdown_hover:   Markdown_Hover,
	// The editor's text clicks, which count double and triple clicks.
	markdown_clicks:  ui.Click_Run,
}

// The app's Markdown panes, which windows refer to by id, and when the poll next reads their files.
// App embeds it; this file owns it, and markdown_app_destroy releases it.
Markdown_App :: struct {
	markdown_panes:    [dynamic]^Markdown_Pane,
	next_markdown_id:  u32,
	// Zero while no pane is registered, so nothing polls.
	markdown_deadline: time.Tick,
	// The folders of the panes' files, watched on a thread of their own; nil until a pane needs it.
	markdown_watch:    ^turns.Watch_Set,
	// The watch thread set it: a folder reported news, so the next tick reads what changed.
	markdown_signal:   host.Signal,
	// The markdown.* settings with their fonts loaded; markdown_style_apply sets it.
	markdown_style:    views.Markdown_Style,
}

// Loads the fonts the markdown.* settings name. A family that is not installed follows the interface
// or shell font instead, as an empty setting does. Panes lay out again on their next fit, which sees
// the new style.
markdown_style_apply :: proc(app: ^App) {
	s := app.settings.markdown
	family, semibold, code: font.Family
	if s.font_family != "" {
		err: font.Error
		if family, err = font.family_load(app.fonts, s.font_family); err == .None {
			semibold, err = font.family_load(app.fonts, s.font_family, semibold = true)
			if err != .None {semibold = family}
		} else {
			family = {}
			log.warnf("markdown: font %q is not available (%v); following the GUI font", s.font_family, err)
		}
	}
	if s.code_font_family != "" {
		err: font.Error
		if code, err = font.family_load(app.fonts, s.code_font_family); err != .None {
			code = {}
			log.warnf("markdown: font %q is not available (%v); following the shell font", s.code_font_family, err)
		}
	}
	app.markdown_style = views.markdown_style_from(s, family, semibold, code)
}

// Owned by App.markdown_panes; panes refer to it by id and the poll frees it once none does.
Markdown_Pane :: struct {
	id:                     u32,
	path, title, directory: string,
	documents: Document_List,
	load:                   Markdown_Load,
	view:                   views.Markdown_View,
	outline:                views.Markdown_Outline,
	folds:                  Markdown_Folds,
	search:                 markdown.Search,
	// Counts the documents the pane has shown, loads and edit view rebuilds alike, so a view lays out
	// each once.
	revision:               u64,
	// A heading a link asked to show, scrolled to the top by the next draw once the document is laid
	// out; empty for none. Owned.
	heading:                string,
	// Edit mode, or nil while the pane reads the file (markdown_edit.odin).
	editor:                 ^Markdown_Editor,
	// The watch on the file's folder in App.markdown_watch; zero without one (markdown_watch.odin).
	watch:                  turns.Watch_Id,
	// What a reading pane shows of another pane's unsaved edits (markdown_edit.odin); zero when it shows
	// the file.
	followed:               Markdown_Followed,
}

@(require_results)
markdown_find :: proc(app: ^App, id: u32) -> ^Markdown_Pane {
	for pane in app.markdown_panes {if pane.id == id {return pane}}
	return nil
}

@(private)
markdown_pane_destroy :: proc(state: ^Markdown_App, pane: ^Markdown_Pane) {
	markdown_watch_stop(state, pane)
	documents_destroy(&pane.documents)
	if e := pane.editor; e != nil {
		// The pane closing is the last chance to keep its edits.
		if e.save_at != {} {
			if err := os.write_entire_file(pane.path, e.buffer.text[:]); err != nil {
				log.errorf("saving the Markdown file as its pane closed failed: %v", err)
			}
		}
		markdown_editor_destroy(e)
	}
	if loaded, ok := &pane.load.(Markdown_Loaded); ok {
		markdown.document_destroy(&loaded.document)
		delete(loaded.source)
	}
	views.markdown_view_destroy(&pane.view)
	views.markdown_outline_destroy(&pane.outline)
	markdown_folds_destroy(&pane.folds)
	markdown.search_destroy(&pane.search)
	delete(pane.path)
	delete(pane.title)
	delete(pane.directory)
	delete(pane.heading)
	free(pane)
}

markdown_app_destroy :: proc(state: ^Markdown_App) {
	for pane in state.markdown_panes {markdown_pane_destroy(state, pane)}
	delete(state.markdown_panes)
	turns.watch_set_destroy(state.markdown_watch)
	state^ = {}
}

// When the poll next reads the panes' files or an edit saves; false while no pane is registered.
markdown_poll_deadline :: proc(app: ^App) -> (next: time.Tick, pending: bool) {
	if app.markdown_deadline == {} {return}
	next, pending = app.markdown_deadline, true
	for pane in app.markdown_panes {
		if e := pane.editor; e != nil && e.save_at != {} {next, pending = host.earliest(next, pending, e.save_at)}
	}
	return
}

@(private)
markdown_path_set :: proc(pane: ^Markdown_Pane, path: string) -> bool {
	owned, err := strings.clone(path)
	if err != nil {return false}
	title, title_error := strings.clone(filepath.base(path))
	if title_error != nil {delete(owned); return false}
	directory, directory_error := localpath.directory_label(filepath.dir(path))
	if directory_error != nil {directory = ""}
	delete(pane.path)
	delete(pane.title)
	delete(pane.directory)
	pane.path, pane.title, pane.directory = owned, title, directory
	return true
}

// Asks the pane's next draw to scroll `heading` to the top; an empty heading asks nothing. A pane
// opened by the same link has no layout to scroll until it draws.
@(private)
markdown_heading_request :: proc(pane: ^Markdown_Pane, heading: string) {
	if heading == "" {return}
	owned, err := strings.clone(heading)
	if err != nil {return}
	delete(pane.heading)
	pane.heading = owned
}

// Registers a pane for `path`. The poll loads anything that is not loaded now.
@(require_results)
markdown_pane_create :: proc(app: ^App, path: string, verified: bool) -> ^Markdown_Pane {
	pane, err := new(Markdown_Pane)
	if err != nil {return nil}
	if !markdown_path_set(pane, path) {free(pane); return nil}
	if _, append_error := append(&app.markdown_panes, pane); append_error != nil {
		markdown_pane_destroy(&app.markdown_state, pane)
		return nil
	}
	app.next_markdown_id += 1
	pane.id = app.next_markdown_id
	if verified {markdown_pane_verified(app, pane)}
	if app.markdown_deadline == {} {
		app.markdown_deadline = time.tick_add(host.clock_now(&app.clock), MARKDOWN_POLL)
	}
	return pane
}

// The document the pane shows: the edit view while editing, else the file as read; nil while it shows
// a message instead.
@(require_results)
markdown_document :: proc(pane: ^Markdown_Pane) -> ^markdown.Document {
	if pane.editor != nil {return &pane.editor.document}
	loaded, ok := &pane.load.(Markdown_Loaded)
	return ok ? &loaded.document : nil
}

// The only writer of pane.load. Leaving Loaded frees the document; entering it starts the view's
// layout, the selection and any search over for the new text. Returns whether the pane shows
// something new.
@(private = "file", require_results)
markdown_load_enter :: proc(pane: ^Markdown_Pane, next: Markdown_Load) -> bool {
	changed := true
	switch &current in pane.load {
	case Markdown_Loaded:
		markdown.document_destroy(&current.document)
		delete(current.source)
	case Markdown_Missing:
		_, same := next.(Markdown_Missing)
		changed = !same
	case Markdown_Too_Large:
		_, same := next.(Markdown_Too_Large)
		changed = !same
	case Markdown_Failed:
		_, same := next.(Markdown_Failed)
		changed = !same
	case nil:
	}
	pane.load = next
	if _, loaded := next.(Markdown_Loaded); loaded {
		pane.revision += 1
		// The file's text is now what the pane shows, not an editor's.
		pane.followed = {}
		views.markdown_selection_clear(&pane.view)
		markdown.search_restart(&pane.search)
	}
	return changed
}

// The path passed the local-file checks; from now on the poll follows the file itself, and its folder
// reports changes to it.
@(private = "file")
markdown_pane_verified :: proc(app: ^App, pane: ^Markdown_Pane) {
	_ = markdown_load_enter(pane, Markdown_Missing{})
	_ = markdown_pane_load(pane)
	markdown_watch_start(app, pane)
}

// Checks a restored path before anything reads it, then follows the file. Returns whether the pane
// shows something new.
@(private = "file", require_results)
markdown_pane_poll :: proc(app: ^App, pane: ^Markdown_Pane) -> bool {
	if pane.load != nil {return markdown_pane_load(pane)}
	file, ok := localpath.prepare_open(pane.path)
	if !ok {return false}
	defer localpath.open_file_destroy(&file)
	// An active file is never rendered, whatever its name; any other safe file may be explicitly shown.
	if file.confirm || !markdown_path_set(pane, file.target) {return false}
	markdown_pane_verified(app, pane)
	return true
}

// Reads the file again only when its stamp differs from the one last seen, whatever came of that
// read. A failed read keeps what is showing and tries again next poll, because a writer can hold the
// file for a moment. Returns whether the pane shows something new.
@(private = "file", require_results)
markdown_pane_load :: proc(pane: ^Markdown_Pane) -> bool {
	info, stat_error := os.stat(pane.path, context.temp_allocator)
	if stat_error != nil {return markdown_load_enter(pane, Markdown_Missing{})}
	stamp := Markdown_Stamp{info.modification_time, info.size}
	seen, known := Markdown_Stamp{}, false
	switch current in pane.load {
	case Markdown_Loaded:
		seen, known = current.stamp, true
	case Markdown_Too_Large:
		seen, known = current.stamp, true
	case Markdown_Failed:
		seen, known = current.stamp, true
	case Markdown_Missing, nil:
	}
	if known && seen == stamp {return false}
	if info.size > MARKDOWN_SIZE_LIMIT {return markdown_load_enter(pane, Markdown_Too_Large{stamp})}
	data, read_error := os.read_entire_file(pane.path, context.allocator)
	if read_error != nil {
		log.errorf("reading the Markdown file failed: %v", read_error)
		return false
	}
	next: markdown.Document
	if !markdown.parse(string(data), &next) {
		delete(data)
		log.error("parsing the Markdown file ran out of memory")
		return markdown_load_enter(pane, Markdown_Failed{stamp})
	}
	changed := markdown_load_enter(pane, Markdown_Loaded{stamp, next, data})
	markdown_edit_reloaded(pane)
	return changed
}

// Reads the file now if it changed, as the next poll would.
@(private, require_results)
markdown_pane_reload :: proc(pane: ^Markdown_Pane) -> bool {
	return pane.load != nil && markdown_pane_load(pane)
}

// Has the poll read the panes' files at the next tick.
@(private)
markdown_poll_soon :: proc(app: ^App) {
	if app.markdown_deadline != {} {app.markdown_deadline = host.clock_now(&app.clock)}
}

// A pane not showing its document has nothing to find, whatever it last searched.
@(require_results)
markdown_find_summary :: proc(pane: ^Markdown_Pane) -> search.Summary {
	return markdown.search_summary(&pane.search, markdown_document(pane) != nil)
}

markdown_find_select :: proc(w: ^Window, pane: ^Markdown_Pane, upward: bool) {
	if markdown_document(pane) == nil || !markdown.search_select(&pane.search, upward) {return}
	match := pane.search.matches[pane.search.selected]
	if shown, found := markdown_pane_rect(w, pane.id); found {
		visible := int(pane_body_rect(w, shown).height)
		views.markdown_reveal(&pane.view, match.start, match.end, visible)
	}
}

@(private)
markdown_referenced :: proc(app: ^App, id: u32) -> bool {
	content := layout.Content{.Markdown, id}
	for workspace in app.workspaces {if workspace_has_content(workspace, content) {return true}}
	return false
}

// Frees panes nothing shows any more and picks up file changes: at once for a folder that reported one
// (markdown_watch.odin), and for every pane at each poll, which covers what a watch misses. Polling
// costs nothing until a pane exists, and the file attributes it reads do not download a cloud
// placeholder.
markdown_tick :: proc(app: ^App) {
	if app.markdown_deadline == {} {return}
	now := host.clock_now(&app.clock)
	markdown_saves_due(app, now)
	if host.signal_take(&app.markdown_signal) {markdown_watch_drain(app)}
	if time.tick_diff(now, app.markdown_deadline) > 0 {return}
	changed := false
	for i := len(app.markdown_panes) - 1; i >= 0; i -= 1 {
		pane := app.markdown_panes[i]
		if !markdown_referenced(app, pane.id) {
			markdown_pane_destroy(&app.markdown_state, pane)
			ordered_remove(&app.markdown_panes, i)
			continue
		}
		changed = markdown_pane_refresh(app, pane) || changed
	}
	app.markdown_deadline = len(app.markdown_panes) > 0 ? time.tick_add(now, MARKDOWN_POLL) : {}
	if changed {mark_all_dirty(app)}
}

// Reads the pane's file if it changed. Returns whether the pane shows something new.
@(private, require_results)
markdown_pane_refresh :: proc(app: ^App, pane: ^Markdown_Pane) -> bool {
	changed := markdown_pane_poll(app, pane)
	// A file gone from disk ends editing, unless edits wait to bring it back.
	if e := pane.editor; e != nil && e.save_at == {} {
		if _, loaded := pane.load.(Markdown_Loaded); !loaded {markdown_edit_end(app, pane)}
	}
	return changed
}

// Shows a verified file beside `node`: the pane already showing it, or else a new split toward `direction`,
// or a float with `floating`. Beside a floating pane `floating` splits inside its float instead of adding
// another. `w` is the window showing the workspace, or nil.
@(require_results)
markdown_open_at :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	path: string,
	direction: layout.Direction = commands.SPLIT_DEFAULT.direction,
	ratio: f32 = commands.SPLIT_DEFAULT.ratio,
	focus := commands.SPLIT_DEFAULT.focus,
	floating := false,
	heading := "",
) -> bool {
	walk := workspace_panes(app, workspace)
	for shown, ok := workspace_pane_next(&walk); ok; shown, ok = workspace_pane_next(&walk) {
		if shown.content.kind != .Markdown {continue}
		pane := markdown_find(app, shown.content.id)
		if pane == nil || !document_same(pane.path, path) {continue}
		markdown_heading_request(pane, heading)
		if heading != "" && w != nil {w.dirty = true}
		if focus && w != nil {
			if workspace.selected != shown.tab {tab_select(app, w, shown.tab)}
			pane_focus(app, w, shown.node)
		}
		return true
	}
	pane := markdown_pane_create(app, path, true)
	if pane == nil {return false}
	markdown_heading_request(pane, heading)
	tree := &workspace.tabs[tab_index].tree
	placement: Pane_Placement = floating && !layout.is_floating(tree, node) ? .Float : .Split_Right
	content := layout.Content{.Markdown, pane.id}
	return pane_place(app, w, workspace, tab_index, node, content, placement, focus, ratio, direction)
}

// Opens a verified file at the placement chosen on a link in the pane at `node` of w, even when a pane
// already shows it.
@(require_results)
markdown_open_placed :: proc(
	app: ^App,
	w: ^Window,
	node: layout.Node_Id,
	path: string,
	placement: Pane_Placement,
) -> bool {
	acting, beside, found := pane_placement_window(app, w, node, placement)
	if !found {return false}
	pane := markdown_pane_create(app, path, true)
	if pane == nil {return false}
	content := layout.Content{.Markdown, pane.id}
	tab := acting.workspace.selected
	return pane_place(app, acting, acting.workspace, tab, beside, content, placement, true)
}

// Shows a file the focused pane asked for, scrolled to `heading` when it names one. The caller has
// verified the path.
markdown_open_focused :: proc(app: ^App, w: ^Window, path, heading: string) {
	acting := pane_link_acting_window(app, w)
	workspace := acting.workspace
	floating := app.settings.pane.markdown_floating
	if !markdown_open_at(
		app,
		acting,
		workspace,
		workspace.selected,
		window_tree(acting).focus,
		path,
		floating = floating,
		heading = heading,
	) {
		notify(app, .Error, "Could not open the file.")
	}
}

// Opens the Markdown picker. A content menu supplies where the chosen file must go.
markdown_open_picker :: proc(app: ^App, w: ^Window, menu: Maybe(Profile_Menu_Mode) = nil) {
	if app.dialogs.markdown != nil || !gesture_cancel(app, w) {return}
	palette_close(app, w)
	directory := ""
	entry := focused_session(app, w)
	if mode, from_menu := menu.?; from_menu {
		if split, opens_split := mode.(Profile_Menu_Split); opens_split {
			entry = workspace_session_for_content(app, split.pane)
		}
	}
	if entry != nil {directory, _ = pane_directory(app, entry)}
	pick := platform.file_pick_start(&app.platform, w.id, "Markdown files", MARKDOWN_FILTER, directory)
	if pick == nil {
		notify(app, .Error, "Could not show the file dialog.")
		return
	}
	app.dialogs.markdown = Markdown_Pick{{pick, w.id}, menu}
}

@(require_results)
control_markdown_open :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
) -> Outcome {
	if .File not_in invocation.given {return outcome_failure(.Usage, "name a file to open")}
	file, ok := localpath.prepare_open(invocation.file)
	if !ok {return outcome_failure(.Failed, "that file is not available; use a local, absolute path")}
	defer localpath.open_file_destroy(&file)
	if file.confirm {return outcome_failure(.Failed, "that file type is not shown as Markdown")}
	if .Float in invocation.given {
		pane := markdown_pane_create(app, file.target, true)
		if pane == nil ||
		   !pane_place(app, w, target.workspace, target.pane.tab, target.pane.node,
		               {.Markdown, pane.id}, .Float, invocation.focus) {
			return outcome_failure(.Failed, "could not open the file")
		}
		return {}
	}
	// A requested direction asks for a split, whatever the floating preference.
	floating := app.settings.pane.markdown_floating && .Direction not_in invocation.given
	if !markdown_open_at(
		app,
		w,
		target.workspace,
		target.pane.tab,
		target.pane.node,
		file.target,
		invocation.direction,
		invocation.ratio,
		invocation.focus,
		floating,
	) {
		return outcome_failure(.Failed, "could not open the file")
	}
	return {}
}

// The window's focused pane when it shows Markdown.
@(require_results)
markdown_focused :: proc(app: ^App, w: ^Window) -> ^Markdown_Pane {
	content, ok := window_focused_content(w)
	if !ok || content.kind != .Markdown {return nil}
	return markdown_find(app, content.id)
}

markdown_active :: proc(w: ^Window) -> bool {
	content, ok := window_focused_content(w)
	return ok && content.kind == .Markdown
}

@(private, require_results)
markdown_pane_rect :: proc(w: ^Window, id: u32) -> (layout.Pane_Rect, bool) {
	for pane in w.panes {if pane.content == {.Markdown, id} {return pane, true}}
	return {}, false
}

@(private, require_results)
markdown_under_pointer :: proc(app: ^App, w: ^Window, x, y: f32) -> (^Markdown_Pane, layout.Pane_Rect) {
	shown, found := layout.hit_test(w.panes[:], x, y)
	if !found || shown.content.kind != .Markdown {return nil, {}}
	return markdown_find(app, shown.content.id), shown
}

@(private, require_results)
markdown_geometry_of :: proc(app: ^App, w: ^Window, shown: layout.Pane_Rect) -> views.Markdown_Geometry {
	return views.markdown_geometry(pane_body_rect(w, shown), w.scale, app.markdown_style.column)
}

// The link the pointer is over in pane `id`, or -1.
@(private, require_results)
markdown_link_hovered :: proc(w: ^Window, id: u32) -> int {
	if hover, over := w.markdown_hover.(Markdown_Link_Hover); over && hover.pane == id {return hover.link}
	return -1
}

// Whether pane `id` shows its outline's panel.
@(private = "file", require_results)
markdown_outline_open :: proc(w: ^Window, id: u32) -> bool {
	hover, over := w.markdown_hover.(Markdown_Outline_Hover)
	return over && hover.pane == id
}

// Where the pane's outline bars sit on its page at `g`, with the view laid out and the headings
// measured for the document it shows now. Not shown while the pane shows a message.
@(private = "file", require_results)
markdown_outline_of :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	g: views.Markdown_Geometry,
) -> (
	views.Markdown_Outline_Column,
	bool,
) {
	document := markdown_document(pane)
	if document == nil {return {}, false}
	markdown_view_fitted(app, w, pane, document, g)
	views.markdown_outline_sync(&pane.outline, &pane.view, document)
	return views.markdown_outline_column(&pane.outline, g, w.scale)
}

// The heading under a point on the pane's outline: on a bar, or on a row while the panel is open.
// `over` is whether the point is on the bars' strip or the open panel at all. The panel, about to open
// when the point is on the strip, is first scrolled to show the section being read.
@(private = "file", require_results)
markdown_outline_under :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	shown: layout.Pane_Rect,
	x, y: f32,
) -> (
	heading: int,
	over: bool,
) {
	g := markdown_geometry_of(app, w, shown)
	column, visible := markdown_outline_of(app, w, pane, g)
	if !visible {return -1, false}
	outline := &pane.outline
	open := markdown_outline_open(w, pane.id)
	bar := views.markdown_outline_bar_at(column, x, y)
	if !open && bar < 0 {return -1, false}
	panel := views.markdown_outline_panel(outline, markdown_document(pane), column, g.area, &w.ui_text, w.scale)
	if !open {
		views.markdown_outline_reveal(outline, panel, views.markdown_outline_current(outline, &pane.view), w.scale)
	}
	if bar >= 0 {return views.markdown_outline_bar_heading(outline, column, bar), true}
	return views.markdown_outline_row_at(outline, panel, x, y, w.scale)
}

// The wheel over an open panel whose rows overflow scrolls them rather than the page.
@(private = "file", require_results)
markdown_outline_wheel :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	shown: layout.Pane_Rect,
	x, y: f32,
	rows: int,
) -> bool {
	if !markdown_outline_open(w, pane.id) {return false}
	g := markdown_geometry_of(app, w, shown)
	column, visible := markdown_outline_of(app, w, pane, g)
	if !visible {return false}
	outline := &pane.outline
	panel := views.markdown_outline_panel(outline, markdown_document(pane), column, g.area, &w.ui_text, w.scale)
	if _, inside := views.markdown_outline_row_at(outline, panel, x, y, w.scale); !inside {return false}
	if !views.markdown_outline_scrollable(panel) {return false}
	if views.markdown_outline_wheel(outline, panel, rows, w.scale) {
		// The rows moved under the pointer.
		row, _ := views.markdown_outline_row_at(outline, panel, x, y, w.scale)
		markdown_hover_set(w, Markdown_Outline_Hover{pane.id, row})
		w.dirty = true
	}
	return true
}

// A pane that is not showing a document says why, once.
@(private, require_results)
markdown_message_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	g: views.Markdown_Geometry,
) -> render.Build_Status {
	if render.push_layer(&w.list, g.area, 0) != .None {return .Ok}
	message := "This file could not be read."
	path := ""
	if pane != nil {
		path = pane.path
		#partial switch _ in pane.load {
		case nil, Markdown_Missing:
			message = "This file is not available."
		case Markdown_Too_Large:
			message = "This file is too large to show."
		}
	}
	baseline := g.top + w.ui_text.ascent
	if result := ui.draw_text(&w.ui_text, &w.list, message, g.left, baseline, app.theme.text, g.width);
	   result != .Ok {return result}
	baseline += w.ui_text.line_height
	return ui.draw_text(&w.ui_text, &w.list, path, g.left, baseline, app.theme.muted, g.width)
}

// The document inside its pane, or a message when it cannot be shown; `scrollable` when the document
// drew and its scrollbar belongs beside it. pane_draw draws the card, header and outline around it.
@(require_results)
markdown_pane_draw :: proc(
	app: ^App,
	w: ^Window,
	shown: layout.Pane_Rect,
) -> (
	scrollable: bool,
	result: render.Build_Status,
) {
	pane := markdown_find(app, shown.content.id)
	g := markdown_geometry_of(app, w, shown)
	if pane != nil {markdown_follow_edits(app, pane)}
	document := pane != nil ? markdown_document(pane) : nil
	if document == nil {return false, markdown_message_draw(app, w, pane, g)}
	view := &pane.view
	markdown_view_fitted(app, w, pane, document, g)
	visible := int(g.area.height)
	// Applied once: a heading the document does not have leaves the view where it was.
	if pane.heading != "" {
		if offset, found := markdown.heading_find(document, pane.heading); found {
			if markdown_fold_reveal(pane, offset) {markdown_view_fitted(app, w, pane, document, g)}
			views.markdown_scroll_to_offset(view, offset, visible)
		}
		delete(pane.heading)
		pane.heading = ""
	}
	if e := pane.editor; e != nil && e.reveal {
		e.reveal = false
		caret := markdown.live_display(document, e.buffer.caret)
		if rect, _, found := views.markdown_caret_at(view, document, caret); found {
			_ = views.markdown_scroll_to_show(view, rect, visible)
		}
	}
	views.markdown_scroll_by(view, 0, visible)
	find: views.Markdown_Find
	if pane.search.phase != .Off {
		c := app.settings.colors
		find = {
			matches = pane.search.matches[:],
			selected = pane.search.selected,
			foreground = colour.rgba(c.search_foreground),
			background = colour.rgba(c.search_background),
			selected_background = colour.rgba(c.search_selected_background),
		}
	}
	hover := markdown_link_hovered(w, pane.id)
	caret := markdown_caret_shown(w, pane, shown)
	folds := views.Markdown_Folds{pane.folds.folded[:], -1}
	if fold, over := w.markdown_hover.(Markdown_Fold_Hover); over && fold.pane == pane.id {
		folds.hover = fold.heading
	}
	result = views.markdown_draw(view, document, g, &w.list, &w.ui_text, app.theme, find, hover, caret, folds)
	if result != .Ok {return true, result}
	views.markdown_outline_sync(&pane.outline, view, document)
	outline, open := w.markdown_hover.(Markdown_Outline_Hover)
	open &&= outline.pane == pane.id
	return true, views.markdown_outline_draw(&pane.outline, view, document, g, &w.list, &w.ui_text,
		app.theme, open,
		open ? outline.heading : -1, w.scale)
}

@(private)
markdown_scroll :: proc(w: ^Window, pane: ^Markdown_Pane, shown: layout.Pane_Rect, delta: int) {
	visible := int(pane_body_rect(w, shown).height)
	if views.markdown_scroll_by(&pane.view, delta, visible) {w.dirty = true}
}

// Rows are the scrolled text lines, positive toward the top, as the mouse wheel reports them.
@(require_results)
markdown_wheel :: proc(app: ^App, w: ^Window, x, y: f32, rows: int) -> bool {
	pane, shown := markdown_under_pointer(app, w, x, y)
	if shown.content.kind != .Markdown {return false}
	if pane == nil {return true}
	if markdown_outline_wheel(app, w, pane, shown, x, y, rows) {return true}
	markdown_scroll(w, pane, shown, -rows * views.markdown_line(&pane.view))
	return true
}

// Scrolls by whole pages of the focused pane, keeping one line of context.
markdown_page :: proc(app: ^App, w: ^Window, pages: f64) {
	pane := markdown_focused(app, w)
	if pane == nil {return}
	shown, found := markdown_pane_rect(w, pane.id)
	if !found {return}
	visible := int(markdown_geometry_of(app, w, shown).area.height)
	page := max(1, visible - views.markdown_line(&pane.view))
	markdown_scroll(w, pane, shown, int(pages * f64(page)))
}

// The focused document's selected text, empty when nothing is selected or no document is focused.
@(require_results)
markdown_selected :: proc(app: ^App, w: ^Window) -> string {
	pane := markdown_focused(app, w)
	if pane == nil {return ""}
	// An editor copies the file's own text, markup included.
	if e := pane.editor; e != nil {return textedit.selected_text(&e.buffer)}
	document := markdown_document(pane)
	return document == nil ? "" : views.markdown_selected_text(&pane.view, document)
}

markdown_copy :: proc(app: ^App, w: ^Window) {
	if text := markdown_selected(app, w); text != "" {clipboard_copy(app, text)}
}

markdown_select_all :: proc(app: ^App, w: ^Window) {
	pane := markdown_focused(app, w)
	if pane == nil {return}
	if e := pane.editor; e != nil {
		textedit.select_all(&e.buffer)
		markdown_editor_sync(pane)
	} else if document := markdown_document(pane); document != nil {
		views.markdown_select_all(&pane.view, document)
	}
	w.dirty = true
}

markdown_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane_header_cancel(w)
	key_suppress(w, e)
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {return}
	logical := key.logical
	has_find := ui.find_has_keyboard(&w.find)
	editing := markdown_focused(app, w)
	if !markdown_editing(editing) {editing = nil}
	if !has_find && editing == nil && key.clipboard == .Copy {
		markdown_copy(app, w)
		return
	}
	if !e.pressed {return}
	// An editor's keys come before shortcuts, as a terminal's program would want them, except the chords
	// it has no use for.
	if !has_find && editing != nil && markdown_edit_key(app, w, editing, key) {return}
	if key.found && (key.runtime || action_available(app, w, key.action)) {
		run_window_command(app, w, key.command, .Key)
		return
	}
	status_inbox_typed(w, e)
	if has_find {
		find_bar_key(app, w, e, logical)
		return
	}
	modifiers := e.modifiers & {.Control, .Shift, .Alt, .Super}
	if modifiers == {.Control} && logical.key == .A {
		markdown_select_all(app, w)
		return
	}
	if modifiers != {} {return}
	pane := markdown_focused(app, w)
	if pane == nil {return}
	shown, found := markdown_pane_rect(w, pane.id)
	if !found {return}
	line := views.markdown_line(&pane.view)
	#partial switch logical.key {
	case .Arrow_Up:
		markdown_scroll(w, pane, shown, -line)
	case .Arrow_Down:
		markdown_scroll(w, pane, shown, line)
	case .Page_Up:
		markdown_page(app, w, -1)
	case .Page_Down:
		markdown_page(app, w, 1)
	case .Home:
		markdown_scroll(w, pane, shown, -views.markdown_total(&pane.view))
	case .End:
		markdown_scroll(w, pane, shown, views.markdown_total(&pane.view))
	case .Escape:
		views.markdown_selection_clear(&pane.view)
		w.dirty = true
	}
}

// Web links open in the browser. Anything else is a file the link resolves to from the document, which
// then takes the same path as a file link printed in a terminal; a heading in this same document
// scrolls this pane instead.
@(private)
markdown_link_open :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane, link: int) {
	buffer: [links.TARGET_BYTES]u8 = ---
	target, heading := target_from_link(markdown_document(pane).links[link], pane.path, buffer[:])
	file, local := target.(File_Target)
	switch {
	case !local:
		target_open(app, w, target)
	case document_same(file.path, pane.path):
		markdown_heading_request(pane, heading)
		w.dirty = true
	case:
		target_open_file(app, w, file.path, heading)
	}
}

// A right-click on a link shows the link menu a terminal link shows. False when the point is on no
// link.
@(private = "file", require_results)
markdown_link_menu :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	shown: layout.Pane_Rect,
	x, y: f32,
) -> bool {
	document := markdown_document(pane)
	if document == nil {return false}
	link := views.markdown_link_at(&pane.view, markdown_geometry_of(app, w, shown), x, y)
	if link < 0 {return false}
	buffer: [links.TARGET_BYTES]u8 = ---
	target, _ := target_from_link(document.links[link], pane.path, buffer[:])
	document_menu_open_target(app, w, shown.content, target, x, y)
	return true
}

// Whether a point is on the page's text, not on its scrollbar or its outline bars.
@(private = "file", require_results)
markdown_text_at :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	shown: layout.Pane_Rect,
	x, y: f32,
) -> bool {
	if bar, visible := pane_scrollbar_geometry(app, w, shown); visible && ui.scrollbar_contains(bar, x, y) {
		return false
	}
	_, over := markdown_outline_under(app, w, pane, shown, x, y)
	return !over
}

// The link a click at a point opens, or -1. A link on a line the editor shows as source is text to
// edit there, so only Ctrl+click opens it.
@(private = "file", require_results)
markdown_link_clicked :: proc(
	pane: ^Markdown_Pane,
	document: ^markdown.Document,
	g: views.Markdown_Geometry,
	x, y: f32,
	control: bool,
) -> int {
	link := views.markdown_link_at(&pane.view, g, x, y)
	if link < 0 || control || !markdown_editing(pane) {return link}
	e := pane.editor
	source := markdown.live_source(document, views.markdown_offset_at(&pane.view, document, g, x, y))
	return source >= e.built_from && source <= e.built_to ? -1 : link
}

// Pointer surface

markdown_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	shown, found := layout.hit_test(w.panes[:], x, y)
	return found && shown.content.kind == .Markdown
}

@(private = "file")
markdown_hover_set :: proc(w: ^Window, next: Markdown_Hover) {
	if w.markdown_hover != next {w.markdown_hover, w.dirty = next, true}
}

// The pointer is off every Markdown page: no link or bar shows its hover.
markdown_leave :: proc(_: ^App, w: ^Window) {
	markdown_hover_set(w, nil)
	pane_scrollbar_hover_leave(w, .Markdown)
}

markdown_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	if w.markdown_gesture != nil {
		markdown_held_move(app, w, x, y)
		return
	}
	if owner != .Markdown_Page {
		markdown_leave(app, w)
		return
	}
	pane, shown := markdown_under_pointer(app, w, x, y)
	if pane == nil {
		markdown_leave(app, w)
		pointer_set(app, w, .Arrow)
		return
	}
	hover: Markdown_Hover
	shape := platform.Cursor_Shape.Arrow
	bar, visible := pane_scrollbar_geometry(app, w, shown)
	if visible && ui.scrollbar_contains(bar, x, y) {
		pane_scrollbar_hover_set(w, shown.content)
	} else {
		pane_scrollbar_hover_leave(w, .Markdown)
		if heading, over := markdown_outline_under(app, w, pane, shown, x, y); over {
			hover = Markdown_Outline_Hover{pane.id, heading}
			if heading >= 0 {shape = .Hand}
		} else if document := markdown_document(pane); document != nil {
			g := markdown_geometry_of(app, w, shown)
			shape = .Text
			if link := markdown_link_clicked(pane, document, g, x, y, .Control in e.modifiers); link >= 0 {
				hover, shape = Markdown_Link_Hover{pane.id, link}, .Hand
			} else if views.markdown_task_at(&pane.view, document, g, x, y) != markdown.NO_SOURCE {
				shape = .Hand
			} else if folding, on_chevron := views.markdown_fold_at(&pane.view, document, g, x, y); folding >= 0 {
				hover = Markdown_Fold_Hover{pane.id, folding}
				if on_chevron {shape = .Hand}
			}
		}
	}
	markdown_hover_set(w, hover)
	pointer_set(app, w, shape)
}

// A held pane that left the window or stopped showing its document ends the gesture, since there is
// nothing left for it to select or scroll. Past the page's top or bottom edge the page scrolls on a timer
// (markdown_autoscroll_tick), so a held pointer keeps selecting without moving.
@(private = "file")
markdown_held_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	selecting, held := w.markdown_gesture.(Markdown_Selecting)
	if !held {return}
	pane := markdown_find(app, selecting.pane)
	shown, found := markdown_pane_rect(w, selecting.pane)
	document := pane != nil ? markdown_document(pane) : nil
	if !found || document == nil {
		markdown_gesture_clear(app, w)
		return
	}
	g := markdown_geometry_of(app, w, shown)
	markdown_selecting_extend(w, pane, document, g, selecting, x, y)
	outside := y < g.area.y || y > g.area.y + g.area.height
	if ui.edge_scroll_follow(&selecting.scroll, outside, host.clock_now(&app.clock)) {
		w.markdown_gesture = selecting
	}
	w.dirty = true
	pointer_set(app, w, .Text)
}

// The selection a held press makes follows the pointer to (`x`, `y`), which stays within the page so an
// edge reaches the line at it.
@(private = "file")
markdown_selecting_extend :: proc(
	w: ^Window,
	pane: ^Markdown_Pane,
	document: ^markdown.Document,
	g: views.Markdown_Geometry,
	selecting: Markdown_Selecting,
	x, pointer_y: f32,
) {
	y := clamp(pointer_y, g.area.y, max(g.area.y, g.area.y + g.area.height - 1))
	switch unit, by_unit := selecting.unit.?; {
	case !markdown_editing(pane):
		views.markdown_select_at(&pane.view, views.markdown_offset_at(&pane.view, document, g, x, y), true)
	case by_unit:
		markdown_edit_unit_drag(w, pane, g, x, y, unit, selecting.from, selecting.to)
	case:
		_ = markdown_edit_point(w, pane, g, x, y, true)
	}
}

markdown_autoscroll_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	selecting, held := w.markdown_gesture.(Markdown_Selecting)
	if !held {return {}, false}
	return ui.edge_scroll_deadline(selecting.scroll)
}

// Scrolls the page a step toward a held pointer past its top or bottom edge, faster the farther it is,
// and extends the selection to the line that comes under it.
markdown_autoscroll_tick :: proc(app: ^App, w: ^Window, now: time.Tick) {
	selecting, held := w.markdown_gesture.(Markdown_Selecting)
	if !held || !ui.edge_scroll_due(&selecting.scroll, now) {return}
	pane := markdown_find(app, selecting.pane)
	shown, found := markdown_pane_rect(w, selecting.pane)
	document := pane != nil ? markdown_document(pane) : nil
	if !found || document == nil {
		markdown_gesture_clear(app, w)
		return
	}
	g := markdown_geometry_of(app, w, shown)
	x, y := w.pointer.x, w.pointer.y
	distance := y < g.area.y ? y - g.area.y : max(0, y - g.area.y - g.area.height)
	if distance == 0 {
		ui.edge_scroll_stop(&selecting.scroll)
		w.markdown_gesture = selecting
		return
	}
	reach := 3 * views.markdown_line(&pane.view)
	markdown_scroll(w, pane, shown, clamp(int(distance) / 4, -reach, reach) + (distance < 0 ? -1 : 1))
	markdown_selecting_extend(w, pane, document, g, selecting, x, y)
	w.markdown_gesture = selecting
	w.dirty = true
}

markdown_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	pane, shown := markdown_under_pointer(app, w, x, y)
	if shown.content.kind != .Markdown {return}
	pane_focus(app, w, shown.node)
	if pane == nil {return}
	if e.button == .Right {
		switch {
		case markdown_link_menu(app, w, pane, shown, x, y): gesture_swallow(w, .Right, .Markdown_Page)
		case markdown_editing(pane) && markdown_text_at(app, w, pane, shown, x, y):
			gesture_swallow(w, .Right, .Markdown_Page)
			markdown_edit_menu_open(app, w, pane, markdown_geometry_of(app, w, shown), x, y)
		}
		return
	}
	if e.button != .Left {return}
	document := markdown_document(pane)
	if document == nil {return}
	w.dirty = true
	if pane_scrollbar_press(app, w, shown, x, y) {return}
	g := markdown_geometry_of(app, w, shown)
	editing := markdown_editing(pane)
	// A press on the outline jumps to a heading and never starts a selection.
	if heading, over := markdown_outline_under(app, w, pane, shown, x, y); over {
		if heading >= 0 {
			start := pane.outline.headings[heading].start
			if markdown_fold_reveal(pane, start) {markdown_view_fitted(app, w, pane, document, g)}
			views.markdown_scroll_to_offset(&pane.view, start, int(g.area.height))
		}
		return
	}
	if editing && .Shift not_in e.modifiers {
		if count := ui.click_run_count(w.markdown_clicks, pane.id, x, y, e.time_ns); count > 1 {
			// The first click moved the caret and so changed the layout under the pointer: the word or
			// line is the one that click hit.
			unit: textedit.Unit = count == 2 ? .Word : .Line
			at := w.markdown_clicks.at
			from, to := markdown_edit_unit(w, pane, unit, at)
			w.markdown_clicks = {pane.id, x, y, e.time_ns, count, at}
			w.markdown_gesture = Markdown_Selecting{pane = pane.id, unit = unit, from = from, to = to}
			return
		}
	}
	if heading, on_chevron := views.markdown_fold_at(&pane.view, document, g, x, y); on_chevron {
		markdown_fold_toggle(pane, heading)
		return
	}
	if .Shift not_in e.modifiers || .Control in e.modifiers {
		if link := markdown_link_clicked(pane, document, g, x, y, .Control in e.modifiers); link >= 0 {
			markdown_link_open(app, w, pane, link)
			return
		}
	}
	if mark := views.markdown_task_at(&pane.view, document, g, x, y); mark != markdown.NO_SOURCE {
		markdown_task_toggle(app, pane, mark)
		return
	}
	if editing {
		at := markdown_edit_point(w, pane, g, x, y, .Shift in e.modifiers)
		w.markdown_clicks = .Shift in e.modifiers ? ui.Click_Run{} : ui.Click_Run{pane.id, x, y, e.time_ns, 1, at}
	} else {
		offset := views.markdown_offset_at(&pane.view, document, g, x, y)
		views.markdown_select_at(&pane.view, offset, .Shift in e.modifiers)
	}
	w.markdown_gesture = Markdown_Selecting{pane = pane.id}
}

markdown_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Left {return false}
	if pane_scrollbar_end(w, .Markdown) {
		w.dirty = true
		return true
	}
	if w.markdown_gesture == nil {return false}
	markdown_gesture_clear(app, w)
	return true
}

// Ends whatever the pointer holds on a Markdown pane: a selection or a scrollbar thumb.
markdown_gesture_clear :: proc(app: ^App, w: ^Window) {
	thumb := pane_scrollbar_end(w, .Markdown)
	if w.markdown_gesture == nil && !thumb {return}
	w.markdown_gesture = nil
	w.dirty = true
}

when AIO_CONTROL {
	// The focused Markdown pane's verification keys; the load state is reported by its variant name.
	markdown_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		scroll, total := 0, 0
		path, selected := "", ""
		state := "Missing"
		outline, current := 0, -1
		open, editing, unsaved := false, false, false
		caret, folds := -1, 0
		if pane := markdown_focused(app, w); pane != nil {
			scroll, total = pane.view.scroll, views.markdown_total(&pane.view)
			path = pane.path
			switch _ in pane.load {
			case nil:
				state = "Unverified"
			case Markdown_Missing:
			case Markdown_Loaded:
				state = "Loaded"
			case Markdown_Too_Large:
				state = "Too_Large"
			case Markdown_Failed:
				state = "Failed"
			}
			if document := markdown_document(pane); document != nil {
				selected = markdown_selected(app, w)
				if e := pane.editor; e != nil {
					editing, unsaved, caret = true, e.save_at != {}, e.buffer.caret
				}
				if shown, found := markdown_pane_rect(w, pane.id); found {
					column, visible := markdown_outline_of(app, w, pane, markdown_geometry_of(app, w, shown))
					if visible {outline = column.count}
					current = views.markdown_outline_current(&pane.outline, &pane.view)
				}
				open = markdown_outline_open(w, pane.id)
			}
		}
		state_value(r, "markdown.count", len(app.markdown_panes))
		state_value(r, "markdown.active", markdown_active(w))
		state_text(r, "markdown.path", path)
		state_text(r, "markdown.state", state)
		state_value(r, "markdown.scroll", scroll)
		state_value(r, "markdown.total", total)
		state_text(r, "markdown.selection", selected)
		state_value(r, "markdown.outline", outline)
		state_value(r, "markdown.outline_open", open)
		state_value(r, "markdown.outline_current", current)
		state_value(r, "markdown.editing", editing)
		state_value(r, "markdown.unsaved", unsaved)
		state_value(r, "markdown.caret", caret)
		if pane := markdown_focused(app, w); pane != nil {folds = len(pane.folds.folds)}
		state_value(r, "markdown.folds", folds)
	}
}
