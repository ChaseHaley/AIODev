package ui

import "aio:render"

// The one scrollbar every scrolling surface shows: terminal panes, the command palette and dropdown
// lists. The track is the whole expansion zone: the thumb is thin until the pointer enters the width
// it would expand to, so it always grows under the pointer.
@(private)
SCROLLBAR_TRACK :: 10
@(private = "file")
SCROLLBAR_THIN :: 4
@(private = "file")
SCROLLBAR_INSET :: 1
@(private = "file")
SCROLLBAR_MIN_THUMB :: 24

// How much there is to scroll, in whatever unit the surface scrolls by.
Scroll_Extent :: struct {
	total, visible, offset: int,
}

Scrollbar_State :: enum {
	Collapsed,
	Hovered,
	Active,
}

// A drag on the thumb. `grab` is where the pointer holds it, measured down from the thumb's top.
Scroll_Drag :: struct {
	active: bool,
	grab:   f32,
}

Scrollbar :: struct {
	track, thumb: render.Rect,
	extent:       Scroll_Extent,
}

scrollbar_state :: proc(hovered: bool, drag: Scroll_Drag) -> Scrollbar_State {
	if drag.active {return .Active}
	return hovered ? .Hovered : .Collapsed
}

// Places the track along the right edge of `area`; nothing is shown when the content fits.
scrollbar_layout :: proc(
	area: render.Rect, extent: Scroll_Extent, state: Scrollbar_State, scale: f32,
) -> (bar: Scrollbar, visible: bool) {
	if extent.visible <= 0 || extent.total <= extent.visible || area.height <= 0 || area.width <= 0 {return}
	width := min(SCROLLBAR_TRACK * scale, area.width)
	track := render.Rect{area.x + area.width - width, area.y, width, area.height}
	range := extent.total - extent.visible
	share := track.height * f32(extent.visible) / f32(extent.total)
	height := min(track.height, max(SCROLLBAR_MIN_THUMB * scale, share))
	top := (track.height - height) * f32(clamp(extent.offset, 0, range)) / f32(range)
	thumb_width := min(SCROLLBAR_THIN * scale, track.width)
	if state != .Collapsed {thumb_width = max(0, track.width - 2 * SCROLLBAR_INSET * scale)}
	inset := min(SCROLLBAR_INSET * scale, track.width - thumb_width)
	thumb := render.Rect{track.x + track.width - inset - thumb_width, track.y + top, thumb_width, height}
	return {track, thumb, extent}, true
}

scrollbar_contains :: proc(bar: Scrollbar, x, y: f32) -> bool {return render.rect_contains(bar.track, x, y)}

// A press on the track pages toward the pointer, or on the thumb starts a drag. Returns the offset
// the surface scrolls to.
scrollbar_press :: proc(drag: ^Scroll_Drag, bar: Scrollbar, y: f32) -> int {
	e := bar.extent
	range := max(0, e.total - e.visible)
	switch {
	case y < bar.thumb.y:
		return clamp(e.offset - e.visible, 0, range)
	case y >= bar.thumb.y + bar.thumb.height:
		return clamp(e.offset + e.visible, 0, range)
	}
	drag^ = {active = true, grab = y - bar.thumb.y}
	return e.offset
}

scrollbar_drag :: proc(drag: Scroll_Drag, bar: Scrollbar, y: f32) -> int {
	e := bar.extent
	room := bar.track.height - bar.thumb.height
	if room <= 0 {return e.offset}
	fraction := clamp((y - drag.grab - bar.track.y) / room, 0, 1)
	return int(fraction * f32(e.total - e.visible) + 0.5)
}

// Draws clipped to the track; the caller's layer is current again afterwards.
scrollbar_draw :: proc(list: ^render.Draw_List, theme: Theme, bar: Scrollbar, state: Scrollbar_State) {
	scope, opened := clip_scope_open(list, bar.track)
	if !opened {return}
	defer clip_scope_close(list, scope)
	color := theme.scrollbar
	if state != .Collapsed {
		color = state == .Active ? theme.scrollbar_active : theme.scrollbar_hover
		draw_rect(list, {rect = bar.track, color = theme.scrollbar_track, radius = bar.track.width / 2})
	}
	draw_rect(list, {rect = bar.thumb, color = color, radius = bar.thumb.width / 2})
}
