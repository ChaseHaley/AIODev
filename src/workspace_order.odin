package main

import "aio:platform"
import "core:math"

@(require_results)
workspace_reorder :: proc(app: ^App, id, target_id: u32) -> bool {
	if id == target_id || workspace_row_target(app, id) == nil ||
	   workspace_row_target(app, target_id) == nil {return false}
	from, to := -1, -1
	for workspace, i in app.workspaces {
		if workspace.id == id {from = i}
		if workspace.id == target_id {to = i}
	}
	workspace := app.workspaces[from]
	if from < to {
		for i in from..<to {app.workspaces[i] = app.workspaces[i + 1]}
	} else {
		for i := from; i > to; i -= 1 {app.workspaces[i] = app.workspaces[i - 1]}
	}
	app.workspaces[to] = workspace
	workspace_pickers_refresh(app)
	layout_state_touch(app)
	mark_all_dirty(app)
	return true
}

workspace_order_neighbor :: proc(app: ^App, id: u32, step: int) -> u32 {
	previous: u32
	found := false
	for workspace in app.workspaces {
		if !workspace_eligible(app, workspace) {continue}
		if found {return workspace.id}
		if workspace.id == id {
			if step < 0 {return previous}
			found = true
		}
		previous = workspace.id
	}
	return 0
}

Workspace_Order_Drag :: struct {
	id: u32,
	start_x, start_y: f32,
	active: bool,
	target: u32,
}

workspace_order_hover :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) -> bool {
	p := &w.workspace_picker
	d := &p.order
	if d.id == 0 {return false}
	if .Left not_in e.buttons {p.order = {}; w.dirty = true; return false}
	x, y := f32(e.x), f32(e.y)
	if math.abs(x - d.start_x) >= 4 * w.scale || math.abs(y - d.start_y) >= 4 * w.scale {
		d.active = true
	}
	d.target = 0
	if d.active {
		if hit := workspace_picker_hit(w, x, y); hit >= 0 && hit < len(p.rows) {
			d.target = p.rows[hit].id
		}
	}
	w.dirty = true
	pointer_set(app, w, d.active ? .Resize_All : .Hand)
	return true
}

workspace_order_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	p := &w.workspace_picker
	d := p.order
	p.order = {}
	w.dirty = true
	if d.active {
		hit := workspace_picker_hit(w, f32(e.x), f32(e.y))
		if hit >= 0 && hit < len(p.rows) {
			_ = workspace_reorder(app, d.id, p.rows[hit].id)
			workspace_row_reveal(w, d.id)
		}
	} else if hit := workspace_picker_hit(w, f32(e.x), f32(e.y)); hit >= 0 && hit < len(p.rows) &&
	          p.rows[hit].id == d.id {
		p.selected = hit
		workspace_picker_choose(app, w)
	}
}
