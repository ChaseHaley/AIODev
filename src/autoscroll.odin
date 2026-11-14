package main

import "aio:input"
import "aio:layout"
import "aio:render"
import "aio:term"
import "aio:ui"
import "core:math"
import "core:time"

// Middle-click scrolling, as Windows applications do it: a Middle press on a terminal, Markdown or
// settings pane drops an anchor, and the pane scrolls toward the pointer, faster the further the pointer
// is above or below it. Releasing the button without having left the dead zone keeps scrolling until
// the next press, key or wheel turn; releasing it after a drag past the dead zone ends it. A program that
// reports the mouse keeps its Middle presses. nil is off; the procs in this file are the only writers.
Autoscroll :: union {
	Autoscroll_On,
}

Autoscroll_On :: struct {
	// The pane content being scrolled, found again each frame so a pane that goes ends it.
	content:   layout.Content,
	anchor:    [2]f32,
	// The Middle button is still down from the press that dropped the anchor.
	held:      bool,
	// The pointer left the dead zone while the button was down, so its release ends scrolling.
	dragged:   bool,
	// The display time of the last frame that scrolled; zero while the pointer rests in the dead zone.
	last:      time.Tick,
	// Scrolling not yet applied: terminal rows, and Markdown pixels, move in whole steps.
	remainder: f32,
}

// The distance in DIP above or below the anchor within which nothing scrolls.
@(private = "file")
AUTOSCROLL_DEAD_ZONE :: f32(12)
// The anchor glyph's diameter in DIP.
@(private = "file")
AUTOSCROLL_ANCHOR :: f32(28)
// A longer gap between frames, as after a stall, scrolls only this much time's worth.
@(private = "file")
AUTOSCROLL_MAX_STEP :: 100 * time.Millisecond

// The surfaces whose Middle press drops the anchor: pane content of every kind.
@(private = "file")
AUTOSCROLL_TARGETS :: bit_set[Pointer_Target]{.Content, .Markdown_Page, .Settings_Page}

autoscroll_active :: proc(w: ^Window) -> bool {
	return w.autoscroll != nil
}

// The speed in DIP per second, positive toward the end of the page, for the pointer at `y`. Linear near
// the dead zone for fine control, then growing with the square of the distance to cross a long page.
@(private = "file")
autoscroll_speed :: proc(w: ^Window, on: Autoscroll_On, y: f32) -> f32 {
	offset := (y - on.anchor.y) / w.scale
	beyond := abs(offset) - AUTOSCROLL_DEAD_ZONE
	if beyond <= 0 {return 0}
	return math.sign(offset) * (6 * beyond + beyond * beyond / 25)
}

// A Middle press on pane content that can scroll drops the anchor; true when it did, and the press
// is spent. Another button already held, a selection drag or a drag of a pane or tab leaves the press
// to its surface.
@(private)
autoscroll_begin :: proc(app: ^App, w: ^Window, target: Pointer_Target, e: input.Mouse_Button_Event) -> bool {
	if e.button != .Middle || target not_in AUTOSCROLL_TARGETS {return false}
	for capture, button in w.gesture.captures {if button != .Middle && capture != nil {return false}}
	if selection_active(w) || drag_active(w) != nil || arrange_active(w) {return false}
	x, y := f32(e.x), f32(e.y)
	pane, found := layout.hit_test(w.panes[:], x, y)
	if !found || y < pane_body_rect(w, pane).y {return false}
	switch pane.content.kind {
	case .Terminal:
		entry := workspace_session_for_content(app, pane.content)
		if entry == nil || reports_mouse(entry, e.modifiers) {return false}
	case .Markdown:
		if markdown_find(app, pane.content.id) == nil {return false}
	case .Settings:
	}
	pane_focus(app, w, pane.node)
	tooltip_cancel(w)
	link_hover_clear(w)
	w.autoscroll = Autoscroll_On {
		content = pane.content,
		anchor  = {x, y},
		held    = true,
	}
	// Speed follows w.pointer, which only moves update; scrolling starts at rest.
	w.pointer = {x, y}
	pointer_set(app, w, .Resize_Vertical)
	w.dirty = true
	return true
}

// Scrolling stops and the pointer takes the shape of whatever it is over.
@(private)
autoscroll_end :: proc(app: ^App, w: ^Window) {
	if w.autoscroll == nil {return}
	autoscroll_stop(w)
	pointer_move(app, w, pointer_target(app, w, w.pointer.x, w.pointer.y), {
		window = w.id,
		x = i32(w.pointer.x),
		y = i32(w.pointer.y),
	})
}

