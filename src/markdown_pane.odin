package main

import "aio:commands"
import "aio:glyphs"
import "aio:layout"
import "aio:links"
import "aio:markdown"
import "aio:platform"
import "aio:render"
import "aio:settings"
import "aio:term"
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
// The same step as a terminal's search, so a long document never stalls a frame.
@(private)
MARKDOWN_FIND_BUDGET :: 2 * time.Millisecond

Markdown_State :: enum u8 {
	Loaded,
	Missing,
	Too_Large,
	Failed,
}

// Owned by App.markdown_panes; panes refer to it by id and the poll frees it once none does.
Markdown_Pane :: struct {
	id:                     u32,
	path, title, directory: string,
	documents: Document_List,
	// False until the path has passed the local-file checks. A path from the saved layout may be
	// gone or point anywhere, so the poll must not touch it directly.
	verified:               bool,
	state:                  Markdown_State,
	document:               markdown.Document,
	view:                   ui.Markdown_View,
	search:                 markdown.Search,
	revision:               u64,
	modified:               time.Time,
	size:                   i64,
	scroll_drag:            ui.Scroll_Drag,
	bar_hover:              bool,
}

markdown_is_path :: proc(path: string) -> bool {
	extension := strings.to_lower(filepath.ext(path), context.temp_allocator)
	return extension == ".md" || extension == ".markdown"
}

@(require_results)
markdown_find :: proc(app: ^App, id: u32) -> ^Markdown_Pane {
	for pane in app.markdown_panes {if pane.id == id {return pane}}
	return nil
}

@(private)
markdown_pane_destroy :: proc(pane: ^Markdown_Pane) {
	documents_destroy(&pane.documents)
	markdown.document_destroy(&pane.document)
	ui.markdown_view_destroy(&pane.view)
	markdown.search_destroy(&pane.search)
	delete(pane.path)
	delete(pane.title)
	delete(pane.directory)
	free(pane)
}

markdown_panes_destroy :: proc(app: ^App) {
	if app.markdown_pick != nil {
		platform.file_pick_destroy(app.markdown_pick)
		app.markdown_pick = nil
	}
	document_pick_destroy(app)
	for pane in app.markdown_panes {markdown_pane_destroy(pane)}
	delete(app.markdown_panes)
	app.markdown_panes = nil
}

@(private)
markdown_path_set :: proc(pane: ^Markdown_Pane, path: string) -> bool {
	owned, err := strings.clone(path)
	if err != nil {return false}
	title, title_error := strings.clone(filepath.base(path))
	if title_error != nil {delete(owned); return false}
	directory, directory_error := settings.directory_label(filepath.dir(path))
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
	pane.verified, pane.state = verified, .Missing
	if verified {_ = markdown_pane_load(pane)}
	if app.markdown_deadline == {} {app.markdown_deadline = time.tick_add(time.tick_now(), MARKDOWN_POLL)}
	return pane
}

// Re-reads the file when it changed. A failed read keeps what is showing and tries again next poll,
// because a writer can hold the file for a moment. Returns whether the pane shows something new.
@(private, require_results)
markdown_pane_load :: proc(pane: ^Markdown_Pane) -> bool {
	info, stat_error := os.stat(pane.path, context.temp_allocator)
	if stat_error != nil {
		changed := pane.state != .Missing
		pane.state, pane.modified, pane.size = .Missing, {}, 0
		return changed
	}
	if pane.state == .Loaded && info.modification_time == pane.modified && info.size == pane.size {return false}
	if info.size > MARKDOWN_SIZE_LIMIT {
		changed := pane.state != .Too_Large
		pane.state, pane.modified, pane.size = .Too_Large, info.modification_time, info.size
		return changed
	}
	data, read_error := os.read_entire_file(pane.path, context.allocator)
	if read_error != nil {
		log.errorf("reading the Markdown file failed: %v", read_error)
		return false
	}
	defer delete(data)
	next: markdown.Document
	if !markdown.parse(string(data), &next) {
		log.error("parsing the Markdown file ran out of memory")
		changed := pane.state != .Failed
		pane.state = .Failed
		return changed
	}
	markdown.document_destroy(&pane.document)
	pane.document = next
	pane.state, pane.modified, pane.size = .Loaded, info.modification_time, info.size
	pane.revision += 1
	ui.markdown_selection_clear(&pane.view)
	markdown.search_restart(&pane.search)
	return true
}

