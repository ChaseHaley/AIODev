package ui

import "aio:render"
import "core:time"

// The one scrollbar every scrolling surface shows: terminal panes, the everything palette,
// dropdown lists and the theme filmstrip. The track is the whole expansion zone: the thumb is thin
// until the pointer enters the width it would expand to, so it always grows under the pointer.
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

// A vertical bar runs down the right edge of its area; a horizontal one along the bottom edge.
Scrollbar :: struct {
	track, thumb: render.Rect,
	extent:       Scroll_Extent,
	horizontal:   bool,
}

scrollbar_state :: proc(hovered: bool, drag: Scroll_Drag) -> Scrollbar_State {
	if drag.active {return .Active}
	return hovered ? .Hovered : .Collapsed
}

// Places the track along the right edge of `area`; nothing is shown when the content fits.
scrollbar_layout :: proc(
	area: render.Rect, extent: Scroll_Extent, state: Scrollbar_State, scale: f32,
) -> (bar: Scrollbar, visible: bool) {
	return scrollbar_place(area, extent, state, scale, false)
}

// Places the track along the bottom edge of `area`, for a surface that scrolls sideways.
scrollbar_layout_horizontal :: proc(
	area: render.Rect, extent: Scroll_Extent, state: Scrollbar_State, scale: f32,
) -> (bar: Scrollbar, visible: bool) {
	return scrollbar_place(area, extent, state, scale, true)
}

// Lays the bar out along its axis: `length` runs with the scroll, `breadth` across it.
@(private = "file")
scrollbar_place :: proc(
	area: render.Rect, extent: Scroll_Extent, state: Scrollbar_State, scale: f32, horizontal: bool,
) -> (bar: Scrollbar, visible: bool) {
	if extent.visible <= 0 || extent.total <= extent.visible || area.height <= 0 || area.width <= 0 {return}
	length, breadth := area.height, area.width
	if horizontal {length, breadth = area.width, area.height}
	width := min(SCROLLBAR_TRACK * scale, breadth)
	range := extent.total - extent.visible
	share := length * f32(extent.visible) / f32(extent.total)
	size := min(length, max(SCROLLBAR_MIN_THUMB * scale, share))
	start := (length - size) * f32(clamp(extent.offset, 0, range)) / f32(range)
	thumb_width := min(SCROLLBAR_THIN * scale, width)
	if state != .Collapsed {thumb_width = max(0, width - 2 * SCROLLBAR_INSET * scale)}
	inset := min(SCROLLBAR_INSET * scale, width - thumb_width)
	if horizontal {
		track := render.Rect{area.x, area.y + area.height - width, area.width, width}
		thumb := render.Rect{track.x + start, track.y + width - inset - thumb_width, size, thumb_width}
		return {track, thumb, extent, true}, true
	}
	track := render.Rect{area.x + area.width - width, area.y, width, area.height}
	thumb := render.Rect{track.x + width - inset - thumb_width, track.y + start, thumb_width, size}
	return {track, thumb, extent, false}, true
}

// Where `r` starts along the bar's axis, and how long it is.
@(private = "file")
scrollbar_span :: proc(bar: Scrollbar, r: render.Rect) -> (start, length: f32) {
	return bar.horizontal ? r.x : r.y, bar.horizontal ? r.width : r.height
}

scrollbar_contains :: proc(bar: Scrollbar, x, y: f32) -> bool {return render.rect_contains(bar.track, x, y)}

// Where one page toward `at` lands: `at` is the pointer's coordinate along the bar, y for a vertical bar
// and x for a horizontal one. A point on the thumb stays where the view is, and reports it.
@(private = "file")
scrollbar_toward :: proc(bar: Scrollbar, at: f32) -> (offset: int, on_thumb: bool) {
	e := bar.extent
	range := max(0, e.total - e.visible)
	start, length := scrollbar_span(bar, bar.thumb)
	switch {
	case at < start:
		return clamp(e.offset - e.visible, 0, range), false
	case at >= start + length:
		return clamp(e.offset + e.visible, 0, range), false
	}
	return e.offset, true
}

