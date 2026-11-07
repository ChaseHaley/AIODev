package main

import "aio:layout"
import "aio:links"
import "aio:platform"
import "aio:term"
import "aio:term_view"
import "core:log"

@(private, require_results)
link_pane :: proc(w: ^Window, content: layout.Content) -> ^Pane_View {
	for &pane, i in w.views {
		if pane.content == content {
			return &w.views[i]
		}
	}
	return nil
}

// The terminal link under the pointer: the pane content showing it and the cells the renderer
// underlines. Window.link_hover holds at most one; nil is None. This file is the only writer. Hover is
// transient view state, so it never touches the cell grid, the selection or the scrollback.
Link_Hover :: struct {
	content: layout.Content,
	range:   term.Link_Range,
}

// The underlined range in the pane showing `content`.
link_hover_range :: proc(w: ^Window, content: layout.Content) -> Maybe(term.Link_Range) {
	if hover, ok := w.link_hover.?; ok && hover.content == content {return hover.range}
	return nil
}

@(private = "file")
link_hover_set :: proc(w: ^Window, next: Maybe(Link_Hover)) {
	if w.link_hover == next {return}
	w.link_hover = next
	w.dirty = true
}

link_hover_clear :: proc(w: ^Window) {
	link_hover_set(w, nil)
}

// The pointer moved over pane content. A selection drag, a divider, the title bar or a button another
// surface swallowed hides the underline. Returns whether the pointer is over a link.
@(private, require_results)
link_hover_move :: proc(app: ^App, w: ^Window, x, y: f32, over_divider, title: bool) -> bool {
	if selection_active(w) || over_divider || title || gesture_swallowing(w) {
		link_hover_clear(w)
		return false
	}
	return link_hover_update(app, w, x, y)
}

// link_hover_update refreshes the hovered pane's spans only when its grid changed, hit-tests the
// pointer, and records the range that the renderer underlines. It returns whether the pointer is
// over a web target.
@(private, require_results)
link_cell :: proc(entry: ^Session_Entry, x, y: f32) -> (column, row: int, ok: bool) {
	g := term.geometry(entry.session)
	extent := term.grid_extent(g)
	if x < f32(g.padding_left) ||
	   y < f32(g.padding_top) ||
	   x >= f32(g.padding_left + extent.width) ||
	   y >= f32(g.padding_top + extent.height) {
		return 0, 0, false
	}
	column, row = term.cell_at(g, x, y)
	return column, row, true
}

// link_hover_update refreshes the hovered pane's spans only when its grid changed, hit-tests the
// pointer, and records the range that the renderer underlines. It returns whether the pointer is
// over a web target.
@(private = "file", require_results)
link_hover_update :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	pane, found := layout.hit_test(w.panes[:], x, y)
	entry := found ? workspace_session_for_content(app, pane.content) : nil
	state := entry != nil ? link_pane(w, pane.content) : nil
	if entry == nil || state == nil || !term_view.links_refresh(&state.view, entry.session) {
		link_hover_clear(w)
		return false
	}
	column, row, inside := link_cell(entry, x, y)
	if !inside {
		link_hover_clear(w)
		return false
	}
	range, _, hit := term.link_at(&state.view.links, column, row)
	next: Maybe(Link_Hover)
	if hit {next = Link_Hover{pane.content, range}}
	link_hover_set(w, next)
	return hit
}

@(private)
Link_Resolution :: enum {
	// Nothing under the pointer reads as a link.
	None,
	Web,
	File,
	// It reads as a local file, but none exists there.
	Missing,
}

// What a click at the point would open. The filesystem settles file links here, under D-068. The
// target borrows buffer or the pane's link state; copy it to keep it.
@(private, require_results)
link_resolve :: proc(app: ^App, w: ^Window, x, y: f32, buffer: []u8) -> (Link_Resolution, string) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found {
		return .None, ""
	}
	entry := workspace_session_for_content(app, pane.content)
	state := link_pane(w, pane.content)
	if entry == nil || state == nil || !term_view.links_refresh(&state.view, entry.session) {
		return .None, ""
	}
	column, row, inside := link_cell(entry, x, y)
	if !inside {
		return .None, ""
	}
	cwd := term.working_directory(entry.session, context.temp_allocator)
	selection, selected := term.link_selection_at(&state.view.links, column, row)
	if selected {
		if uri, web := link_selection_web(selection, buffer); web {return .Web, uri}
		if path, exists := link_selection_file(selection, cwd, buffer); exists {return .File, path}
	}
	target, hit := term.link_detected_at(&state.view.links, column, row)
	if !hit {return selected ? .Missing : .None, ""}
	if !links.allowed(target.uri) {
		path, exists := link_detected_file(target, cwd, buffer)
		return exists ? .File : .Missing, path
	}
	return .Web, target.uri
}

