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

// link_hover_clear drops every underline state. Hover is transient view state, so it never
// touches the cell grid, the selection, or the scrollback.
link_hover_clear :: proc(w: ^Window) {
	changed := false
	for &pane in w.views {
		if pane.hover != nil {
			pane.hover = nil
			changed = true
		}
	}
	if changed {
		w.dirty = true
	}
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
@(private, require_results)
link_hover_update :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	pane, found := layout.hit_test(w.panes[:], x, y)
	terminal := found && pane.content.kind == .Terminal
	entry := terminal ? session_find(app, pane.content.id) : nil
	state := terminal ? link_pane(w, pane.content) : nil
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
	changed := false
	for &candidate in w.views {
		next: Maybe(term.Link_Range)
		if &candidate == state && hit {
			next = range
		}
		if candidate.hover != next {
			candidate.hover = next
			changed = true
		}
	}
	if changed {
		w.dirty = true
	}
	return hit
}

@(private, require_results)
link_click :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || pane.content.kind != .Terminal {
		return false
	}
	entry := session_find(app, pane.content.id)
	state := link_pane(w, pane.content)
	if entry == nil || state == nil || !term_view.links_refresh(&state.view, entry.session) {
		return false
	}
	column, row, inside := link_cell(entry, x, y)
	if !inside {
		return false
	}
	_, uri, hit := term.link_at(&state.view.links, column, row)
	if !hit {
		return false
	}
	if !links.allowed(uri) {
		cwd := term.working_directory(entry.session, context.temp_allocator)
		buffer: [4096]u8
		path, ok := links.resolve_file(uri, cwd, buffer[:])
		if ok {terminal_file_request(app, w, path)}
		else {notify(app, .Error, "That local file is not available.")}
		return true
	}
	if !open_link(app, uri) {
		notify(app, .Error, "Could not open the link.")
	}
	return true
}

// link_hover_refresh keeps an underline honest while output or scrolling changes the grid under
// a stationary pointer. It only scans panes that are already showing a hovered link, so ordinary
// output never pays for link detection.
@(private)
link_hover_refresh :: proc(app: ^App, w: ^Window) {
	hit, touched := false, false
	for &pane in w.views {
		if pane.hover == nil {
			continue
		}
		touched = true
		hovered, found := layout.hit_test(w.panes[:], w.pointer.x, w.pointer.y)
		if !found || hovered.content != pane.content {
			pane.hover = nil
			continue
		}
		entry := session_find(app, pane.content.id)
		if entry == nil || !term_view.links_refresh(&pane.view, entry.session) {
			pane.hover = nil
			continue
		}
		column, row, inside := link_cell(entry, w.pointer.x, w.pointer.y)
		if !inside {
			pane.hover = nil
			continue
		}
		range, _, over := term.link_at(&pane.view.links, column, row)
		pane.hover = nil
		if over {
			pane.hover = range
			hit = true
		}
	}
	if touched {
		pointer_set(app, w, hit ? .Hand : .Text)
	}
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
