package main

import "aio:layout"
import "aio:links"
import "aio:localpath"
import "aio:term"

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

// The terminal cell under a point and the pane state indexing its links. It borrows the window's
// views, so it is for immediate use only.
@(private)
Terminal_Link_Hit :: struct {
	content:     layout.Content,
	entry:       ^Session_Entry,
	pane:        ^Pane_View,
	column, row: int,
}

// The one way hover, click and refresh find a link cell: the terminal pane under the point, its link
// index brought up to date only when the grid changed, and the cell. Settings and Markdown panes
// have no session, so they never hit. It does no filesystem work.
@(private, require_results)
terminal_link_probe :: proc(app: ^App, w: ^Window, x, y: f32) -> (hit: Terminal_Link_Hit, ok: bool) {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found {return}
	entry := workspace_session_for_content(app, pane.content)
	state := entry != nil ? pane_view(w, pane.content) : nil
	if state == nil || !term.link_map_refresh(&state.links, entry.session) {return}
	g := term.geometry(entry.session)
	extent := term.grid_extent(g)
	if x < f32(g.padding_left) ||
	   y < f32(g.padding_top) ||
	   x >= f32(g.padding_left + extent.width) ||
	   y >= f32(g.padding_top + extent.height) {
		return
	}
	column, row := term.cell_at(g, x, y)
	return {pane.content, entry, state, column, row}, true
}

// The link the probe finds at the point, as the renderer underlines it.
@(private = "file", require_results)
link_hover_at :: proc(app: ^App, w: ^Window, x, y: f32) -> Maybe(Link_Hover) {
	hit, ok := terminal_link_probe(app, w, x, y)
	if !ok {return nil}
	range, _, over := term.link_at(&hit.pane.links, hit.column, hit.row)
	if !over {return nil}
	return Link_Hover{hit.content, range}
}

// Records the range the renderer underlines under the pointer. It returns whether the pointer is
// over a link.
@(private = "file", require_results)
link_hover_update :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	next := link_hover_at(app, w, x, y)
	link_hover_set(w, next)
	return next != nil
}

// What a click at the point would open; nil when nothing under the pointer reads as a link. The
// filesystem settles file links here, under D-068. Strings borrow buffer or the pane's link state;
// copy them to keep them.
@(private, require_results)
link_resolve :: proc(app: ^App, w: ^Window, x, y: f32, buffer: []u8) -> Target {
	hit, ok := terminal_link_probe(app, w, x, y)
	if !ok {
		return nil
	}
	cwd := term.working_directory(hit.entry.session, context.temp_allocator)
	selection, selected := term.link_selection_at(&hit.pane.links, hit.column, hit.row)
	if selected {
		if uri, web := link_selection_web(selection, buffer); web {return Web_Target{uri}}
		if path, exists := link_selection_file(selection, cwd, buffer); exists {return File_Target{path}}
	}
	target, detected := term.link_detected_at(&hit.pane.links, hit.column, hit.row)
	if !detected {
		if selected {return Missing_Target{}}
		return nil
	}
	if !links.allowed(target.uri) {
		if path, exists := link_detected_file(target, cwd, buffer); exists {return File_Target{path}}
		return Missing_Target{}
	}
	return Web_Target{target.uri}
}

@(private, require_results)
link_click :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	buffer: [links.TARGET_BYTES]u8 = ---
	target := link_resolve(app, w, x, y, buffer[:])
	if target == nil {return false}
	target_open(app, w, target)
	return true
}

// A click is the one moment the filesystem may settle what text means, under D-068. The limit keeps a
// long line from stalling it with a run of failed checks.
@(private)
LINK_FILE_CHECKS :: 24

// link_file_exists returns the path text names when an openable file is there. The result borrows
// buffer.
@(private, require_results)
link_file_exists :: proc(text, cwd: string, checks: ^int, buffer: []u8) -> (string, bool) {
	path, valid := links.resolve_file(text, cwd, localpath.local_hosts(), buffer)
	if !valid || checks^ >= LINK_FILE_CHECKS {return "", false}
	checks^ += 1
	if !localpath.file_available(path) {return "", false}
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
	spelling: [links.TARGET_BYTES]u8 = ---
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
	if pane_view(w, hover.content) == nil {
		link_hover_clear(w)
		return
	}
	// Only the pane already showing the link is scanned again.
	under, found := layout.hit_test(w.panes[:], w.pointer.x, w.pointer.y)
	next: Maybe(Link_Hover)
	if found && under.content == hover.content {next = link_hover_at(app, w, w.pointer.x, w.pointer.y)}
	link_hover_set(w, next)
	pointer_set(app, w, next != nil ? .Hand : .Text)
}

when AIO_CONTROL {
	// Hover state and the link count prove the interaction from a control journey without reading
	// pixels: the range and target name the cells under the pointer, and pointer.shape is what the
	// OS was asked to show.
	link_state_report :: proc(r: ^State_Report, w: ^Window) {
		hover, uri := "none", ""
		spans := 0
		for &view in w.views {spans += term.link_span_count(&view.links)}
		if link, ok := w.link_hover.?; ok {
			if view := pane_view(w, link.content); view != nil {
				range := link.range
				hover = state_key("%d,%d-%d,%d", range.first_row, range.first_column, range.last_row, range.last_column)
				if _, target, found := term.link_at(&view.links, range.first_column, range.first_row); found {
					uri = target
				}
			}
		}
		state_text(r, "link.hover", hover)
		state_text(r, "link.uri", uri)
		state_value(r, "link.spans", spans)
	}
}
