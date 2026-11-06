package main

import "aio:platform"
import "aio:ui"
import "core:math"

// A drag holding a workspace dropdown open: the window showing it and the row under the pointer.
Workspace_Drag :: struct {
	picker_window:  platform.Window_Id,
	picker_pointer: [2]f32,
	picker_hit:     int,
}

workspace_drag_close :: proc(app: ^App, d: ^Workspace_Drag) {
	if picker := window_find(app, d.picker_window); picker != nil && picker.workspace_picker.drag {
		workspace_picker_cancel(picker)
	}
	d.picker_window = 0
}

// Opens w's dropdown while the pointer is over its chip and keeps it open over its rows, returning whether
// the drag is on it. Its last row, a new window, takes a drop only when the content may leave for one.
@(require_results)
workspace_drag_hover :: proc(
	app: ^App,
	d: ^Workspace_Drag,
	w: ^Window,
	x, y: f32,
	request: Workspace_Move_Request,
	new_window_allowed: bool,
) -> bool {
	p := &w.workspace_picker
	button := workspace_button_rect(w)
	on_button := workspace_rect_contains(button, x, y)
	panel, _ := workspace_picker_rect(w)
	// Keep the drag alive through the gap between the chip and its dropdown.
	in_panel := d.picker_window == w.id && p.drag && x >= panel.x && x < panel.x + panel.width &&
		y >= button.y && y < panel.y + panel.height
	if !on_button && !in_panel {
		workspace_drag_close(app, d)
		return false
	}
	if d.picker_window != w.id || !p.drag {
		workspace_drag_close(app, d)
		window_overlays_cancel(app, w)
		workspace_picker_transition(w, .List)
		p.move = request
		p.drag = true
		ui.field_set(&p.query, "")
		workspace_picker_filter(app, w)
		d.picker_window = w.id
	}
	d.picker_pointer = {x, y}
	d.picker_hit = workspace_picker_hit(w, x, y)
	if d.picker_hit == len(p.rows) + 1 && !new_window_allowed {d.picker_hit = -1}
	p.selected = d.picker_hit
	return true
}

// Scrolls the dropdown a drag holds open, returning its window so the caller can track the rows that moved.
@(require_results)
workspace_drag_scroll :: proc(app: ^App, d: ^Workspace_Drag, delta: f32) -> ^Window {
	w := window_find(app, d.picker_window)
	if w == nil || !w.workspace_picker.drag {return nil}
	_, visible := workspace_picker_rect(w)
	p := &w.workspace_picker
	p.scroll = clamp(p.scroll - int(math.sign(delta)), 0, max(0, workspace_picker_count(w) - visible))
	return w
}
