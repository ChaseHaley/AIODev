package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

Gesture_State :: struct {
	buttons, cancelled, reported: input.Mouse_Buttons,
}

@(private)
gesture_clear :: proc(app: ^App, w: ^Window) {
	w.gesture.cancelled += w.gesture.buttons | w.header_buttons
	if ui.armed_down(w.find.armed) || w.selecting || w.dragging.count > 0 || w.rail_resizing ||
	   w.tab_drag.pressed || w.pane_drag.pressed || ui.armed_down(w.tab_close_armed) ||
	   ui.armed_down(w.caption_armed) || ui.armed_down(w.tab_orientation_button_armed) ||
	   ui.armed_down(w.title_action_armed) ||
	   w.editor.drag != .None || w.rename.dragging || w.workspace_picker.query.dragging {
		w.gesture.cancelled += {.Left}
	}
	w.gesture.buttons, w.gesture.reported, w.header_buttons = {}, {}, {}
	ui.armed_cancel(&w.find.armed)
	confirmation_release(w)
	w.find.hover = .None
	pane_header_cancel(w)
	w.tab_hover, w.tab_pressed = -1, false
	w.rail_hover, w.rail_pressed = -1, -1
	w.title_action_hover = .None
	ui.armed_cancel(&w.title_action_armed)
	w.tab_orientation_button_hovered = false
	ui.armed_cancel(&w.tab_orientation_button_armed)
	ui.armed_cancel(&w.tab_close_armed)
	w.caption_hover = -1
	ui.armed_cancel(&w.caption_armed)
	w.selecting, w.autoscrolling, w.split_overlay = false, false, false
	w.scroll_drag = false
	w.rail_resizing = false
	ui.armed_cancel(&w.status.panel_side_armed)
	w.rename.dragging, w.workspace_picker.query.dragging = false, false
	link_hover_clear(w)
	if palette_active(app, w) {
		ui.palette_input_release(&app.palette)
		if ui.palette_slider_dragging(&app.palette) {ui.palette_edit_cancel(&app.palette)}
	}
	ui.editor_hover_clear(&w.editor)
	if w.editor.drag == .Process_Order {w.editor.drag = .None}
	ui.editor_release(&w.editor)
	leader_cancel(w)
	w.dirty = true
}

// The result is the caller's permission to keep using w: cancelling a preview can remove it.
@(require_results)
gesture_cancel :: proc(app: ^App, w: ^Window) -> bool {
	id := w.id
	gesture_clear(app, w)
	arrange_cancel(app, w)
	return window_find(app, id) == w
}

