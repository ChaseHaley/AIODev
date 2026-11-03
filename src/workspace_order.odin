package main

import "aio:platform"
import "aio:ui"
import "core:math"
import "core:time"

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
	grab, pointer_x, pointer_y: f32,
	active: bool,
	to: int,
}

Workspace_Order_Position :: struct {
	id: u32,
	position: ui.Motion,
	lifted: bool,
}

workspace_order_position :: proc(p: ^Workspace_Picker, id: u32) -> ^Workspace_Order_Position {
	for &entry in p.order_positions {if entry.id == id {return &entry}}
	return nil
}

workspace_order_reset :: proc(w: ^Window) {
	w.workspace_picker.order = {}
	clear(&w.workspace_picker.order_positions)
}

@(require_results)
workspace_order_begin :: proc(w: ^Window) -> bool {
	p := &w.workspace_picker
	for row in p.rows {
		if workspace_order_position(p, row.id) == nil {clear(&p.order_positions); break}
	}
	if len(p.order_positions) == 0 {
		if resize(&p.order_positions, len(p.rows)) != nil {return false}
		for row, i in p.rows {
			p.order_positions[i] = {id = row.id, position = {value = f32(i), target = f32(i)}}
		}
	}
	for &entry in p.order_positions {entry.lifted = entry.id == p.order.id}
	return true
}

workspace_order_move :: proc(w: ^Window, x, y: f32) {
	p := &w.workspace_picker
	d := &p.order
	d.pointer_x, d.pointer_y = x, y
	origin := workspace_picker_slot_rect(w, 0)
	top := clamp((y - origin.y) / origin.height - d.grab, 0, f32(len(p.rows) - 1))
	d.to = int(math.round(top))
	if entry := workspace_order_position(p, d.id); entry != nil {
		ui.motion_target(&entry.position, top, 0, .Linear, false, time.tick_now())
	}
}

workspace_order_animate :: proc(w: ^Window, enabled: bool, now: time.Tick) -> bool {
	p := &w.workspace_picker
	if len(p.order_positions) == 0 {return false}
	from := workspace_row_index(w, p.order.id)
	changed, moving := false, false
	for &entry in p.order_positions {
		index := workspace_row_index(w, entry.id)
		if index < 0 {continue}
		if !p.order.active || entry.id != p.order.id {
			target := index
			if p.order.active && from >= 0 {
				if from < p.order.to && index > from && index <= p.order.to {target -= 1}
				if p.order.to < from && index >= p.order.to && index < from {target += 1}
			}
			ui.motion_target(&entry.position, f32(target), 140 * time.Millisecond, .Decelerate, enabled, now)
		}
		changed = ui.motion_update(&entry.position, now) || changed
		moving ||= ui.motion_active(entry.position)
	}
	if !p.order.active && !moving {clear(&p.order_positions); changed = true}
	return changed
}

workspace_order_animating :: proc(p: ^Workspace_Picker) -> bool {
	for entry in p.order_positions {if ui.motion_active(entry.position) {return true}}
	return !p.order.active && len(p.order_positions) > 0
}

workspace_order_lifted :: proc(p: ^Workspace_Picker, index: int) -> bool {
	if index < 0 || index >= len(p.rows) {return false}
	entry := workspace_order_position(p, p.rows[index].id)
	return entry != nil && entry.lifted
}

workspace_order_hover :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) -> bool {
	p := &w.workspace_picker
	d := &p.order
	if d.id == 0 {return false}
	if .Left not_in e.buttons {p.order = {}; w.dirty = true; return false}
	x, y := f32(e.x), f32(e.y)
	if !d.active && (math.abs(x - d.start_x) >= DRAG_THRESHOLD * w.scale ||
	   math.abs(y - d.start_y) >= DRAG_THRESHOLD * w.scale) {
		if !workspace_order_begin(w) {
			workspace_order_reset(w)
			notify(app, .Error, "Could not reorder workspaces.")
			return true
		}
		d.active = true
	}
	if d.active {
		workspace_order_move(w, x, y)
		_ = workspace_order_animate(w, app.animations, time.tick_now())
	}
	w.dirty = true
	pointer_set(app, w, d.active ? .Resize_All : .Hand)
	return true
}

workspace_order_release :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	p := &w.workspace_picker
	if p.order.active {workspace_order_move(w, f32(e.x), f32(e.y))}
	d := p.order
	p.order = {}
	w.dirty = true
	if d.active {
		first := workspace_picker_slot_rect(w, p.scroll)
		last := workspace_picker_slot_rect(w, len(p.rows) - 1)
		r, rows := workspace_picker_rect(w)
		bottom := min(last.y + last.height, first.y + f32(rows) * first.height, r.y + r.height)
		if f32(e.x) >= first.x && f32(e.x) < first.x + first.width &&
		   f32(e.y) >= first.y && f32(e.y) < bottom && d.to >= 0 && d.to < len(p.rows) {
			_ = workspace_reorder(app, d.id, p.rows[d.to].id)
			workspace_row_reveal(w, d.id)
		}
		_ = workspace_order_animate(w, app.animations, time.tick_now())
	} else if hit := workspace_picker_hit(w, f32(e.x), f32(e.y)); hit >= 0 && hit < len(p.rows) &&
	          p.rows[hit].id == d.id {
		p.selected = hit
		workspace_picker_choose(app, w)
	}
}
