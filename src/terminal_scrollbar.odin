package main

import "aio:layout"
import "aio:platform"
import "aio:render"
import "aio:term"
import "aio:ui"

terminal_scrollbar_geometry :: proc(
	app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry,
) -> (track, thumb: render.Rect, bar: term.Scrollbar, visible: bool) {
	if entry == nil {return}
	ok: bool
	bar, ok = term.scrollbar(entry.session)
	if !ok || bar.total <= bar.len {return}
	header := pane_header_height(w.scale, app.settings.pane.show_headers)
	track = {pane.rect.x + pane.rect.width - 12 * w.scale, pane.rect.y + header,
		10 * w.scale, max(0, pane.rect.height - header - 4 * w.scale)}
	if track.height <= 0 {return}
	height := min(track.height, max(24 * w.scale, track.height * f32(bar.len) / f32(bar.total)))
	top := (track.height - height) * f32(bar.offset) / f32(bar.total - bar.len)
	thumb = {track.x + 2 * w.scale, track.y + top, 6 * w.scale, height}
	visible = true
	return
}

terminal_scrollbar_draw :: proc(app: ^App, w: ^Window, pane: layout.Pane_Rect, entry: ^Session_Entry) {
	track, thumb, _, visible := terminal_scrollbar_geometry(app, w, pane, entry)
	if !visible {return}
	if render.push_layer(&w.list, track, 0) != .None {return}
	ui.draw_rect(&w.list, {rect = thumb, color = app.theme.muted, radius = 3 * w.scale})
}

terminal_scrollbar_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if !e.pressed || e.button != .Left {return false}
	x, y := f32(e.x), f32(e.y)
	for pane in w.panes {
		if pane.content.kind == .Settings {continue}
		entry := session_find(app, pane.content.id)
		track, thumb, bar, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if !visible || x < track.x || x >= track.x + track.width ||
		   y < track.y || y >= track.y + track.height {continue}
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

terminal_scrollbar_hover :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	for pane in w.panes {
		if pane.content.kind == .Settings {continue}
		entry := session_find(app, pane.content.id)
		track, _, _, visible := terminal_scrollbar_geometry(app, w, pane, entry)
		if visible && x >= track.x && x < track.x + track.width &&
		   y >= track.y && y < track.y + track.height {return true}
	}
	return false
}