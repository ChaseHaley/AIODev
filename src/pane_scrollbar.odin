package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:ui"

// The overlay scrollbar of terminal and Markdown panes: one hover and one held thumb per window,
// keyed by the content whose bar it is. A terminal scrolls by rows and only shows its bar when the
// setting asks; a Markdown page scrolls by pixels. Each content kind reaches the bar through its own
// pointer surface (the Scrollbar surface for terminals, the page for Markdown, which also focuses
// its pane), so each surface clears only its own kind. The procs in this file are the only writers.
Pane_Scrollbars :: struct {
	hover: Maybe(layout.Content),
	drag:  Maybe(Pane_Scroll_Drag),
}

// A held thumb: the content whose bar it is and where the pointer grabbed it.
Pane_Scroll_Drag :: struct {
	content: layout.Content,
	grab:    ui.Scroll_Drag,
}

// The bar sits inside the content area, clear of the card's rounded edge and bottom.
pane_scrollbar_area :: proc(area: render.Rect, scale: f32) -> render.Rect {
	return {area.x, area.y, area.width - 2 * scale, area.height - 4 * scale}
}

pane_scrollbar_state :: proc(w: ^Window, content: layout.Content) -> ui.Scrollbar_State {
	drag: ui.Scroll_Drag
	if held, ok := w.scrollbars.drag.?; ok && held.content == content {drag = held.grab}
	hover, hovering := w.scrollbars.hover.?
	return ui.scrollbar_state(hovering && hover == content, drag)
}

pane_scrollbar_dragging :: proc(w: ^Window) -> bool {
	return w.scrollbars.drag != nil
}

// Where the bar of the shown pane is, when it has one. Terminal extents are rows and Markdown
// extents pixels; each content kind lays out its own content area first.
pane_scrollbar_geometry :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
) -> (
	bar: ui.Scrollbar,
	visible: bool,
) {
	extent: ui.Scroll_Extent
	area: render.Rect
	#partial switch pane.content.kind {
	case .Terminal:
		entry := workspace_session_for_content(app, pane.content)
		if entry == nil || !app.settings.terminal.scrollbar {return}
		lines, ok := term.scrollbar(entry.session)
		if !ok {return}
		header := pane_header_of(w, pane)
		r := pane.rect
		area = pane_scrollbar_area({r.x, r.y + header, r.width, r.height - header}, w.scale)
		extent = {int(lines.total), int(lines.len), int(lines.offset)}
	case .Markdown:
		page := markdown_find(app, pane.content.id)
		if page == nil || markdown_document(page) == nil {return}
		area = pane_scrollbar_area(markdown_geometry_of(w, pane).area, w.scale)
		extent = {ui.markdown_total(&page.view), int(area.height), page.view.scroll}
	case:
		return
	}
	return ui.scrollbar_layout(area, extent, pane_scrollbar_state(w, pane.content), w.scale)
}

pane_scrollbar_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect) {
	bar, visible := pane_scrollbar_geometry(app, w, pane)
	if visible {ui.scrollbar_draw(&w.list, app.theme, bar, pane_scrollbar_state(w, pane.content))}
}

// The content whose visible bar holds the point, on the topmost pane there.
pane_scrollbar_at :: proc(app: ^App, w: ^Window, x, y: f32) -> (content: layout.Content, found: bool) {
	pane, hit := layout.hit_test(w.panes[:], x, y)
	if !hit {return}
	bar, visible := pane_scrollbar_geometry(app, w, pane)
	if !visible || !ui.scrollbar_contains(bar, x, y) {return}
	return pane.content, true
}

// Moves the content's view to `offset` on its bar: rows for a terminal, pixels for a page.
@(private = "file")
pane_scrollbar_apply :: proc(app: ^App, content: layout.Content, bar: ui.Scrollbar, offset: int) {
	#partial switch content.kind {
	case .Terminal:
		entry := workspace_session_for_content(app, content)
		if entry != nil && offset != bar.extent.offset {
			term.scroll_viewport(entry.session, offset - bar.extent.offset)
		}
	case .Markdown:
		if page := markdown_find(app, content.id); page != nil {page.view.scroll = offset}
	}
}

// A Left press on the bar of the shown pane: a track press pages once, and only a thumb press holds
// the bar. False when the point is not on its bar.
pane_scrollbar_press :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, x, y: f32) -> bool {
	bar, visible := pane_scrollbar_geometry(app, w, pane)
	if !visible || !ui.scrollbar_contains(bar, x, y) {return false}
	grab: ui.Scroll_Drag
	pane_scrollbar_apply(app, pane.content, bar, ui.scrollbar_press(&grab, bar, y))
	w.scrollbars.drag = nil
	if grab.active {w.scrollbars.drag = Pane_Scroll_Drag{pane.content, grab}}
	w.dirty = true
	return true
}

// The held thumb follows the pointer, over whichever pane it passes. A page that stopped showing its
// document, or content that left the window, ends the drag; a bar that is hidden keeps it.
pane_scrollbar_move :: proc(app: ^App, w: ^Window, x, y: f32) {
	held, ok := w.scrollbars.drag.?
	if !ok {return}
	for pane in w.panes {
		if pane.content != held.content {continue}
		if held.content.kind == .Markdown {
			page := markdown_find(app, held.content.id)
			if page == nil || markdown_document(page) == nil {break}
			w.pointer = {x, y}
		}
		bar, visible := pane_scrollbar_geometry(app, w, pane)
		if !visible {return}
		pane_scrollbar_apply(app, held.content, bar, ui.scrollbar_drag(held.grab, bar, y))
		w.dirty = true
		return
	}
	w.scrollbars.drag = nil
	if held.content.kind == .Markdown {w.dirty = true}
}

// Ends a held thumb of `kind`; reports whether there was one.
pane_scrollbar_end :: proc(w: ^Window, kind: layout.Content_Kind) -> bool {
	held, ok := w.scrollbars.drag.?
	if !ok || held.content.kind != kind {return false}
	w.scrollbars.drag = nil
	return true
}

// Records the bar under the pointer, repainting only when that changes.
pane_scrollbar_hover_set :: proc(w: ^Window, next: Maybe(layout.Content)) {
	if w.scrollbars.hover != next {w.scrollbars.hover, w.dirty = next, true}
}

// The pointer left the surface that shows bars of `kind`.
pane_scrollbar_hover_leave :: proc(w: ^Window, kind: layout.Content_Kind) {
	if hover, ok := w.scrollbars.hover.?; ok && hover.kind == kind {pane_scrollbar_hover_set(w, nil)}
}

// Terminal bars belong to the Scrollbar pointer surface.

terminal_scrollbar_at :: proc(app: ^App, w: ^Window, x, y: f32) -> (content: layout.Content, found: bool) {
	content, found = pane_scrollbar_at(app, w, x, y)
	return content, found && content.kind == .Terminal
}

// Records which terminal's track is under the pointer; true when one is.
terminal_scrollbar_hover :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	content, over := layout.Content{}, false
	if !selection_active(w) {content, over = terminal_scrollbar_at(app, w, x, y)}
	if over {pane_scrollbar_hover_set(w, content)} else {pane_scrollbar_hover_leave(w, .Terminal)}
	return over
}

terminal_scrollbar_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if !e.pressed || e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || pane.content.kind != .Terminal {return false}
	return pane_scrollbar_press(app, w, pane, x, y)
}

terminal_scrollbar_release :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if !pane_scrollbar_end(w, .Terminal) {return false}
	w.dirty = true
	terminal_scrollbar_hover(app, w, x, y)
	return true
}
