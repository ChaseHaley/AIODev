package main

import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:ui"

terminal_scrollbar_state :: proc(w: ^Window, id: u32) -> ui.Scrollbar_State {
	drag := w.scroll_session == id ? w.scroll_drag : {}
	return ui.scrollbar_state(w.scroll_hover == id, drag)
}

terminal_scrollbar_geometry :: proc(
	app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry,
) -> (bar: ui.Scrollbar, visible: bool) {
	if entry == nil || !app.settings.terminal.scrollbar {return}
	lines, ok := term.scrollbar(entry.session)
	if !ok {return}
	s := w.scale
	header := pane_header_height(s, app.settings.pane.show_headers)
	area := render.Rect{pane.rect.x, pane.rect.y + header, pane.rect.width - 2 * s,
		pane.rect.height - header - 4 * s}
	extent := ui.Scroll_Extent{int(lines.total), int(lines.len), int(lines.offset)}
	return ui.scrollbar_layout(area, extent, terminal_scrollbar_state(w, entry.id), s)
}

terminal_scrollbar_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry) {
	bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
	if visible {ui.scrollbar_draw(&w.list, app.theme, bar, terminal_scrollbar_state(w, entry.id))}
}

terminal_scrollbar_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if !e.pressed || e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	for pane in w.panes {
		entry := workspace_session_for_content(app, pane.content)
		bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if !visible || !ui.scrollbar_contains(bar, x, y) {continue}
		w.scroll_session = entry.id
		if delta := ui.scrollbar_press(&w.scroll_drag, bar, y) - bar.extent.offset; delta != 0 {
			term.scroll_viewport(entry.session, delta)
		}
		w.dirty = true
		return true
	}
	return false
}

terminal_scrollbar_move :: proc(app: ^App, w: ^Window, y: f32) {
	for pane in w.panes {
		entry := workspace_session_for_content(app, pane.content)
		if entry == nil || entry.id != w.scroll_session {continue}
		bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if !visible {return}
		term.scroll_viewport(entry.session, ui.scrollbar_drag(w.scroll_drag, bar, y) - bar.extent.offset)
		w.dirty = true
		return
	}
	w.scroll_drag = {}
}

// The session whose visible track holds the point, or 0.
terminal_scrollbar_at :: proc(app: ^App, w: ^Window, x, y: f32) -> u32 {
	for pane in w.panes {
		entry := workspace_session_for_content(app, pane.content)
		bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if visible && ui.scrollbar_contains(bar, x, y) {return entry.id}
	}
	return 0
}

// Records which pane's track is under the pointer, repainting only when that changes.
terminal_scrollbar_hover :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	hovered: u32
	if !w.selecting {hovered = terminal_scrollbar_at(app, w, x, y)}
	terminal_scrollbar_hover_set(w, hovered)
	return hovered != 0
}

terminal_scrollbar_hover_set :: proc(w: ^Window, id: u32) {
	if w.scroll_hover != id {w.scroll_hover, w.dirty = id, true}
}

terminal_scrollbar_release :: proc(app: ^App, w: ^Window, x, y: f32) {
	w.scroll_drag, w.dirty = {}, true
	terminal_scrollbar_hover(app, w, x, y)
}
