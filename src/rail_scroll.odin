package main

import "aio:render"
import "aio:ui"
import "core:math"
import "core:time"

// How the rail's rows scroll (WORK-468): the wheel and the scrollbar's track glide the scroll, its thumb
// moves it with the pointer, and tabs dragged near the top or bottom of the rows scroll it that way. The
// dragged tabs keep their place under the pointer through every scroll, without waiting for it to move.

@(private = "file")
RAIL_GLIDE :: 160 * time.Millisecond
// How fast tabs dragged at the rows' very edge scroll them, in DIPs a second; slower further in.
@(private = "file")
RAIL_EDGE_SPEED :: f32(480)

// Sets the rail's scroll at once, ending any glide.
rail_scroll_set :: proc(w: ^Window, scroll: f32) {
	w.rail_scroll = scroll
	w.rail_glide = {value = scroll, target = scroll}
	w.dirty = true
}

// Glides the rail's scroll to `target`, from where it shows now; at once without animations.
rail_scroll_glide :: proc(app: ^App, w: ^Window, target: f32) {
	glide := &w.rail_glide
	if !ui.motion_active(glide^) {glide^ = {value = w.rail_scroll, target = w.rail_scroll}}
	ui.motion_target(glide, target, RAIL_GLIDE, .Decelerate, app.animations)
	w.dirty = true
	if ui.motion_active(glide^) {return}
	w.rail_scroll = glide.value
	rail_drag_follow(app, w)
}

// The wheel glides the rail three rows a notch, on from where an unfinished glide was going.
rail_wheel :: proc(app: ^App, w: ^Window, delta: f32) {
	layout, ok := rail_current_layout(w)
	if !ok {return}
	from := ui.motion_active(w.rail_glide) ? w.rail_glide.target : w.rail_scroll
	step := f32(math.sign(delta)) * 3 * layout.row_height
	rail_scroll_glide(app, w, ui.rail_scroll_clamped(layout, from - step))
}

// Tabs dragged in the rail follow the scroll under the still pointer.
@(private = "file")
rail_drag_follow :: proc(app: ^App, w: ^Window) {
	if w.tabs_horizontal || !tab_drag_active(w) {return}
	_ = tab_drag_move_rail(app, w, w.pointer.x, w.pointer.y)
}

// How fast a tab drag scrolls the rail, in pixels a second, negative upward: while the pointer is within a
// row of the top or bottom of the rows, or past them, faster the nearer the edge; zero once the rows can
// scroll no further that way.
rail_drag_edge_speed :: proc(w: ^Window) -> f32 {
	if w.tabs_horizontal || !tab_drag_active(w) {return 0}
	_, carry := tab_drag_state(w)
	if _, reorder := carry.destination.(Drop_Reorder); !reorder {return 0}
	layout, ok := rail_layout_query(w)
	if !ok || layout.row_height <= 0 {return 0}
	zone, list, y := layout.row_height, layout.list, w.pointer.y
	depth: f32
	switch {
	case y < list.y + zone:
		if layout.scroll <= 0 {return 0}
		depth = -min(1, (list.y + zone - y) / zone)
	case y > list.y + list.height - zone:
		if layout.scroll >= ui.rail_scroll_max(layout) {return 0}
		depth = min(1, (y - (list.y + list.height - zone)) / zone)
	}
	return depth * RAIL_EDGE_SPEED * w.scale
}

// Advances the rail's glide and a drag's edge scrolling for `frame`; true when the rail moved.
rail_scroll_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	moved := false
	if ui.motion_update(&w.rail_glide, frame) {
		w.rail_scroll = w.rail_glide.value
		moved = true
	}
	if speed := rail_drag_edge_speed(w); speed != 0 {
		if layout, ok := rail_layout_query(w); ok {
			step := speed * f32(time.duration_seconds(frame.period))
			next := ui.rail_scroll_clamped(layout, w.rail_scroll + step)
			if next != w.rail_scroll {
				rail_scroll_set(w, next)
				moved = true
			}
		}
	}
	if !moved {return false}
	w.dirty = true
	rail_drag_follow(app, w)
	return true
}

rail_scroll_animating :: proc(w: ^Window) -> bool {
	return ui.motion_active(w.rail_glide) || rail_drag_edge_speed(w) != 0
}

// The rail's scrollbar along the right of the rows `layout` places, while they overflow.
rail_scrollbar_place :: proc(w: ^Window, layout: ui.Rail_Layout) -> (bar: ui.Scrollbar, visible: bool) {
	list := layout.list
	area := render.Rect{list.x, list.y, list.width - 2 * w.scale, list.height}
	extent := ui.Scroll_Extent {
		total   = int(math.round(layout.content_height)),
		visible = int(math.round(list.height)),
		offset  = int(math.round(layout.scroll)),
	}
	return ui.scrollbar_layout(area, extent, rail_scrollbar_state(w), w.scale)
}

// The rail's scrollbar where it shows now, when it shows.
rail_scrollbar :: proc(w: ^Window) -> (bar: ui.Scrollbar, visible: bool) {
	if !rail_visible(w) {return}
	layout, ok := rail_layout_query(w)
	if !ok {return}
	return rail_scrollbar_place(w, layout)
}

rail_scrollbar_state :: proc(w: ^Window) -> ui.Scrollbar_State {
	return ui.scrollbar_state(w.rail_bar_hover, w.rail_bar_drag)
}

// A Left press on the rail's scrollbar: the track glides a page toward the pointer and the thumb holds the
// bar. False when the point is not on the bar.
rail_scrollbar_press :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	bar, visible := rail_scrollbar(w)
	if !visible || !ui.scrollbar_contains(bar, x, y) {return false}
	offset := ui.scrollbar_press(&w.rail_bar_drag, bar, y)
	if !w.rail_bar_drag.active {rail_scroll_glide(app, w, f32(offset))}
	w.dirty = true
	return true
}

// The held thumb follows the pointer; false when no thumb is held.
rail_scrollbar_move :: proc(w: ^Window, y: f32) -> bool {
	if !w.rail_bar_drag.active {return false}
	bar, visible := rail_scrollbar(w)
	if visible {rail_scroll_set(w, f32(ui.scrollbar_drag(w.rail_bar_drag, bar, y)))}
	return true
}

// Lets go of the held thumb; false when none was held.
rail_scrollbar_release :: proc(w: ^Window) -> bool {
	if !w.rail_bar_drag.active {return false}
	w.rail_bar_drag = {}
	w.dirty = true
	return true
}

// Records whether the pointer is over the rail's scrollbar, repainting when that changes.
rail_scrollbar_hover :: proc(w: ^Window, x, y: f32) -> bool {
	bar, visible := rail_scrollbar(w)
	over := visible && ui.scrollbar_contains(bar, x, y)
	if over != w.rail_bar_hover {w.rail_bar_hover, w.dirty = over, true}
	return over
}
