package main

import "aio:platform"
import "aio:ui"
import "core:math"

// A drag holding a workspace dropdown open: the window showing it and the row under the pointer. The dropdown
// keeps its own side as a drag move target, and workspace_drag_picker is where the two meet, so a dropdown
// closed under the drag by focus loss or another overlay counts as no longer held.
Workspace_Drag :: struct {
	picker_window:  platform.Window_Id,
	picker_pointer: [2]f32,
	picker_hit:     int,
}

// What a drop on a held dropdown chooses. Nil, a drop between rows or on a dropdown no longer held, puts the
// content back.
Workspace_Drag_Drop :: union {
	Workspace_Drop_Row,
	Workspace_Drop_New_Window,
}

// A workspace row; id 0 is the new workspace row.
Workspace_Drop_Row :: struct {
	request: Workspace_Move_Request,
	id:      u32,
}

Workspace_Drop_New_Window :: struct {}

// The window whose dropdown d holds open, or nil.
workspace_drag_picker :: proc(app: ^App, d: ^Workspace_Drag) -> ^Window {
	w := window_find(app, d.picker_window)
	if w == nil || !workspace_picker_held(&w.workspace_picker) {return nil}
	return w
}

workspace_picker_drag_leave :: proc(app: ^App, d: ^Workspace_Drag) {
	if picker := workspace_drag_picker(app, d); picker != nil {workspace_picker_cancel(picker)}
	d.picker_window = 0
}

// Opens w's dropdown while the pointer is over its chip and keeps it open over its rows, returning whether
// the drag is on it. Its last row, a new window, takes a drop only when the content may leave for one.
@(require_results)
workspace_picker_drag_hover :: proc(
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
	held := workspace_drag_picker(app, d) == w
	// Keep the drag alive through the gap between the chip and its dropdown.
	in_panel := held && x >= panel.x && x < panel.x + panel.width &&
		y >= button.y && y < panel.y + panel.height
	if !on_button && !in_panel {
		workspace_picker_drag_leave(app, d)
		return false
	}
	if !held {
		workspace_picker_drag_leave(app, d)
		window_overlays_cancel(app, w)
		workspace_picker_transition(w, .List)
		workspace_picker_list_set(w, Workspace_Move_Target{request, true})
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
workspace_picker_drag_scroll :: proc(app: ^App, d: ^Workspace_Drag, delta: f32) -> ^Window {
	w := workspace_drag_picker(app, d)
	if w == nil {return nil}
	_, visible := workspace_picker_rect(w)
	p := &w.workspace_picker
	p.scroll = clamp(p.scroll - int(math.sign(delta)), 0, max(0, workspace_picker_count(w) - visible))
	return w
}

// Reads the row under a drop and closes the dropdown d holds.
workspace_picker_drag_drop :: proc(app: ^App, d: ^Workspace_Drag) -> (drop: Workspace_Drag_Drop) {
	defer workspace_picker_drag_leave(app, d)
	w := workspace_drag_picker(app, d)
	if w == nil {return}
	p := &w.workspace_picker
	move, _ := workspace_picker_move(p)
	hit, count := d.picker_hit, len(p.rows)
	if hit >= 0 && hit <= count {return Workspace_Drop_Row{move.request, hit < count ? p.rows[hit].id : 0}}
	if hit == count + 1 {return Workspace_Drop_New_Window{}}
	return
}
