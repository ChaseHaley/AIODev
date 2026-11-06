package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"
import "core:time"

Gesture_State :: struct {
	buttons, cancelled, reported: input.Mouse_Buttons,
	// The surface each held button was pressed on, which receives its release.
	owners:                       [input.Mouse_Button]Maybe(Pointer_Target),
}

@(private)
gesture_clear :: proc(app: ^App, w: ^Window) {
	w.gesture.cancelled += w.gesture.buttons | w.header_buttons
	if ui.armed_down(w.find.armed) || w.selecting || w.dragging.count > 0 || w.rail_resizing ||
	   w.tab_drag.pressed || w.pane_drag.pressed || ui.armed_down(w.tab_close_armed) ||
	   ui.armed_down(w.caption_armed) || ui.armed_down(w.tab_orientation_button_armed) ||
	   ui.armed_down(w.title_action_armed) ||
	   ui.editor_dragging(&w.editor) || w.rename.dragging || w.workspace_picker.query.dragging {
		w.gesture.cancelled += {.Left}
	}
	w.gesture.buttons, w.gesture.reported, w.header_buttons = {}, {}, {}
	w.gesture.owners = {}
	ui.armed_cancel(&w.find.armed)
	confirmation_release(w)
	w.find.hover = .None
	pane_header_cancel(w)
	w.tab_hover, w.tab_pressed = -1, false
	w.rail_hover, w.rail_pressed = -1, -1
	w.title_action_hover = .None
	ui.armed_cancel(&w.title_action_armed)
	ui.armed_cancel(&w.notice_armed)
	w.notice_hover, w.notice_buttons = 0, {}
	w.tab_orientation_button_hovered = false
	ui.armed_cancel(&w.tab_orientation_button_armed)
	ui.armed_cancel(&w.tab_close_armed)
	w.caption_hover = -1
	ui.armed_cancel(&w.caption_armed)
	w.selecting, w.autoscrolling, w.split_overlay = false, false, false
	w.scroll_drag = {}
	w.rail_resizing = false
	ui.armed_cancel(&w.status.panel_button_armed)
	w.rename.dragging, w.workspace_picker.query.dragging = false, false
	w.document_menu.url.dragging = false
	workspace_order_end(w)
	_ = workspace_order_animate(w, app.animations, time.tick_now())
	link_hover_clear(w)
	if palette_active(app, w) {
		ui.palette_input_release(&app.palette)
		if ui.palette_slider_dragging(&app.palette) {ui.palette_edit_cancel(&app.palette)}
		app.palette.scroll_drag = {}
	}
	markdown_gesture_clear(app, w)
	ui.editor_hover_clear(&w.editor)
	ui.editor_pointer_cancel(&w.editor)
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
	owner, owned := w.gesture.owners[e.button].?
	w.gesture.owners[e.button] = nil
	if owned && pointer_release(app, w, owner, e) {return true}
	// A press or drag that began without a recorded owner still finishes with the surface holding it.
	for target in Pointer_Target {
		if (!owned || target != owner) && pointer_release(app, w, target, e) {return true}
	}
	if confirmation_button(app, w, e) {return true}
	w.rail_pressed, w.tab_pressed, w.dirty = -1, false, true
	x, y := f32(e.x), f32(e.y)
	if e.button in w.header_buttons {
		if palette_active(app, w) {pane_header_cancel(w)}
		return pane_header_button(app, w, e)
	}
	if palette_active(app, w) {
		if e.button == .Left {on_palette_outcome(app, w, ui.palette_pointer_release(&app.palette), 0)}
		return true
	}
	if e.button != .Left {return false}
	// Pane content, and a pane drag the header began, finish here.
	if w.pane_drag.pressed {_ = pane_drag_release(app, w); return true}
	if ui.editor_order_dragging(&w.editor, .Process_Groups) {
		_ = ui.editor_drag(&w.editor, settings_layout(w), &w.ui_text, x, y)
		editor_outcome(app, w, ui.editor_release(&w.editor))
		return true
	}
	if settings_active(w) {editor_outcome(app, w, ui.editor_release(&w.editor)); return true}
	if w.selecting {selection_finish(app, w, x, y); return true}
	return false
}

