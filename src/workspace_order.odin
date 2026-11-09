package main

import "aio:input"
import "aio:ui"
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
	workspace_mutation_finish(app, workspace, {.Order})
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

// A press on a row, which lifts it once the pointer passes the drag threshold.
Workspace_Order_Pressed :: struct {
	id: u32,
	start_x, start_y, grab: f32,
}

// A lifted row follows the pointer; to is the slot a drop moves it into.
Workspace_Order_Lifted :: struct {
	id: u32,
	grab, pointer_x, pointer_y: f32,
	to: int,
}

// The settle after a lifted row is let go: for 140 ms, as tab reorder does (D-069), the rows ease into
// their listed slots with the row that was lifted drawn on top. It is its own value rather than a state of
// Workspace_Picker_State because it must outlive the List it starts in: the row menu and rename open over
// a settling row, and a new press can start before it ends. workspace_picker_state_set starts it when a
// lift ends; workspace_order_begin, workspace_order_stop and workspace_order_animate end it.
Workspace_Order_Settle :: struct {
	id: u32,
}

// A row's eased position in slots. The rows have positions while one is lifted and while they settle.
Workspace_Order_Position :: struct {
	id: u32,
	position: ui.Motion,
}

// Ends any settle with the rows standing where they are listed.
workspace_order_stop :: proc(p: ^Workspace_Picker) {
	p.order_settle = nil
	clear(&p.order_positions)
}

workspace_order_position :: proc(p: ^Workspace_Picker, id: u32) -> ^Workspace_Order_Position {
	for &entry in p.order_positions {if entry.id == id {return &entry}}
	return nil
}

workspace_order_pressed :: proc(p: ^Workspace_Picker) -> ^Workspace_Order_Pressed {
	list, listing := &p.state.(Workspace_Picker_List)
	if !listing {return nil}
	pressed, _ := &list.sub.(Workspace_Order_Pressed)
	return pressed
}

workspace_order_lift :: proc(p: ^Workspace_Picker) -> ^Workspace_Order_Lifted {
	list, listing := &p.state.(Workspace_Picker_List)
	if !listing {return nil}
	lift, _ := &list.sub.(Workspace_Order_Lifted)
	return lift
}

// The row pressed or lifted, or 0.
workspace_order_grabbed :: proc(p: ^Workspace_Picker) -> u32 {
	if pressed := workspace_order_pressed(p); pressed != nil {return pressed.id}
	if lift := workspace_order_lift(p); lift != nil {return lift.id}
	return 0
}

workspace_order_settling :: proc(p: ^Workspace_Picker) -> bool {
	_, settling := p.order_settle.?
	return settling
}

// Ends a press or a lift, keeping the list's other states. A lifted row settles back into place.
workspace_order_end :: proc(w: ^Window) {
	if workspace_order_grabbed(&w.workspace_picker) != 0 {workspace_picker_list_set(w, nil)}
}

// Ends a press or a lift with no settle, so the rows stand where they are listed.
workspace_order_reset :: proc(w: ^Window) {
	workspace_order_end(w)
	workspace_order_stop(&w.workspace_picker)
}

// Gives each row a position for a lift, keeping those of a settle so its rows carry on from where they
// are. The lifted row takes the top from the row settling.
@(require_results)
workspace_order_begin :: proc(w: ^Window) -> bool {
	p := &w.workspace_picker
	p.order_settle = nil
	for row in p.rows {
		if workspace_order_position(p, row.id) == nil {clear(&p.order_positions); break}
	}
	if len(p.order_positions) == 0 {
		if resize(&p.order_positions, len(p.rows)) != nil {return false}
		for row, i in p.rows {
			p.order_positions[i] = {id = row.id, position = {value = f32(i), target = f32(i)}}
		}
	}
	return true
}

workspace_order_move :: proc(w: ^Window, x, y: f32) {
	p := &w.workspace_picker
	d := workspace_order_lift(p)
	if d == nil {return}
	d.pointer_x, d.pointer_y = x, y
	origin := workspace_picker_slot_rect(w, 0)
	top := clamp((y - origin.y) / origin.height - d.grab, 0, f32(len(p.rows) - 1))
	d.to = int(math.round(top))
	if entry := workspace_order_position(p, d.id); entry != nil {
		ui.motion_target(&entry.position, top, 0, .Linear, false)
	}
}