// Completion never falls through to fresh hit testing, even when its action removes w.
@(private)
gesture_complete :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if e.button == .Left && w.scroll_drag {terminal_scrollbar_release(app, w, f32(e.x), f32(e.y)); return true}
	x, y := f32(e.x), f32(e.y)
	if e.button == .Left && ui.armed_down(w.status.panel_side_armed) {
		w.header_buttons -= {.Left}
		w.dirty = true
		_, ok := ui.armed_release(&w.status.panel_side_armed,
			status_rect_contains(status_panel_side_rect(app, w), x, y))
		if ok {status_panel_side_toggle(app)}
		return true
	}
	if e.button == .Left && ui.armed_down(w.title_action_armed) {
		fired, ok := ui.armed_release(&w.title_action_armed, title_action_hit(w, x, y))
		w.dirty = true
		if ok {
			switch fired {
			case .None:
			case .Settings: editor_open(app, w)
			case .Palette: palette_open(app, w)
			}
		}
		return true
	}
	if e.button == .Left && w.find.open && ui.armed_down(w.find.armed) {
		entry := focused_session(app, w)
		l, enabled := find_controls(w, entry)
		on_find_outcome(app, w, entry, ui.find_mouse(&w.find, l, enabled, e.button, false, x, y))
		return true
	}
	if e.button == .Left &&
	   ui.armed_down(w.tab_orientation_button_armed) {
		fired, ok := ui.armed_release(&w.tab_orientation_button_armed, tab_orientation_button_hit(w, x, y))
		w.dirty = true
		if ok && fired {toggle_tab_orientation(app)}
		return true
	}
	if e.button == .Left && ui.armed_down(w.caption_armed) && !w.pane_drag.pressed && !w.tab_drag.pressed {
		fired, ok := ui.armed_release(
			&w.caption_armed,
			ui.caption_hit(f32(w.width), x, y, w.scale),
		)
		w.dirty = true
		if ok {platform.window_caption_action(&app.platform, w.id, fired)}
		return true
	}
	if confirmation_button(app, w, e) {return true}
	w.rail_pressed, w.tab_pressed, w.dirty = -1, false, true
	if e.button in w.header_buttons {
		if palette_active(app, w) {pane_header_cancel(w)}
		return pane_header_button(app, w, e)
	}
	if palette_active(app, w) {
		if e.button == .Left {on_palette_outcome(app, w, ui.palette_pointer_release(&app.palette), 0)}
		return true
	}
	if e.button != .Left {return false}
	if tab_interaction_release(app, w, x, y) {return true}
	if w.dragging.count > 0 {
		divider_drag(app, w, x, y)
		w.dragging, w.rail_resizing = {}, false
		return true
	}
	if w.tab_drag.pressed {tab_drag_release(app, w); rail_overlay_dismiss(app, w); return true}
	if w.pane_drag.pressed {_ = pane_drag_release(app, w); return true}
	if w.editor.drag == .Process_Order {
		_ = ui.editor_drag(&w.editor, settings_layout(w), &w.ui_text, x, y)
		editor_outcome(app, w, ui.editor_release(&w.editor))
		return true
	}
	if settings_active(w) {editor_outcome(app, w, ui.editor_release(&w.editor)); return true}
	if w.selecting {selection_finish(app, w, x, y); return true}
	return false
}

gesture_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if w.preparing {return}
	if e.pressed {
		w.gesture.cancelled -= {e.button}
		w.gesture.buttons += {e.button}
	} else {
		w.gesture.buttons -= {e.button}
		if e.button in w.gesture.cancelled {
			w.gesture.cancelled -= {e.button}
			return
		}
	}
	x, y := f32(e.x), f32(e.y)
	target := pointer_target(app, w, x, y)
	if pointer_modal(target) {
		pointer_press(app, w, target, e)
		return
	}
	if !e.pressed {
		if gesture_complete(app, w, e) {return}
		if e.button in w.gesture.reported {
			w.gesture.reported -= {e.button}
			if entry := pane_at(app, w, e.x, e.y); entry != nil && reports_mouse(entry, e.modifiers) {
				term.send_mouse(entry.session, .Release, e.button, {}, e.modifiers, f32(e.x), f32(e.y))
			}
		}
		return
	}
	if ui.armed_down(w.find.armed) {target = .Find} else if w.selecting {target = .Content}
	w.dirty = true
	// A press below the find bar hands the keyboard back to the terminal; the bar and its matches stay.
	if target > .Find && w.find.focused {ui.find_blur(&w.find, &app.find_history)}
	pointer_press(app, w, target, e)
}

// A press on pane content focuses the pane, then reaches a settings page, a link, the selection or a
// program that reports the mouse.
@(private)
content_press :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	if !w.selecting {
		if pane, found := layout.hit_test(w.panes[:], x, y); found {pane_focus(app, w, pane.node)}
	}
	if settings_active(w) {
		if e.button == .Left {
			editor_outcome(
				app,
				w,
				ui.editor_press(&w.editor, settings_layout(w), &w.ui_text, x, y, .Shift in e.modifiers),
			)
		}
		return
	}
	entry := pane_at(app, w, e.x, e.y)
	if entry == nil {
		return
	}
	if e.button == .Left && !w.selecting && .Control in e.modifiers {
		if link_click(app, w, x, y) {
			return
		}
	}
	if e.button == .Left && (w.selecting || !reports_mouse(entry, e.modifiers)) {
		w.selecting = true
		term.selection_press(entry.session, x, y, e.time_ns)
		w.dirty = true
		return
	}
	if reports_mouse(entry, e.modifiers) {
		w.gesture.reported += {e.button}
		term.send_mouse(entry.session, .Press, e.button, {e.button}, e.modifiers, x, y)
	}
}