gesture_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) {
	if w.phase == .Preparing {return}
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
	if !e.pressed && e.button == .Left && w.pane_drag.active && w.pane_drag.picker_window != 0 {
		w.gesture.owners[e.button] = nil
		w.header_buttons -= {.Left}
		pane_drag_move(app, w, x, y, .Shift in e.modifiers)
		pane_header_cancel(w)
		_ = pane_drag_release(app, w)
		return
	}
	if !e.pressed && e.button == .Left && w.tab_drag.active && w.tab_drag.picker_window != 0 {
		w.gesture.owners[e.button] = nil
		w.rail_pressed, w.tab_pressed = -1, false
		_ = tab_drag_move(app, w, x, y)
		tab_drag_finish(app, w)
		return
	}
	target := pointer_target(app, w, x, y)
	if !e.pressed && e.button in w.notice_buttons {
		_ = gesture_complete(app, w, e)
		return
	}
	if pointer_modal(target) {
		if e.pressed {w.gesture.owners[e.button] = target}
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
	w.gesture.owners[e.button] = target
	w.dirty = true
	// A press below the find bar hands the keyboard back to the terminal; the bar and its matches stay.
	if target > .Find && ui.find_has_keyboard(&w.find) {ui.find_blur(&w.find, &app.find_history)}
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
	if e.button == .Right && !w.selecting && .Control in e.modifiers {
		if document_menu_open_link(app, w, x, y) {
			w.header_buttons += {.Right}
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
	if w.scroll_drag.active {terminal_scrollbar_move(app, w, f32(event.y)); return}
	if w.phase == .Preparing {return}
	e := event
	e.buttons -= w.gesture.cancelled
	if event.buttons != {} && e.buttons == {} {return}
	x, y := f32(e.x), f32(e.y)
	target := pointer_target(app, w, x, y)
	if w.pane_drag.pressed && (w.pane_drag.active || !pointer_modal(target)) {
		if .Left not_in e.buttons {
			pane_drag_cancel(app, w)
			target = pointer_target(app, w, x, y)
		} else if pane_drag_move(app, w, x, y, .Shift in e.modifiers) {
			pointer_set(app, w, .Resize_All)
			return
		}
	}
	if w.tab_drag.pressed && (w.tab_drag.active || !pointer_modal(target)) {
		if .Left not_in e.buttons {
			tab_drag_cancel(app, w)
			target = pointer_target(app, w, x, y)
		} else if tab_drag_move(app, w, x, y) {
			if w.tab_drag.active {
				d := &w.tab_drag
				outside := d.new_window || d.destination_window != 0 || d.picker_window != 0
				pointer_set(app, w, outside ? .Resize_All : .Arrow)
			}
			return
		}
	}
	if pointer_modal(target) {
		pointer_move(app, w, target, e)
		return
	}
	if w.dragging.count > 0 {
		if .Left not_in e.buttons {w.dragging, w.rail_resizing = {}, false; return}
		divider_drag(app, w, x, y)
		return
	}
	target = pointer_held_target(w, e.buttons, target)
	pointer_move(app, w, target, e)
}

// A held button keeps the pointer with the surface it was pressed on until release. The palette and a
// confirmation already take the whole window while open, so a press on one that has since closed keeps
// nothing. Captures that began without a recorded owner fall back to the surface holding them.
@(private)
pointer_held_target :: proc(w: ^Window, held: input.Mouse_Buttons, target: Pointer_Target) -> Pointer_Target {
	for button in held {
		owner, owned := w.gesture.owners[button].?
		if owned && !pointer_modal(owner) && owner != .Palette && owner != .Confirmation {return owner}
	}
	switch {
	case ui.armed_down(w.find.armed):
		return .Find
	case ui.editor_dragging(&w.editor):
		return .Settings_Page
	case w.selecting || w.header_buttons != {} || w.gesture.reported != {}:
		return .Content
	}
	return target
}

// Moves over terminal content: the text cursor, links, the selection and programs that report the
// mouse. A button swallowed by another surface keeps the arrow and reaches no program.
@(private)
content_move :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	swallowed := w.header_buttons != {}
	title := y < window_title_height(w)
	shape: platform.Cursor_Shape = swallowed ? .Arrow : .Text
	if title && !swallowed {shape = chrome_pointer(app, w, x, y)}
	entry := pane_at(app, w, e.x, e.y)
	if shape == .Text && entry == nil && !w.selecting {shape = .Arrow}
	resize, over_divider := divider_cursor(w, x, y)
	if over_divider && !swallowed {shape = resize}
	if !w.selecting && !over_divider && !swallowed && !title && link_hover_update(app, w, x, y) {
		shape = .Hand
	} else if w.selecting || over_divider || swallowed || title {
		link_hover_clear(w)
	}
	pointer_set(app, w, shape)
	if swallowed || entry == nil {return}
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
