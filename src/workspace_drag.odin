package main

import "aio:render"
import "aio:ui"
import "core:math"

// A drag holds a workspace dropdown open through its Drop_Workspace_Dropdown destination (drag.odin). The
// dropdown keeps its own side as a drag move target, and workspace_drag_picker is where the two meet, so a
// dropdown closed under the drag by focus loss or another overlay counts as no longer held.

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

// The window whose dropdown the drag holds open, or nil.
workspace_drag_picker :: proc(app: ^App, d: Drop_Workspace_Dropdown) -> ^Window {
	w := window_find(app, d.window)
	if w == nil || !workspace_picker_held(&w.workspace_picker) {return nil}
	return w
}

// Closes the dropdown the drag held, when it is still open for it.
workspace_picker_drag_leave :: proc(app: ^App, d: Drop_Workspace_Dropdown) {
	if picker := workspace_drag_picker(app, d); picker != nil {workspace_picker_cancel(picker)}
}

// Opens w's dropdown while the pointer is over its chip and keeps it open over its rows, returning the hold
// and whether the drag is on it. `current` is the drag's destination now. The dropdown's last row, a new
// window, takes a drop only when the content may leave for one. Leaving the dropdown is the caller's next
// destination, which closes it.
@(require_results)
workspace_picker_drag_hover :: proc(
	app: ^App,
	current: Drag_Destination,
	w: ^Window,
	x, y: f32,
	request: Workspace_Move_Request,
	new_window_allowed: bool,
) -> (
	Drop_Workspace_Dropdown,
	bool,
) {
	p := &w.workspace_picker
	button := workspace_button_rect(w)
	on_button := render.rect_contains(button, x, y)
	panel, _ := workspace_picker_rect(w)
	previous, holding := current.(Drop_Workspace_Dropdown)
	held := holding && workspace_drag_picker(app, previous) == w
	// Keep the drag alive through the gap between the chip and its dropdown.
	in_panel := held && x >= panel.x && x < panel.x + panel.width &&
		y >= button.y && y < panel.y + panel.height
	if !on_button && !in_panel {return {}, false}
	if !held {
		if holding {workspace_picker_drag_leave(app, previous)}
		window_overlays_cancel(app, w)
		workspace_picker_transition(w, .List)
		workspace_picker_list_set(w, Workspace_Move_Target{request, true})
		ui.field_set(&p.query, "")
		workspace_picker_filter(app, w)
	}
	row := workspace_picker_hit(w, x, y)
	if row == len(p.rows) + 1 && !new_window_allowed {row = -1}
	p.selected = row
	return {window = w.id, pointer = {x, y}, row = row}, true
}

// Scrolls the dropdown the drag holds open, returning its window so the caller can track the rows that moved.
@(require_results)
workspace_picker_drag_scroll :: proc(app: ^App, d: Drop_Workspace_Dropdown, delta: f32) -> ^Window {
	w := workspace_drag_picker(app, d)
	if w == nil {return nil}
	_, visible := workspace_picker_rect(w)
	p := &w.workspace_picker
	p.scroll = clamp(p.scroll - int(math.sign(delta)), 0, max(0, workspace_picker_count(w) - visible))
	return w
}

// Reads the row under a drop and closes the dropdown the drag holds.
workspace_picker_drag_drop :: proc(app: ^App, d: Drop_Workspace_Dropdown) -> (drop: Workspace_Drag_Drop) {
	defer workspace_picker_drag_leave(app, d)
	w := workspace_drag_picker(app, d)
	if w == nil {return}
	p := &w.workspace_picker
	move, _ := workspace_picker_move(p)
	hit, count := d.row, len(p.rows)
	if hit >= 0 && hit <= count {return Workspace_Drop_Row{move.request, hit < count ? p.rows[hit].id : 0}}
	if hit == count + 1 {return Workspace_Drop_New_Window{}}
	return
}

// Scrolls a dropdown a drag holds and follows the rows under the still pointer; whether the wheel was the
// drag's.
drag_wheel :: proc(app: ^App, w: ^Window, delta: f32) -> bool {
	held, holding := drag_destination(w).(Drop_Workspace_Dropdown)
	if !holding {return false}
	picker := workspace_picker_drag_scroll(app, held, delta)
	if picker == nil {return false}
	x, y := held.pointer.x, held.pointer.y
	if pane_drag_active(w) {return pane_workspace_drag_move(app, w, picker, x, y, false)}
	return tab_workspace_drag_move(app, w, picker, x, y)
}