gesture_move :: proc(app: ^App, w: ^Window, event: platform.Mouse_Move_Event) {
	if w.scroll_drag {terminal_scrollbar_move(app, w, f32(event.y)); return}
	if w.preparing {return}
	e := event
	e.buttons -= w.gesture.cancelled
	if event.buttons != {} && e.buttons == {} {return}
	x, y := f32(e.x), f32(e.y)
	target := pointer_target(app, w, x, y)
	if pointer_modal(target) {
		pointer_move(app, w, target, e)
		return
	}
	if w.dragging.count > 0 {
		if .Left not_in e.buttons {w.dragging, w.rail_resizing = {}, false; return}
		divider_drag(app, w, x, y)
		return
	}
	if w.tab_drag.pressed {
		if .Left not_in e.buttons {tab_drag_cancel(app, w)} else if tab_drag_move(app, w, x, y) {return}
	}
	if w.pane_drag.pressed {
		if .Left not_in e.buttons {
			pane_drag_cancel(app, w)
		} else if pane_drag_move(app, w, x, y, .Shift in e.modifiers) {
			pointer_set(app, w, .Resize_All)
			return
		}
	}
	// A press that began on a surface keeps the pointer there until it is released.
	if ui.armed_down(w.find.armed) {
		target = .Find
	} else if w.selecting || w.header_buttons != {} || w.editor.drag != .None || w.gesture.reported != {} {
		target = .Content
	}
	pointer_move(app, w, target, e)
}

// Moves over pane content and pane headers: header buttons, links, settings pages, the selection and
// programs that report the mouse.
@(private)
content_move :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	enabled := !w.selecting
	split_overlay_update(w, x, y, enabled)
	over_header, header_action := pane_header_pointer(w, x, y, enabled)
	shape: platform.Cursor_Shape = over_header || w.header_buttons != {} ? .Arrow : .Text
	if over_header && header_action != .None && w.header_buttons == {} {shape = .Hand}
	if y < ui.TITLE_BAR_HEIGHT * w.scale {
		shape = w.header_buttons == {} ? chrome_pointer(app, w, x, y) : .Arrow
	}
	entry := pane_at(app, w, e.x, e.y)
	if shape == .Text && entry == nil && !w.selecting {shape = .Arrow}
	resize, over_divider := divider_cursor(w, x, y)
	if over_divider && w.header_buttons == {} {shape = resize}
	link_hovered := false
	if enabled && !over_header && !over_divider && w.header_buttons == {} &&
	   y >= ui.TITLE_BAR_HEIGHT * w.scale {
		link_hovered = link_hover_update(app, w, x, y)
	} else {
		link_hover_clear(w)
	}
	if link_hovered {shape = .Hand}
	over_settings := false
	if enabled && !over_header && w.header_buttons == {} && !over_divider {
		if pane, found := settings_pane_under_pointer(w, x, y); found {
			l := settings_layout_for(w, pane.rect)
			changed := ui.editor_hover(&w.editor, l, x, y)
			if .Left in e.buttons && ui.editor_drag(&w.editor, l, &w.ui_text, x, y) {changed = true}
			if changed {w.dirty = true}
			shape = ui.editor_pointer(&w.editor, l, x, y)
			over_settings = true
		}
	}
	pointer_set(app, w, shape)
	if over_header || w.header_buttons != {} || over_settings {return}
	if entry == nil {
		return
	}
	if w.selecting {
		term.selection_drag(entry.session, x, y)
		w.pointer = {x, y}
		autoscroll_follow(w, entry)
		w.dirty = true
	} else if reports_mouse(entry, e.modifiers) {
		held := e.buttons & w.gesture.reported
		if e.buttons != {} && held == {} {return}
		term.send_mouse(entry.session, .Motion, nil, held, e.modifiers, x, y)
	}
}

@(private)
selection_finish :: proc(app: ^App, w: ^Window, x, y: f32) {
	entry := focused_session(app, w)
	w.selecting, w.autoscrolling = false, false
	if entry == nil {return}
	term.selection_release(entry.session, x, y)
	if app.settings.terminal.copy_on_select {copy_selection(app, entry, false)}
	w.dirty = true
}
