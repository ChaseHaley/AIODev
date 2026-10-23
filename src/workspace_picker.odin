package main

import "aio:platform"
import "core:math"
import "aio:ui"

Workspace_Picker_Mode :: enum { Closed, List, Menu, Rename, Icons, Tint }

Workspace_Picker :: struct {
	mode: Workspace_Picker_Mode,
	query: ui.Text_Field,
	rows: [dynamic]Workspace_Row,
	selected, scroll: int,
	target_id: u32,
	menu_selected: int,
	rename_motion: ui.Motion,
	rename_error: bool,
	saved_query: ui.Text_Field,
}

workspace_picker_active :: proc(p: ^Workspace_Picker) -> bool {
	return p.mode != .Closed
}

workspace_picker_icons :: proc(p: ^Workspace_Picker) -> bool {
	return p.mode == .Icons || p.mode == .Tint
}

workspace_picker_target :: proc(p: ^Workspace_Picker, mode: Workspace_Picker_Mode) -> u32 {
	return p.mode == mode || mode == .Icons && p.mode == .Tint ? p.target_id : 0
}

@(private)
workspace_picker_transition :: proc(w: ^Window, mode: Workspace_Picker_Mode, target_id: u32 = 0) {
	p := &w.workspace_picker
	p.mode, p.target_id = mode, target_id
	p.menu_selected, p.rename_error, p.rename_motion = 0, false, {}
	p.query.dragging, w.rename.dragging, w.dirty = false, false, true
}

workspace_picker_cancel :: proc(w: ^Window, focus_lost := false) {
	p := &w.workspace_picker
	p.query.dragging, w.rename.dragging = false, false
	// Windows' emoji picker can take focus before delivering text to the icon field.
	if focus_lost && workspace_picker_icons(p) {return}
	workspace_picker_transition(w, .Closed)
}

workspace_picker_destroy :: proc(w: ^Window) {
	delete(w.workspace_picker.query.bytes)
	delete(w.workspace_picker.saved_query.bytes)
	delete(w.workspace_picker.rows)
	w.workspace_picker = {}
}

workspace_picker_layout_changed :: proc(w: ^Window) {
	p := &w.workspace_picker
	if !workspace_picker_active(p) {return}
	p.selected = clamp(p.selected, 0, workspace_picker_count(w)-1)
	if workspace_picker_icons(p) {
		workspace_icon_picker_reveal(w, workspace_icon_picker_layout(w))
		return
	}
	if p.mode == .Rename || p.mode == .Menu {
		if index := workspace_row_index(w, p.target_id); index >= 0 {p.selected = index}
	}
	_, rows := workspace_picker_rect(w)
	p.scroll = clamp(p.scroll, max(0, p.selected-rows+1), p.selected)
	p.scroll = clamp(p.scroll, 0, max(0, workspace_picker_count(w)-rows))
}

workspace_picker_select :: proc(w: ^Window, index: int) {
	w.workspace_picker.selected, w.dirty = index, true
	workspace_picker_layout_changed(w)
}

workspace_picker_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	p := &w.workspace_picker
	if !e.pressed {
		p.query.dragging, w.rename.dragging = false, false
		w.header_buttons -= {e.button}
		return
	}
	w.header_buttons += {e.button}
	x, y := f32(e.x), f32(e.y)
	r, _ := workspace_picker_rect(w)
	if p.mode == .Menu && e.button == .Left {
		workspace_picker_click(app, w, x, y, .Shift in e.modifiers)
	} else if !workspace_rect_contains(r, x, y) {
		workspace_picker_cancel(w)
	} else if e.button == .Left {
		workspace_picker_click(app, w, x, y, .Shift in e.modifiers)
	}
}

workspace_picker_hover :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	if workspace_row_hover(app, w, e) {return}
	if w.workspace_picker.query.dragging && .Left in e.buttons {
		workspace_picker_pointer(app, w, f32(e.x), false, true)
	} else if hit := workspace_picker_hit(w, f32(e.x), f32(e.y)); hit >= 0 {
		workspace_picker_select(w, hit)
	}
	pointer_set(app, w, .Arrow)
}

workspace_picker_wheel :: proc(w: ^Window, delta: f32) {
	p := &w.workspace_picker
	if p.mode == .Menu || p.mode == .Rename {return}
	workspace_picker_select(w, p.selected-int(math.sign(delta)))
}