workspace_order_animate :: proc(w: ^Window, enabled: bool, frame: ui.Frame_Time) -> bool {
	p := &w.workspace_picker
	if len(p.order_positions) == 0 {return false}
	lift := workspace_order_lift(p)
	from := lift != nil ? workspace_row_index(w, lift.id) : -1
	changed, moving := false, false
	for &entry in p.order_positions {
		index := workspace_row_index(w, entry.id)
		if index < 0 {continue}
		if lift == nil || entry.id != lift.id {
			target := index
			if lift != nil && from >= 0 {
				if from < lift.to && index > from && index <= lift.to {target -= 1}
				if lift.to < from && index >= lift.to && index < from {target += 1}
			}
			ui.motion_target(&entry.position, f32(target), ui.REORDER_DURATION, .Decelerate, enabled)
		}
		changed = ui.motion_update(&entry.position, frame) || changed
		moving ||= ui.motion_active(entry.position)
	}
	if lift == nil && !moving {workspace_order_stop(p); changed = true}
	return changed
}

workspace_order_animating :: proc(p: ^Workspace_Picker) -> bool {
	for entry in p.order_positions {if ui.motion_active(entry.position) {return true}}
	return workspace_order_settling(p)
}

// Whether the row at index is drawn on top, lifted or settling after a lift.
workspace_order_lifted :: proc(p: ^Workspace_Picker, index: int) -> bool {
	if index < 0 || index >= len(p.rows) {return false}
	id := p.rows[index].id
	if lift := workspace_order_lift(p); lift != nil {return lift.id == id}
	settle, settling := p.order_settle.?
	return settling && settle.id == id
}

workspace_order_hover :: proc(app: ^App, w: ^Window, e: input.Mouse_Move_Event) -> bool {
	p := &w.workspace_picker
	if workspace_order_grabbed(p) == 0 {return false}
	if .Left not_in e.buttons {workspace_order_end(w); return false}
	x, y := f32(e.x), f32(e.y)
	if pressed := workspace_order_pressed(p); pressed != nil &&
	   (math.abs(x - pressed.start_x) >= DRAG_THRESHOLD * w.scale ||
	    math.abs(y - pressed.start_y) >= DRAG_THRESHOLD * w.scale) {
		lifted := Workspace_Order_Lifted{id = pressed.id, grab = pressed.grab}
		if !workspace_order_begin(w) {
			workspace_order_reset(w)
			notify(app, .Error, "Could not reorder workspaces.")
			return true
		}
		workspace_picker_list_set(w, lifted)
	}
	lifted := workspace_order_lift(p) != nil
	if lifted {
		workspace_order_move(w, x, y)
		_ = workspace_order_animate(w, app.animations, window_frame_time(app, w))
	}
	w.dirty = true
	pointer_set(app, w, lifted ? .Resize_All : .Hand)
	return true
}

workspace_order_release :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	p := &w.workspace_picker
	id := workspace_order_grabbed(p)
	if id == 0 {return}
	workspace_order_move(w, f32(e.x), f32(e.y))
	d: Workspace_Order_Lifted
	lift := workspace_order_lift(p)
	lifted := lift != nil
	if lifted {d = lift^}
	workspace_order_end(w)
	if lifted {
		first := workspace_picker_slot_rect(w, p.scroll)
		last := workspace_picker_slot_rect(w, len(p.rows) - 1)
		r, rows := workspace_picker_rect(w)
		bottom := min(last.y + last.height, first.y + f32(rows) * first.height, r.y + r.height)
		if f32(e.x) >= first.x && f32(e.x) < first.x + first.width &&
		   f32(e.y) >= first.y && f32(e.y) < bottom && d.to >= 0 && d.to < len(p.rows) {
			_ = workspace_reorder(app, d.id, p.rows[d.to].id)
			workspace_row_reveal(w, d.id)
		}
		_ = workspace_order_animate(w, app.animations, window_frame_time(app, w))
	} else if hit := workspace_picker_hit(w, f32(e.x), f32(e.y)); hit >= 0 && hit < len(p.rows) &&
	          p.rows[hit].id == id {
		p.selected = hit
		workspace_picker_choose(app, w)
	}
}
