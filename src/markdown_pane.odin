package main

import "aio:colour"
import "aio:commands"
import "aio:input"
import "aio:layout"
import "aio:links"
import "aio:localpath"
import "aio:markdown"
import "aio:platform"
import "aio:render"
import "aio:search"
import "aio:ui"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

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
Markdown_Selecting :: struct {
	pane: u32,
}

// The link the pointer is over among a window's Markdown panes; one value, so one pane at most shows
// it. The scrollbar under the pointer is a pane scrollbar hover.
Markdown_Hover :: union {
	Markdown_Link_Hover,
}
Markdown_Link_Hover :: struct {
	pane: u32,
	link: int,
}

// A window's pointer state over its Markdown panes; Window embeds it and this file is its only writer.
Markdown_Pointer :: struct {
	markdown_gesture: Markdown_Gesture,
	markdown_hover:   Markdown_Hover,
}

// The app's Markdown panes, which windows refer to by id, and when the poll next reads their files.
// App embeds it; this file owns it, and markdown_app_destroy releases it.
Markdown_App :: struct {
	markdown_panes:    [dynamic]^Markdown_Pane,
	next_markdown_id:  u32,
	// Zero while no pane is registered, so nothing polls.
	markdown_deadline: time.Tick,
}

// Owned by App.markdown_panes; panes refer to it by id and the poll frees it once none does.
Markdown_Pane :: struct {
	id:                     u32,
	path, title, directory: string,
	documents: Document_List,
	load:                   Markdown_Load,
	view:                   ui.Markdown_View,
	search:                 markdown.Search,
	// Counts loads, so a view lays out each new document once.
	revision:               u64,
}

@(require_results)
markdown_find :: proc(app: ^App, id: u32) -> ^Markdown_Pane {
	for pane in app.markdown_panes {if pane.id == id {return pane}}
	return nil
}

@(private)
markdown_pane_destroy :: proc(pane: ^Markdown_Pane) {
	documents_destroy(&pane.documents)
	if document := markdown_document(pane); document != nil {markdown.document_destroy(document)}
	ui.markdown_view_destroy(&pane.view)
	markdown.search_destroy(&pane.search)
	delete(pane.path)
	delete(pane.title)
	delete(pane.directory)
	free(pane)
}

markdown_app_destroy :: proc(state: ^Markdown_App) {
	for pane in state.markdown_panes {markdown_pane_destroy(pane)}
	delete(state.markdown_panes)
	state^ = {}
}

// When the poll next reads the panes' files; false while no pane is registered.
markdown_poll_deadline :: proc(app: ^App) -> (time.Tick, bool) {
	return app.markdown_deadline, app.markdown_deadline != {}
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

// Registers a pane for `path`. The poll loads anything that is not loaded now.
@(require_results)
markdown_pane_create :: proc(app: ^App, path: string, verified: bool) -> ^Markdown_Pane {
	pane, err := new(Markdown_Pane)
	if err != nil {return nil}
	if !markdown_path_set(pane, path) {free(pane); return nil}
	if _, append_error := append(&app.markdown_panes, pane); append_error != nil {
		markdown_pane_destroy(pane)
		return nil
	}
	app.next_markdown_id += 1
	pane.id = app.next_markdown_id
	if verified {markdown_pane_verified(pane)}
	if app.markdown_deadline == {} {app.markdown_deadline = time.tick_add(time.tick_now(), MARKDOWN_POLL)}
	return pane
}

// The document the pane shows, or nil while it shows a message instead.
@(require_results)
markdown_document :: proc(pane: ^Markdown_Pane) -> ^markdown.Document {
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
		ui.markdown_selection_clear(&pane.view)
		markdown.search_restart(&pane.search)
	}
	return changed
}

// The path passed the local-file checks; from now on the poll follows the file itself.
@(private = "file")
markdown_pane_verified :: proc(pane: ^Markdown_Pane) {
	_ = markdown_load_enter(pane, Markdown_Missing{})
	_ = markdown_pane_load(pane)
}