@(private, require_results)
link_click :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	buffer: [4096]u8 = ---
	resolution, target := link_resolve(app, w, x, y, buffer[:])
	switch resolution {
	case .None:
		return false
	case .Web:
		if !open_link(app, target) {notify(app, .Error, "Could not open the link.")}
	case .File:
		terminal_file_request(app, w, target)
	case .Missing:
		notify(app, .Error, "That local file is not available.")
	}
	return true
}

// A click is the one moment the filesystem may settle what text means, under D-068. The limit keeps a
// long line from stalling it with a run of failed checks.
@(private)
LINK_FILE_CHECKS :: 24

// link_file_exists returns the path text names when the file is there. The result borrows buffer.
@(private, require_results)
link_file_exists :: proc(text, cwd: string, checks: ^int, buffer: []u8) -> (string, bool) {
	path, valid := links.resolve_file(text, cwd, platform.local_hosts(), buffer)
	if !valid || checks^ >= LINK_FILE_CHECKS {return "", false}
	checks^ += 1
	file, exists := platform.prepare_terminal_file(path)
	if !exists {return "", false}
	platform.terminal_file_destroy(&file)
	return path, true
}

// What was underlined comes first, so a click opens what the user saw whenever it exists. Otherwise
// the longest reading of the line that exists wins.
@(private, require_results)
link_detected_file :: proc(target: term.Link_Target, cwd: string, buffer: []u8) -> (string, bool) {
	checks := 0
	if path, exists := link_file_exists(target.uri, cwd, &checks, buffer); exists {return path, true}
	ranges := make([dynamic]links.Range, context.temp_allocator)
	if !links.candidates(target.line, target.start, target.end, target.cuts, &ranges) {return "", false}
	for r in ranges {
		if path, exists := link_break_readings(target.line[r.start:r.end], cwd, &checks, buffer); exists {
			return path, true
		}
	}
	return "", false
}

@(private, require_results)
link_break_readings :: proc(text, cwd: string, checks: ^int, buffer: []u8) -> (string, bool) {
	spelling: [4096]u8 = ---
	for mask := links.break_variants(text) - 1; mask >= 0; mask -= 1 {
		reading, ok := links.break_variant(text, mask, spelling[:])
		if !ok {continue}
		if path, exists := link_file_exists(reading, cwd, checks, buffer); exists {return path, true}
	}
	return "", false
}

@(private, require_results)
link_selection_file :: proc(selection: term.Link_Target, cwd: string, buffer: []u8) -> (string, bool) {
	checks := 0
	return link_break_readings(selection.line[selection.start:selection.end], cwd, &checks, buffer)
}

@(private, require_results)
link_selection_web :: proc(selection: term.Link_Target, buffer: []u8) -> (string, bool) {
	text := selection.line[selection.start:selection.end]
	for mask := links.break_variants(text) - 1; mask >= 0; mask -= 1 {
		reading, ok := links.break_variant(text, mask, buffer)
		if ok && links.allowed(reading) {return reading, true}
	}
	return "", false
}

// link_hover_refresh keeps an underline honest while output or scrolling changes the grid under
// a stationary pointer. It only scans the pane already showing a hovered link, so ordinary
// output never pays for link detection.
@(private)
link_hover_refresh :: proc(app: ^App, w: ^Window) {
	hover, hovering := w.link_hover.?
	if !hovering {return}
	pane := link_pane(w, hover.content)
	if pane == nil {
		link_hover_clear(w)
		return
	}
	w.link_hover = link_hover_at_pointer(app, w, pane)
	pointer_set(app, w, w.link_hover != nil ? .Hand : .Text)
}

@(private = "file")
link_hover_at_pointer :: proc(app: ^App, w: ^Window, pane: ^Pane_View) -> Maybe(Link_Hover) {
	hovered, found := layout.hit_test(w.panes[:], w.pointer.x, w.pointer.y)
	if !found || hovered.content != pane.content {return nil}
	entry := workspace_session_for_content(app, pane.content)
	if entry == nil || !term_view.links_refresh(&pane.view, entry.session) {return nil}
	column, row, inside := link_cell(entry, w.pointer.x, w.pointer.y)
	if !inside {return nil}
	range, _, over := term.link_at(&pane.view.links, column, row)
	if !over {return nil}
	return Link_Hover{pane.content, range}
}

@(private, require_results)
open_link :: proc(app: ^App, uri: string) -> bool {
	when ODIN_TEST {
		// A test that reaches a link without installing a stub must not launch a browser.
		if app.open_url == nil {
			log.error("a terminal link was clicked in a test without an opener stub")
			return false
		}
	}
	opener := app.open_url
	if opener == nil {
		opener = platform.open_url
	}
	if !opener(uri) {
		log.errorf("opening the web target failed: %s", uri)
		return false
	}
	return true
}
