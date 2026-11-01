package main

import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:ui"

// The track is the whole expansion zone: the thumb is thin until the pointer enters the width it
// would expand to, so it always grows under the pointer.
@(private = "file")
SCROLLBAR_TRACK :: 10
@(private = "file")
SCROLLBAR_THIN :: 4
@(private = "file")
SCROLLBAR_INSET :: 1

Scrollbar_State :: enum {
	Collapsed,
	Hovered,
	Active,
}

terminal_scrollbar_state :: proc(w: ^Window, id: u32) -> Scrollbar_State {
	if w.scroll_drag && w.scroll_session == id {return .Active}
	if w.scroll_hover == id {return .Hovered}
	return .Collapsed
}

terminal_scrollbar_geometry :: proc(
	app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry,
) -> (track, thumb: render.Rect, bar: term.Scrollbar, visible: bool) {
	if entry == nil || !app.settings.terminal.scrollbar {return}
	ok: bool
	bar, ok = term.scrollbar(entry.session)
	if !ok || bar.total <= bar.len {return}
	s := w.scale
	header := pane_header_height(s, app.settings.pane.show_headers)
	track = {pane.rect.x + pane.rect.width - (SCROLLBAR_TRACK + 2) * s, pane.rect.y + header,
		SCROLLBAR_TRACK * s, max(0, pane.rect.height - header - 4 * s)}
	if track.height <= 0 {return}
	height := min(track.height, max(24 * s, track.height * f32(bar.len) / f32(bar.total)))
	top := (track.height - height) * f32(bar.offset) / f32(bar.total - bar.len)
	width := f32(SCROLLBAR_THIN) * s
	if terminal_scrollbar_state(w, entry.id) != .Collapsed {width = track.width - 2 * SCROLLBAR_INSET * s}
	thumb = {track.x + track.width - SCROLLBAR_INSET * s - width, track.y + top, width, height}
	visible = true
	return
}

terminal_scrollbar_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry) {
	track, thumb, _, visible := terminal_scrollbar_geometry(app, w, pane, entry)
	if !visible {return}
	if render.push_layer(&w.list, track, 0) != .None {return}
	t := app.theme
	color := t.scrollbar
	switch terminal_scrollbar_state(w, entry.id) {
	case .Collapsed:
	case .Hovered:
		color = t.scrollbar_hover
		ui.draw_rect(&w.list, {rect = track, color = t.scrollbar_track, radius = track.width / 2})
	case .Active:
		color = t.scrollbar_active
		ui.draw_rect(&w.list, {rect = track, color = t.scrollbar_track, radius = track.width / 2})
	}
	ui.draw_rect(&w.list, {rect = thumb, color = color, radius = thumb.width / 2})
}

@(private = "file")
scrollbar_contains :: proc(r: render.Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height
}

terminal_scrollbar_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if !e.pressed || e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	for pane in w.panes {
		if pane.content.kind == .Settings {continue}
		entry := session_find(app, pane.content.id)
		track, thumb, bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if !visible || !scrollbar_contains(track, x, y) {continue}
		if y < thumb.y || y >= thumb.y + thumb.height {
			term.scroll_viewport(entry.session, y < thumb.y ? -int(bar.len) : int(bar.len))
		} else {
			w.scroll_drag, w.scroll_session, w.scroll_grab = true, entry.id, y - thumb.y
		}
		w.dirty = true
		return true
	}
	return false
}

terminal_scrollbar_move :: proc(app: ^App, w: ^Window, y: f32) {
	for pane in w.panes {
		if pane.content.kind == .Settings || pane.content.id != w.scroll_session {continue}
		entry := session_find(app, w.scroll_session)
		track, thumb, bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if !visible || track.height <= thumb.height {return}
		fraction := clamp((y - w.scroll_grab - track.y) / (track.height - thumb.height), 0, 1)
		target := int(fraction * f32(bar.total - bar.len) + 0.5)
		term.scroll_viewport(entry.session, target - int(bar.offset))
		w.dirty = true
		return
	}
	w.scroll_drag = false
}

// The session whose visible track holds the point, or 0.
terminal_scrollbar_at :: proc(app: ^App, w: ^Window, x, y: f32) -> u32 {
	for pane in w.panes {
		if pane.content.kind == .Settings {continue}
		entry := session_find(app, pane.content.id)
		track, _, _, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if visible && scrollbar_contains(track, x, y) {return entry.id}
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
	w.scroll_drag, w.dirty = false, true
	terminal_scrollbar_hover(app, w, x, y)
}