// Checks a restored path before anything reads it, then follows the file. Returns whether the pane
// shows something new.
@(private = "file", require_results)
markdown_pane_poll :: proc(pane: ^Markdown_Pane) -> bool {
	if pane.load != nil {return markdown_pane_load(pane)}
	file, ok := localpath.prepare_open(pane.path)
	if !ok {return false}
	defer localpath.open_file_destroy(&file)
	// An active file is never rendered, whatever its name; any other safe file may be explicitly shown.
	if file.confirm || !markdown_path_set(pane, file.target) {return false}
	markdown_pane_verified(pane)
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
	defer delete(data)
	next: markdown.Document
	if !markdown.parse(string(data), &next) {
		log.error("parsing the Markdown file ran out of memory")
		return markdown_load_enter(pane, Markdown_Failed{stamp})
	}
	return markdown_load_enter(pane, Markdown_Loaded{stamp, next})
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
		visible := int(markdown_geometry_of(w, shown).area.height)
		ui.markdown_reveal(&pane.view, match.start, match.end, visible)
	}
}

@(private)
markdown_referenced :: proc(app: ^App, id: u32) -> bool {
	content := layout.Content{.Markdown, id}
	for workspace in app.workspaces {if workspace_has_content(workspace, content) {return true}}
	return false
}

// Frees panes nothing shows any more and picks up file changes. Polling costs nothing until a pane
// exists, and the file attributes it reads do not download a cloud placeholder.
markdown_tick :: proc(app: ^App) {
	if app.markdown_deadline == {} {return}
	now := time.tick_now()
	if time.tick_diff(now, app.markdown_deadline) > 0 {return}
	changed := false
	for i := len(app.markdown_panes) - 1; i >= 0; i -= 1 {
		pane := app.markdown_panes[i]
		if !markdown_referenced(app, pane.id) {
			markdown_pane_destroy(pane)
			ordered_remove(&app.markdown_panes, i)
			continue
		}
		changed = markdown_pane_poll(pane) || changed
	}
	app.markdown_deadline = len(app.markdown_panes) > 0 ? time.tick_add(now, MARKDOWN_POLL) : {}
	if changed {mark_all_dirty(app)}
}

@(private, require_results)
markdown_new_tab :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	content: layout.Content,
	focus: bool,
) -> bool {
	tab, reserved := tab_record_reserve(workspace)
	if !reserved {return false}
	if layout.init(&tab.tree, content) != nil {
		tab_record_free(tab)
		return false
	}
	tab_record_commit(app, workspace, tab)
	if focus && w != nil {tab_select(app, w, len(workspace.tabs) - 1)}
	return true
}

// Shows a verified file beside `node`: the pane already showing it, a new split, or a new tab when
// the pane is too small to split; with `floating`, a floating pane above the tab instead of a split.
// `w` is the window showing the workspace, or nil.
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
) -> bool {
	walk := workspace_panes(app, workspace)
	for shown, ok := workspace_pane_next(&walk); ok; shown, ok = workspace_pane_next(&walk) {
		if shown.content.kind != .Markdown {continue}
		pane := markdown_find(app, shown.content.id)
		if pane == nil || !document_same(pane.path, path) {continue}
		if focus && w != nil {
			if workspace.selected != shown.tab {tab_select(app, w, shown.tab)}
			pane_focus(app, w, shown.node)
		}
		return true
	}
	pane := markdown_pane_create(app, path, true)
	if pane == nil {return false}
	content := layout.Content{.Markdown, pane.id}
	// A linked window holds one pane's slot, and only linkable content belongs there.
	opened := false
	if w != nil && window_linked(w) {
		opened = markdown_new_tab(app, nil, workspace, content, false)
	} else if floating {
		opened = floating_attach(app, w, workspace, tab_index, content, focus)
	} else {
		// A floating pane does not split, so the file opens beside the tiled pane below it.
		anchor := node
		tree := &workspace.tabs[tab_index].tree
		if layout.is_floating(tree, anchor) {anchor = layout.focus_tiled(tree)}
		failure := pane_split_insert(
			app, w, workspace, tab_index, anchor, direction, ratio, focus, content, false,
		)
		#partial switch failure {
		case .None:
			opened = true
		case .Minimum:
			opened = markdown_new_tab(app, w, workspace, content, focus)
		}
	}
	if opened {layout_state_touch(app)}
	return opened
}