// Scrolling stops, on capture loss too; a Middle button still down reaches nothing when released.
@(private)
autoscroll_stop :: proc(w: ^Window) {
	on, ok := w.autoscroll.(Autoscroll_On)
	if !ok {return}
	if on.held {gesture_cancel_button(w, .Middle)}
	w.autoscroll = nil
	w.dirty = true
}

// The release of the Middle press that dropped the anchor: after a drag past the dead zone it ends
// scrolling, otherwise scrolling goes on until the next press, key or wheel turn. False for a release
// of any other press.
@(private)
autoscroll_release :: proc(app: ^App, w: ^Window) -> bool {
	on, ok := &w.autoscroll.(Autoscroll_On)
	if !ok || !on.held {return false}
	on.held = false
	if on.dragged {autoscroll_end(app, w)}
	return true
}

// A move while scrolling sets the speed for the next frames; no surface sees it.
@(private)
autoscroll_move :: proc(app: ^App, w: ^Window, e: input.Mouse_Move_Event) -> bool {
	on, ok := &w.autoscroll.(Autoscroll_On)
	if !ok {return false}
	if on.held && autoscroll_speed(w, on^, f32(e.y)) != 0 {on.dragged = true}
	pointer_set(app, w, .Resize_Vertical)
	return true
}

// Keys end scrolling: Escape is spent on it, every other key except a lone modifier also goes on to
// its surface. True when the key was spent.
@(private)
autoscroll_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	if w.autoscroll == nil || !e.pressed || input.is_modifier_key(e.key) {return false}
	autoscroll_end(app, w)
	if e.key != .Escape {return false}
	key_suppress(w, e)
	return true
}

// Moves the pane by the time since the last frame at the pointer's speed; true while it moves.
@(private)
autoscroll_animate :: proc(app: ^App, w: ^Window, frame: ui.Frame_Time) -> bool {
	on, ok := &w.autoscroll.(Autoscroll_On)
	if !ok {return false}
	pane, shown := autoscroll_pane(w, on.content)
	if !shown {
		autoscroll_end(app, w)
		return false
	}
	speed := autoscroll_speed(w, on^, w.pointer.y)
	if speed == 0 {
		on.last, on.remainder = {}, 0
		return false
	}
	if on.last == {} {
		on.last = frame.display
		return true
	}
	elapsed := clamp(time.tick_diff(on.last, frame.display), 0, AUTOSCROLL_MAX_STEP)
	on.last = frame.display
	dip := speed * f32(time.duration_seconds(elapsed))
	switch pane.content.kind {
	case .Terminal:
		entry := workspace_session_for_content(app, pane.content)
		if entry == nil {
			autoscroll_end(app, w)
			return false
		}
		on.remainder += dip * w.scale / f32(max(1, term.geometry(entry.session).cell_height))
		rows := int(on.remainder)
		on.remainder -= f32(rows)
		term.scroll(entry.session, -rows, {}, on.anchor.x, on.anchor.y)
	case .Markdown:
		document := markdown_find(app, pane.content.id)
		if document == nil {
			autoscroll_end(app, w)
			return false
		}
		on.remainder += dip * w.scale
		pixels := int(on.remainder)
		on.remainder -= f32(pixels)
		markdown_scroll(w, document, pane, pixels)
	case .Settings:
		_ = settings_layout_for(w, pane)
		ui.editor_scroll_by(&w.editor, dip)
	}
	return true
}

// Whether the window draws a frame for scrolling: the pointer is outside the dead zone.
@(private)
autoscroll_moving :: proc(w: ^Window) -> bool {
	on, ok := w.autoscroll.(Autoscroll_On)
	return ok && autoscroll_speed(w, on, w.pointer.y) != 0
}

@(private = "file")
autoscroll_pane :: proc(w: ^Window, content: layout.Content) -> (layout.Pane_Rect, bool) {
	for pane in w.panes {
		if pane.content == content {return pane, true}
	}
	return {}, false
}

// The anchor: a round badge with the scroll mark, where the press was.
autoscroll_draw :: proc(app: ^App, w: ^Window) {
	on, ok := w.autoscroll.(Autoscroll_On)
	if !ok {return}
	if render.push_layer(&w.list, {0, 0, f32(w.width), f32(w.height)}) != .None {return}
	size := math.round(AUTOSCROLL_ANCHOR * w.scale)
	area := render.Rect{math.round(on.anchor.x - size / 2), math.round(on.anchor.y - size / 2), size, size}
	theme, edge := app.theme, max(1, math.round(w.scale))
	ui.draw_rect(&w.list, {rect = area, color = theme.surface, radius = size / 2})
	ui.draw_rect(&w.list, {rect = area, color = theme.border, radius = size / 2, stroke = edge})
	ui.icon_draw(&w.list, .Autoscroll, area, theme.text, ui.ICON_BUTTON, w.scale)
}