// A press on the track pages toward the pointer, or on the thumb starts a drag. `at` is the
// pointer's coordinate along the bar: y for a vertical bar, x for a horizontal one. Returns the
// offset the surface scrolls to.
scrollbar_press :: proc(drag: ^Scroll_Drag, bar: Scrollbar, at: f32) -> int {
	offset, on_thumb := scrollbar_toward(bar, at)
	if on_thumb {
		start, _ := scrollbar_span(bar, bar.thumb)
		drag^ = {active = true, grab = at - start}
	}
	return offset
}

// What a page toward the pointer found.
Scroll_Page :: enum u8 {
	// The pointer is off the track or on the other side of the thumb from where the press began: a held
	// press pauses, as Windows does.
	Off_Track,
	// The thumb is under the pointer: the view has met it.
	On_Thumb,
	// The view cannot go further toward the pointer.
	Stuck,
	// The view pages toward the pointer; `offset` is where it goes.
	Paged,
}

// The held track press, as Windows repeats it: the first page comes with the press, the next after
// SCROLLBAR_REPEAT_DELAY and then one every SCROLLBAR_REPEAT_INTERVAL for as long as the button stays
// down, each paging toward wherever the pointer is then, until the thumb reaches it. Wine's
// dlls/win32u/scroll.c (SCROLL_FIRST_DELAY 200, SCROLL_REPEAT_DELAY 50) and ReactOS's scrollbar.c use
// these values; Windows reads no system setting for them.
SCROLLBAR_REPEAT_DELAY :: 200 * time.Millisecond
SCROLLBAR_REPEAT_INTERVAL :: 50 * time.Millisecond

// Which side of the thumb a track press landed on: the held press keeps paging only from that side, as a
// native Windows scrollbar does (Wine's win32u/scroll.c fixes `hit_test` at the press and stops the timer
// whenever the pointer's region differs from it, thumb included, restarting it on return).
Scroll_Side :: enum u8 {
	// On the thumb, or off the bar.
	None,
	// Before the thumb: above it, or left of it.
	Before,
	// After the thumb.
	After,
}

// The side of the thumb the point `at` along the bar is on.
scrollbar_side :: proc(bar: Scrollbar, at: f32) -> Scroll_Side {
	start, length := scrollbar_span(bar, bar.thumb)
	switch {
	case at < start:
		return .Before
	case at >= start + length:
		return .After
	}
	return .None
}

// One page toward the pointer at (x, y), the step a held track press repeats. `side` is where the press
// began. Nothing moves while the pointer is off the track or on the other side of the thumb (Off_Track: the
// press pauses and resumes when the pointer is back on its side), or on the thumb.
scrollbar_page :: proc(
	bar: Scrollbar,
	x, y: f32,
	side: Scroll_Side,
) -> (
	offset: int,
	result: Scroll_Page,
) {
	offset = bar.extent.offset
	if !scrollbar_contains(bar, x, y) {return offset, .Off_Track}
	at := bar.horizontal ? x : y
	switch scrollbar_side(bar, at) {
	case .None:
		return offset, .On_Thumb
	case .Before, .After:
		if scrollbar_side(bar, at) != side {return offset, .Off_Track}
	}
	toward, _ := scrollbar_toward(bar, at)
	if toward == offset {return offset, .Stuck}
	return toward, .Paged
}

scrollbar_drag :: proc(drag: Scroll_Drag, bar: Scrollbar, at: f32) -> int {
	e := bar.extent
	track, track_length := scrollbar_span(bar, bar.track)
	_, thumb_length := scrollbar_span(bar, bar.thumb)
	room := track_length - thumb_length
	if room <= 0 {return e.offset}
	fraction := clamp((at - drag.grab - track) / room, 0, 1)
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
		draw_rect(list, {rect = bar.track, color = theme.scrollbar_track, radius = pill_radius(bar.track)})
	}
	draw_rect(list, {rect = bar.thumb, color = color, radius = pill_radius(bar.thumb)})
}