// Shows a file the focused pane asked for. The caller has verified the path.
markdown_open_focused :: proc(app: ^App, w: ^Window, path: string) {
	acting := pane_link_acting_window(app, w)
	workspace := acting.workspace
	floating := app.settings.pane.markdown_floating
	if !markdown_open_at(
		app, acting, workspace, workspace.selected, window_tree(acting).focus, path, floating = floating,
	) {
		notify(app, .Error, "Could not open the file.")
	}
}

// The Open Markdown File command from a key or the palette.
markdown_open_picker :: proc(app: ^App, w: ^Window) {
	if app.dialogs.markdown != nil || !gesture_cancel(app, w) {return}
	palette_close(app, w)
	directory := ""
	if entry := focused_session(app, w); entry != nil {directory, _ = pane_directory(app, entry)}
	pick := platform.file_pick_start(&app.platform, w.id, "Markdown files", MARKDOWN_FILTER, directory)
	if pick == nil {
		notify(app, .Error, "Could not show the file dialog.")
		return
	}
	app.dialogs.markdown = File_Dialog{pick, w.id}
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
markdown_geometry_of :: proc(w: ^Window, shown: layout.Pane_Rect) -> ui.Markdown_Geometry {
	return ui.markdown_geometry(pane_body_rect(w, shown), w.scale)
}

// The link the pointer is over in pane `id`, or -1.
@(private, require_results)
markdown_link_hovered :: proc(w: ^Window, id: u32) -> int {
	if hover, over := w.markdown_hover.(Markdown_Link_Hover); over && hover.pane == id {return hover.link}
	return -1
}

// A pane that is not showing a document says why, once.
@(private, require_results)
markdown_message_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	g: ui.Markdown_Geometry,
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

@(require_results)
markdown_pane_draw :: proc(app: ^App, w: ^Window, shown: layout.Pane_Rect, card: int) -> render.Build_Status {
	if card < len(w.list.rects) {w.list.rects[card].color = app.theme.pane}
	pane := markdown_find(app, shown.content.id)
	g := markdown_geometry_of(w, shown)
	document := pane != nil ? markdown_document(pane) : nil
	if document != nil {
		view := &pane.view
		ui.markdown_view_fit(view, document, pane.revision, &w.ui_text, app.family, g.width, w.scale)
		ui.markdown_scroll_by(view, 0, int(g.area.height))
		find: ui.Markdown_Find
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
		if result := ui.markdown_draw(view, document, g, &w.list, &w.ui_text, app.theme, find, hover);
		   result != .Ok {
			return result
		}
		pane_scrollbar_draw(app, w, shown)
	} else if result := markdown_message_draw(app, w, pane, g); result != .Ok {return result}
	if header := pane_header_draw(app, w, shown, nil); header != .Ok {return header}
	window_card_dim(app, w, shown, app.theme.pane)
	window_card_outline(app, w, shown)
	return .Ok
}

@(private)
markdown_scroll :: proc(w: ^Window, pane: ^Markdown_Pane, shown: layout.Pane_Rect, delta: int) {
	visible := int(markdown_geometry_of(w, shown).area.height)
	if ui.markdown_scroll_by(&pane.view, delta, visible) {w.dirty = true}
}

// Rows are the scrolled text lines, positive toward the top, as the mouse wheel reports them.
@(require_results)
markdown_wheel :: proc(app: ^App, w: ^Window, x, y: f32, rows: int) -> bool {
	pane, shown := markdown_under_pointer(app, w, x, y)
	if shown.content.kind != .Markdown {return false}
	if pane != nil {markdown_scroll(w, pane, shown, -rows * ui.markdown_line(&pane.view))}
	return true
}

// Scrolls by whole pages of the focused pane, keeping one line of context.
markdown_page :: proc(app: ^App, w: ^Window, pages: f64) {
	pane := markdown_focused(app, w)
	if pane == nil {return}
	shown, found := markdown_pane_rect(w, pane.id)
	if !found {return}
	visible := int(markdown_geometry_of(w, shown).area.height)
	page := max(1, visible - ui.markdown_line(&pane.view))
	markdown_scroll(w, pane, shown, int(pages * f64(page)))
}

// The focused document's selected text, empty when nothing is selected or no document is focused.
@(require_results)
markdown_selected :: proc(app: ^App, w: ^Window) -> string {
	pane := markdown_focused(app, w)
	if pane == nil {return ""}
	document := markdown_document(pane)
	return document == nil ? "" : ui.markdown_selected_text(&pane.view, document)
}

markdown_copy :: proc(app: ^App, w: ^Window) {
	if text := markdown_selected(app, w); text != "" {clipboard_copy(app, text)}
}

markdown_select_all :: proc(app: ^App, w: ^Window) {
	if pane := markdown_focused(app, w); pane != nil {
		if document := markdown_document(pane); document != nil {
			ui.markdown_select_all(&pane.view, document)
			w.dirty = true
		}
	}
}

markdown_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) {
	pane_header_cancel(w)
	key_suppress(w, e)
	key, consumed := content_key_prelude(app, w, e, true)
	if consumed {return}
	logical := key.logical
	has_find := ui.find_has_keyboard(&w.find)
	if !has_find && key.clipboard == .Copy {
		markdown_copy(app, w)
		return
	}
	if !e.pressed {return}
	if key.found && action_available(app, w, key.action) {
		run_action(app, w, key.action)
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
	line := ui.markdown_line(&pane.view)
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
		markdown_scroll(w, pane, shown, -ui.markdown_total(&pane.view))
	case .End:
		markdown_scroll(w, pane, shown, ui.markdown_total(&pane.view))
	case .Escape:
		ui.markdown_selection_clear(&pane.view)
		w.dirty = true
	}
}

