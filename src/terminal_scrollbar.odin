package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:ui"

// A held terminal scrollbar thumb: the session whose bar it is and where the pointer grabbed it. Nil is
// Idle. The procs in this file are the only writers.
Terminal_Scroll_Drag :: struct {
	session: u32,
	grab:    ui.Scroll_Drag,
}

terminal_scrollbar_dragging :: proc(w: ^Window) -> bool {
	return w.scroll_drag != nil
}

terminal_scrollbar_state :: proc(w: ^Window, id: u32) -> ui.Scrollbar_State {
	drag: ui.Scroll_Drag
	if held, ok := w.scroll_drag.?; ok && held.session == id {drag = held.grab}
	return ui.scrollbar_state(w.scroll_hover == id, drag)
}

terminal_scrollbar_geometry :: proc(
	app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry,
) -> (bar: ui.Scrollbar, visible: bool) {
	if entry == nil || !app.settings.terminal.scrollbar {return}
	lines, ok := term.scrollbar(entry.session)
	if !ok {return}
	s := w.scale
	header := pane_header_of(w, pane)
	area := render.Rect{pane.rect.x, pane.rect.y + header, pane.rect.width - 2 * s,
		pane.rect.height - header - 4 * s}
	extent := ui.Scroll_Extent{int(lines.total), int(lines.len), int(lines.offset)}
	return ui.scrollbar_layout(area, extent, terminal_scrollbar_state(w, entry.id), s)
}

terminal_scrollbar_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry) {
	bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
	if visible {ui.scrollbar_draw(&w.list, app.theme, bar, terminal_scrollbar_state(w, entry.id))}
}

terminal_scrollbar_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if !e.pressed || e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found {return false}
	entry := workspace_session_for_content(app, pane.content)
	bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
	if !visible || !ui.scrollbar_contains(bar, x, y) {return false}
	grab: ui.Scroll_Drag
	if delta := ui.scrollbar_press(&grab, bar, y) - bar.extent.offset; delta != 0 {
		term.scroll_viewport(entry.session, delta)
	}
	// A track press pages once; only a thumb press holds the bar.
	if grab.active {w.scroll_drag = Terminal_Scroll_Drag{entry.id, grab}} else {w.scroll_drag = nil}
	w.dirty = true
	return true
}

// The held thumb follows the pointer; a bar that is gone ends the drag.
terminal_scrollbar_move :: proc(app: ^App, w: ^Window, y: f32) {
	held, ok := w.scroll_drag.?
	if !ok {return}
	for pane in w.panes {
		entry := workspace_session_for_content(app, pane.content)
		if entry == nil || entry.id != held.session {continue}
		bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if !visible {return}
		term.scroll_viewport(entry.session, ui.scrollbar_drag(held.grab, bar, y) - bar.extent.offset)
		w.dirty = true
		return
	}
	terminal_scrollbar_cancel(w)
}

terminal_scrollbar_cancel :: proc(w: ^Window) {
	w.scroll_drag = nil
}

// The session whose visible track holds the point on the topmost pane there, or 0.
terminal_scrollbar_at :: proc(app: ^App, w: ^Window, x, y: f32) -> u32 {
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found {return 0}
	entry := workspace_session_for_content(app, pane.content)
	bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
	if visible && ui.scrollbar_contains(bar, x, y) {return entry.id}
	return 0
}

// Records which pane's track is under the pointer, repainting only when that changes.
terminal_scrollbar_hover :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	hovered: u32
	if !selection_active(w) {hovered = terminal_scrollbar_at(app, w, x, y)}
	terminal_scrollbar_hover_set(w, hovered)
	return hovered != 0
}

terminal_scrollbar_hover_set :: proc(w: ^Window, id: u32) {
	if w.scroll_hover != id {w.scroll_hover, w.dirty = id, true}
}

terminal_scrollbar_release :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	if w.scroll_drag == nil {return false}
	w.scroll_drag, w.dirty = nil, true
	terminal_scrollbar_hover(app, w, x, y)
	return true
}