// A pane not showing its document has nothing to find, whatever it last searched.
@(require_results)
markdown_find_summary :: proc(pane: ^Markdown_Pane) -> term.Search_Summary {
	s := &pane.search
	if !s.active {return {selected = -1}}
	if pane.state != .Loaded {return {active = true, complete = true, selected = -1, invalid = s.invalid}}
	total := len(s.matches)
	return {
		active = true,
		complete = s.complete || s.invalid,
		total = total,
		selected = s.selected,
		invalid = s.invalid,
		revision = s.revision,
	}
}

markdown_find_select :: proc(w: ^Window, pane: ^Markdown_Pane, upward: bool) {
	if pane.state != .Loaded || !markdown.search_select(&pane.search, upward) {return}
	match := pane.search.matches[pane.search.selected]
	if shown, found := markdown_pane_rect(w, pane.id); found {
		visible := int(markdown_geometry_of(w, shown.rect).area.height)
		ui.markdown_reveal(&pane.view, match.start, match.end, visible)
	}
}

@(require_results)
markdown_find_pending :: proc(app: ^App) -> bool {
	for pane in app.markdown_panes {if markdown.search_pending(&pane.search) {return true}}
	return false
}

markdown_find_tick :: proc(app: ^App) {
	for pane in app.markdown_panes {
		if !markdown.search_pending(&pane.search) {continue}
		before := markdown_find_summary(pane)
		markdown.search_update(&pane.search, &pane.document, MARKDOWN_FIND_BUDGET)
		if markdown_find_summary(pane) != before {mark_all_dirty(app)}
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
	markdown_pick_tick(app)
	document_pick_tick(app)
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
		if !pane.verified {
			file, ok := platform.prepare_terminal_file(pane.path)
			if !ok {continue}
			defer platform.terminal_file_destroy(&file)
			if file.confirm || !markdown_path_set(pane, file.target) {continue}
			pane.verified = true
			changed = true
		}
		changed = markdown_pane_load(pane) || changed
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
	tab, record_error := tab_record_reserve(workspace)
	if record_error != .None {return false}
	if layout.init(&tab.tree, content) != nil {
		tab_record_free(tab)
		return false
	}
	tab_record_commit(app, workspace, tab)
	if focus && w != nil {tab_select(app, w, len(workspace.tabs) - 1)}
	return true
}

// Shows a verified file beside `node`: the pane already showing it, a new split, or a new tab when
// the pane is too small to split. `w` is the window showing the workspace, or nil.
@(require_results)
markdown_open_at :: proc(
	app: ^App,
	w: ^Window,
	workspace: ^Workspace,
	tab_index: int,
	node: layout.Node_Id,
	path: string,
	direction: layout.Direction = .Right,
	ratio: f32 = 0.5,
	focus := true,
) -> bool {
	walk := workspace_panes(app, workspace)
	for shown, ok := workspace_pane_next(&walk); ok; shown, ok = workspace_pane_next(&walk) {
		if shown.content.kind != .Markdown {continue}
		pane := markdown_find(app, shown.content.id)
		if pane == nil || !strings.equal_fold(pane.path, path) {continue}
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
	if w != nil && w.linked {
		opened = markdown_new_tab(app, nil, workspace, content, false)
	} else {
		failure := pane_split_insert(app, w, workspace, tab_index, node, direction, ratio, focus, content, false)
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
	if !markdown_open_at(app, acting, workspace, workspace.selected, acting.tree.focus, path) {
		notify(app, .Error, "Could not open the file.")
	}
}

// The Open Markdown File command from a key or the palette.
markdown_open_picker :: proc(app: ^App, w: ^Window) {
	if app.markdown_pick != nil || !gesture_cancel(app, w) {return}
	palette_close(app, w)
	directory := ""
	if entry := focused_session(app, w); entry != nil {directory, _ = pane_directory(app, entry)}
	pick := platform.file_pick_start(&app.platform, w.id, "Markdown files", "*.md;*.markdown", directory)
	if pick == nil {
		notify(app, .Error, "Could not show the file dialog.")
		return
	}
	app.markdown_pick, app.markdown_pick_window = pick, w.id
}

// Opens what the dialog chose once it closes. The window may have gone in the meantime.
@(private)
markdown_pick_tick :: proc(app: ^App) {
	if app.markdown_pick == nil {return}
	path, finished := platform.file_pick_finished(app.markdown_pick)
	if !finished {return}
	if w := window_find(app, app.markdown_pick_window); w != nil && path != "" {
		terminal_file_request(app, w, path)
	}
	platform.file_pick_destroy(app.markdown_pick)
	app.markdown_pick = nil
}

@(require_results)
control_markdown_open :: proc(
	app: ^App,
	w: ^Window,
	target: Pane_Target,
	invocation: commands.Invocation,
) -> Outcome {
	if .Text not_in invocation.given {return outcome_failure(.Usage, "name a file to open")}
	file, ok := platform.prepare_terminal_file(invocation.text)
	if !ok {return outcome_failure(.Failed, "that file is not available; use a local, absolute path")}
	defer platform.terminal_file_destroy(&file)
	if file.confirm {return outcome_failure(.Failed, "that file type is not shown as Markdown")}
	direction: layout.Direction = .Direction in invocation.given ? invocation.direction : .Right
	ratio: f32 = .Ratio in invocation.given ? invocation.ratio : 0.5
	if !markdown_open_at(
		app,
		w,
		target.workspace,
		target.pane.tab,
		target.pane.node,
		file.target,
		direction,
		ratio,
		invocation.focus,
	) {
		return outcome_failure(.Failed, "could not open the file")
	}
	return {}
}

// The window's focused pane when it shows Markdown.
@(require_results)
markdown_focused :: proc(app: ^App, w: ^Window) -> ^Markdown_Pane {
	if w.tree == nil || w.tree.focus == layout.INVALID_NODE {return nil}
	pane, ok := w.tree.nodes[w.tree.focus].(layout.Pane)
	if !ok || pane.content.kind != .Markdown {return nil}
	return markdown_find(app, pane.content.id)
}

markdown_active :: proc(w: ^Window) -> bool {
	if w.tree == nil || w.tree.focus == layout.INVALID_NODE {return false}
	pane, ok := w.tree.nodes[w.tree.focus].(layout.Pane)
	return ok && pane.content.kind == .Markdown
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
markdown_geometry_of :: proc(w: ^Window, rect: layout.Rect) -> ui.Markdown_Geometry {
	area := render.Rect{rect.x, rect.y + w.header_height, rect.width, max(0, rect.height - w.header_height)}
	return ui.markdown_geometry(area, w.scale)
}

@(private, require_results)
markdown_bar :: proc(w: ^Window, pane: ^Markdown_Pane, rect: layout.Rect) -> (ui.Scrollbar, bool) {
	area := markdown_geometry_of(w, rect).area
	area.width -= 2 * w.scale
	area.height -= 4 * w.scale
	extent := ui.Scroll_Extent{ui.markdown_total(&pane.view), int(area.height), pane.view.scroll}
	state := ui.scrollbar_state(pane.bar_hover, pane.scroll_drag)
	return ui.scrollbar_layout(area, extent, state, w.scale)
}

// A pane that is not showing a document says why, once.
@(private, require_results)
markdown_message_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: ^Markdown_Pane,
	g: ui.Markdown_Geometry,
) -> glyphs.Result {
	if render.push_layer(&w.list, g.area, 0) != .None {return .Ok}
	message := "This file could not be read."
	path := ""
	if pane != nil {
		path = pane.path
		#partial switch pane.state {
		case .Missing:
			message = "This file is not available."
		case .Too_Large:
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
markdown_pane_draw :: proc(app: ^App, w: ^Window, shown: layout.Pane_Rect, card: int) -> glyphs.Result {
	if card < len(w.list.rects) {w.list.rects[card].color = app.theme.pane}
	pane := markdown_find(app, shown.content.id)
	g := markdown_geometry_of(w, shown.rect)
	if pane != nil && pane.state == .Loaded {
		view := &pane.view
		ui.markdown_view_fit(view, &pane.document, pane.revision, &w.ui_text, app.family, g.width, w.scale)
		ui.markdown_scroll_by(view, 0, int(g.area.height))
		find: ui.Markdown_Find
		if pane.search.active {
			c := app.settings.colors
			find = {
				matches = pane.search.matches[:],
				selected = pane.search.selected,
				foreground = color(c.search_foreground),
				background = color(c.search_background),
				selected_background = color(c.search_selected_background),
			}
		}
		if result := ui.markdown_draw(view, &pane.document, g, &w.list, &w.ui_text, app.theme, find);
		   result != .Ok {
			return result
		}
		if bar, visible := markdown_bar(w, pane, shown.rect); visible {
			ui.scrollbar_draw(&w.list, app.theme, bar, ui.scrollbar_state(pane.bar_hover, pane.scroll_drag))
		}
	} else if result := markdown_message_draw(app, w, pane, g); result != .Ok {return result}
	if header := pane_header_draw(app, w, shown, nil); header != .Ok {return header}
	window_card_dim(app, w, shown, app.theme.pane)
	window_card_outline(app, w, shown)
	return .Ok
}

@(private)
markdown_scroll :: proc(w: ^Window, pane: ^Markdown_Pane, shown: layout.Pane_Rect, delta: int) {
	visible := int(markdown_geometry_of(w, shown.rect).area.height)
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
	visible := int(markdown_geometry_of(w, shown.rect).area.height)
	page := max(1, visible - ui.markdown_line(&pane.view))
	markdown_scroll(w, pane, shown, int(pages * f64(page)))
}

markdown_copy :: proc(app: ^App, w: ^Window) {
	if pane := markdown_focused(app, w); pane != nil {
		text := ui.markdown_selected_text(&pane.view, &pane.document)
		if text != "" {clipboard_copy(app, text)}
	}
}

markdown_select_all :: proc(app: ^App, w: ^Window) {
	if pane := markdown_focused(app, w); pane != nil {
		pane.view.anchor, pane.view.head = 0, len(pane.document.text)
		w.dirty = true
	}
}

markdown_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) {
	pane_header_cancel(w)
	if e.pressed {w.suppressed_key = e}
	has_find := ui.find_has_keyboard(&w.find)
	if has_find && e.pressed && e.key == .Escape && w.leader_until == {} {
		find_close(app, w, find_target(app, w))
		return
	}
	literal := false
	switch leader_key(app, w, e) {
	case .Consumed:
		return
	case .Literal:
		literal = true
	case .None:
	}
	logical := e
	logical.key = commands.logical_key(e.key, e.unshifted)
	if !has_find && clipboard_chord(logical) == .Copy {
		markdown_copy(app, w)
		return
	}
	if !e.pressed {return}
	if !literal {
		if action, found := shortcut_action(app, e); found {
			command_run(app, w, action, .Key)
			return
		}
	}
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
	uri := pane.document.links[link]
	if links.allowed(uri) {
		if !open_link(app, uri) {notify(app, .Error, "Could not open the link.")}
		return
	}
	target := uri
	if fragment := strings.index_byte(target, '#'); fragment >= 0 {target = target[:fragment]}
	buffer: [4096]u8 = ---
	directory := filepath.dir(pane.path)
	path, ok := links.resolve_file(target, directory, platform.local_hosts(), buffer[:])
	if ok {terminal_file_request(app, w, path)} else {notify(app, .Error, "That local file is not available.")}
}

// Pointer surface

markdown_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	shown, found := layout.hit_test(w.panes[:], x, y)
	return found && shown.content.kind == .Markdown
}

@(private)
markdown_hover_clear :: proc(app: ^App, w: ^Window, except: ^Markdown_Pane) {
	for shown in w.panes {
		if shown.content.kind != .Markdown {continue}
		pane := markdown_find(app, shown.content.id)
		if pane == nil || pane == except {continue}
		if pane.bar_hover || pane.view.hover_link >= 0 {w.dirty = true}
		pane.bar_hover, pane.view.hover_link = false, -1
	}
}

markdown_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	if w.markdown_held != 0 {
		pane := markdown_find(app, w.markdown_held)
		shown, found := markdown_pane_rect(w, w.markdown_held)
		if pane == nil || !found {w.markdown_held = 0; return}
		w.pointer = {x, y}
		if pane.scroll_drag.active {
			if bar, visible := markdown_bar(w, pane, shown.rect); visible {
				pane.view.scroll = ui.scrollbar_drag(pane.scroll_drag, bar, y)
				w.dirty = true
			}
			return
		}
		g := markdown_geometry_of(w, shown.rect)
		if y < g.area.y {markdown_scroll(w, pane, shown, int(y - g.area.y))}
		if y > g.area.y + g.area.height {markdown_scroll(w, pane, shown, int(y - g.area.y - g.area.height))}
		pane.view.head = ui.markdown_offset_at(&pane.view, &pane.document, g, x, y)
		pane.view.selecting = true
		w.dirty = true
		pointer_set(app, w, .Text)
		return
	}
	if owner != .Markdown_Page {
		markdown_hover_clear(app, w, nil)
		return
	}
	pane, shown := markdown_under_pointer(app, w, x, y)
	markdown_hover_clear(app, w, pane)
	if pane == nil {pointer_set(app, w, .Arrow); return}
	bar, visible := markdown_bar(w, pane, shown.rect)
	over_bar := visible && ui.scrollbar_contains(bar, x, y)
	link := -1
	if !over_bar && pane.state == .Loaded {
		link = ui.markdown_link_at(&pane.view, markdown_geometry_of(w, shown.rect), x, y)
	}
	if over_bar != pane.bar_hover || link != pane.view.hover_link {w.dirty = true}
	pane.bar_hover, pane.view.hover_link = over_bar, link
	switch {
	case over_bar:
		pointer_set(app, w, .Arrow)
	case link >= 0:
		pointer_set(app, w, .Hand)
	case:
		pointer_set(app, w, pane.state == .Loaded ? .Text : .Arrow)
	}
}

markdown_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	pane, shown := markdown_under_pointer(app, w, x, y)
	if shown.content.kind != .Markdown {return}
	pane_focus(app, w, shown.node)
	if pane == nil || pane.state != .Loaded || e.button != .Left {return}
	w.dirty = true
	if bar, visible := markdown_bar(w, pane, shown.rect); visible && ui.scrollbar_contains(bar, x, y) {
		pane.view.scroll = ui.scrollbar_press(&pane.scroll_drag, bar, y)
		if pane.scroll_drag.active {w.markdown_held = pane.id}
		return
	}
	g := markdown_geometry_of(w, shown.rect)
	if .Control in e.modifiers {
		if link := ui.markdown_link_at(&pane.view, g, x, y); link >= 0 {
			markdown_link_open(app, w, pane, link)
			return
		}
	}
	offset := ui.markdown_offset_at(&pane.view, &pane.document, g, x, y)
	if .Shift not_in e.modifiers {pane.view.anchor = offset}
	pane.view.head = offset
	w.markdown_held = pane.id
}

markdown_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button != .Left || w.markdown_held == 0 {return false}
	markdown_gesture_clear(app, w)
	return true
}

markdown_gesture_clear :: proc(app: ^App, w: ^Window) {
	if w.markdown_held == 0 {return}
	if pane := markdown_find(app, w.markdown_held); pane != nil {
		pane.scroll_drag = {}
		pane.view.selecting = false
	}
	w.markdown_held = 0
	w.dirty = true
}