// Web links open in the browser. Anything else is a file next to the document, which then takes the
// same path as a file link printed in a terminal.
@(private)
markdown_link_open :: proc(app: ^App, w: ^Window, pane: ^Markdown_Pane, link: int) {
	buffer: [links.TARGET_BYTES]u8 = ---
	target_open(app, w, target_from_href(markdown_document(pane).links[link], pane.path, buffer[:]))
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
		if markdown_document(pane) != nil {
			shape = .Text
			if link := ui.markdown_link_at(&pane.view, markdown_geometry_of(w, shown), x, y); link >= 0 {
				hover, shape = Markdown_Link_Hover{pane.id, link}, .Hand
			}
		}
	}
	markdown_hover_set(w, hover)
	pointer_set(app, w, shape)
}

// A held pane that left the window or stopped showing its document ends the gesture, since there is
// nothing left for it to select or scroll.
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
	g := markdown_geometry_of(w, shown)
	if y < g.area.y {markdown_scroll(w, pane, shown, int(y - g.area.y))}
	if y > g.area.y + g.area.height {markdown_scroll(w, pane, shown, int(y - g.area.y - g.area.height))}
	ui.markdown_select_at(&pane.view, ui.markdown_offset_at(&pane.view, document, g, x, y), true)
	w.dirty = true
	pointer_set(app, w, .Text)
}

markdown_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	pane, shown := markdown_under_pointer(app, w, x, y)
	if shown.content.kind != .Markdown {return}
	pane_focus(app, w, shown.node)
	if pane == nil || e.button != .Left {return}
	document := markdown_document(pane)
	if document == nil {return}
	w.dirty = true
	if pane_scrollbar_press(app, w, shown, x, y) {return}
	g := markdown_geometry_of(w, shown)
	if .Control in e.modifiers {
		if link := ui.markdown_link_at(&pane.view, g, x, y); link >= 0 {
			markdown_link_open(app, w, pane, link)
			return
		}
	}
	offset := ui.markdown_offset_at(&pane.view, document, g, x, y)
	ui.markdown_select_at(&pane.view, offset, .Shift in e.modifiers)
	w.markdown_gesture = Markdown_Selecting{pane.id}
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
		if pane := markdown_focused(app, w); pane != nil {
			scroll, total = pane.view.scroll, ui.markdown_total(&pane.view)
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
				selected = ui.markdown_selected_text(&pane.view, document)
			}
		}
		state_value(r, "markdown.count", len(app.markdown_panes))
		state_value(r, "markdown.active", markdown_active(w))
		state_text(r, "markdown.path", path)
		state_text(r, "markdown.state", state)
		state_value(r, "markdown.scroll", scroll)
		state_value(r, "markdown.total", total)
		state_text(r, "markdown.selection", selected)
	}
}
