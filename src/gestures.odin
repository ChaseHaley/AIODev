package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

// What each mouse button is doing between its press and its release; nil is a free button. The procs
// in this file are the only writers. Every press records its surface before reaching it, so a release
// and the moves before it go to the surface recorded at the press.
Gesture_State :: struct {
	captures: [input.Mouse_Button]Gesture_Capture,
}

Gesture_Capture :: union {
	Gesture_Held,
	Gesture_Swallowed,
	Gesture_Reported,
	Gesture_Cancelled,
}

// Pressed on a surface, which receives the release; a release it declines reaches the shared completion
// for confirmations, the palette and pane content.
Gesture_Held :: struct {
	owner: Gesture_Owner,
}

// Consumed by a surface: neither half reaches pane content or a program, and the release goes to that
// surface alone, or to a modal surface open at the time.
Gesture_Swallowed :: struct {
	by: Pointer_Target,
}

// Pressed on pane content and sent to the program there, which also receives the release.
Gesture_Reported :: struct {}

// The pointer was taken away while the button was down: its moves and its release reach nothing.
Gesture_Cancelled :: struct {}

Gesture_Owner :: union #no_nil {
	Pointer_Target,
	Gesture_Tab,
	Gesture_Rail_Row,
}

// A Left press on a strip tab or the new-tab button, drawn pressed while the pointer is over it.
Gesture_Tab :: struct {}

// A Left press on a rail row: a tab index, RAIL_NEW_TAB_ROW or RAIL_PROFILE_ROW, drawn pressed.
Gesture_Rail_Row :: struct {
	row: int,
}

@(private)
gesture_owner_target :: proc(owner: Gesture_Owner) -> Pointer_Target {
	switch o in owner {
	case Pointer_Target: return o
	case Gesture_Tab, Gesture_Rail_Row: return .Tabs
	}
	return .Content
}

// The surface a capture belongs to; false for a free or cancelled button.
@(private)
gesture_capture_owner :: proc(capture: Gesture_Capture) -> (Pointer_Target, bool) {
	switch c in capture {
	case Gesture_Held: return gesture_owner_target(c.owner), true
	case Gesture_Swallowed: return c.by, true
	case Gesture_Reported: return .Content, true
	case Gesture_Cancelled:
	}
	return {}, false
}

// The buttons whose capture is a T.
gesture_buttons :: proc(w: ^Window, $T: typeid) -> (buttons: input.Mouse_Buttons) {
	for capture, button in w.gesture.captures {
		if _, ok := capture.(T); ok {buttons += {button}}
	}
	return
}

// A surface consumed a held button, so pane content shows no hover and programs see no motion.
gesture_swallowing :: proc(w: ^Window) -> bool {return gesture_buttons(w, Gesture_Swallowed) != {}}

gesture_tab_pressed :: proc(w: ^Window) -> bool {
	held, ok := w.gesture.captures[.Left].(Gesture_Held)
	if !ok {return false}
	_, tab := held.owner.(Gesture_Tab)
	return tab
}

// The pressed rail row, or -1.
gesture_rail_pressed :: proc(w: ^Window) -> int {
	held, ok := w.gesture.captures[.Left].(Gesture_Held)
	if !ok {return -1}
	pressed, rail := held.owner.(Gesture_Rail_Row)
	return rail ? pressed.row : -1
}

// The surface holding `button` consumes it: one call per press, from that surface's press handler. A
// press the handler already cancelled stays cancelled.
gesture_swallow :: proc(w: ^Window, button: input.Mouse_Button, by: Pointer_Target) {
	if _, held := w.gesture.captures[button].(Gesture_Held); held {
		w.gesture.captures[button] = Gesture_Swallowed{by}
	}
}

// A content press the program under the pointer receives.
@(private)
gesture_report :: proc(w: ^Window, button: input.Mouse_Button) {
	if _, held := w.gesture.captures[button].(Gesture_Held); held {
		w.gesture.captures[button] = Gesture_Reported{}
	}
}

// A surface passes its press on to `owner`, which then holds it.
gesture_hand_off :: proc(w: ^Window, button: input.Mouse_Button, owner: Pointer_Target) {
	if _, held := w.gesture.captures[button].(Gesture_Held); held {
		w.gesture.captures[button] = Gesture_Held{owner}
	}
}

// A Left press on the tabs that draws `row` pressed until its release.
gesture_tab_press :: proc(w: ^Window, row: Gesture_Owner) {
	held, ok := w.gesture.captures[.Left].(Gesture_Held)
	if ok && gesture_owner_target(held.owner) == .Tabs {w.gesture.captures[.Left] = Gesture_Held{row}}
}

// The tabs changed under a held press: it stops drawing pressed and still finishes with the tabs.
gesture_tab_unpress :: proc(w: ^Window) {
	held, ok := w.gesture.captures[.Left].(Gesture_Held)
	if ok && gesture_owner_target(held.owner) == .Tabs {w.gesture.captures[.Left] = Gesture_Held{.Tabs}}
}

// The held button stops reaching anything until it is released.
gesture_cancel_button :: proc(w: ^Window, button: input.Mouse_Button) {
	if w.gesture.captures[button] != nil {w.gesture.captures[button] = Gesture_Cancelled{}}
}

// Capture loss: every held button is cancelled and every surface drops its pointer state.
@(private)
gesture_clear :: proc(app: ^App, w: ^Window) {
	for button in input.Mouse_Button {gesture_cancel_button(w, button)}
	for surface in pointer_surfaces {
		if surface.cancel != nil {surface.cancel(app, w)}
	}
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

// Delivers a release to the surface recorded at its press. Completion never falls through to fresh hit
// testing, even when its action removes w.
@(private)
gesture_complete :: proc(app: ^App, w: ^Window, capture: Gesture_Capture, e: platform.Mouse_Button_Event) {
	switch c in capture {
	case Gesture_Held:
		if pointer_release(app, w, gesture_owner_target(c.owner), e) {return}
	case Gesture_Swallowed:
		if !pointer_release(app, w, c.by, e) {w.dirty = true}
		return
	case Gesture_Reported, Gesture_Cancelled:
	}
	if gesture_finish(app, w, e) {return}
	if _, reported := capture.(Gesture_Reported); reported {
		if entry := pane_at(app, w, e.x, e.y); entry != nil && reports_mouse(entry, e.modifiers) {
			term.send_mouse(entry.session, .Release, e.button, {}, e.modifiers, f32(e.x), f32(e.y))
		}
	}
}

// The shared completion of a release its surface declined: a confirmation, the palette, then pane
// content and a pane drag the header began.
@(private)
gesture_finish :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	if confirmation_button(app, w, e) {return true}
	w.dirty = true
	x, y := f32(e.x), f32(e.y)
	if palette_active(app, w) {
		if e.button == .Left {on_palette_outcome(app, w, ui.palette_pointer_release(&app.palette), 0)}
		return true
	}
	if e.button != .Left {return false}
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
	x, y := f32(e.x), f32(e.y)
	if e.pressed {
		target := pointer_target(app, w, x, y)
		modal := pointer_modal(target)
		if !modal {
			if ui.armed_down(w.find.armed) {target = .Find} else if w.selecting {target = .Content}
		}
		w.gesture.captures[e.button] = Gesture_Held{target}
		if !modal {
			w.dirty = true
			// A press below the find bar hands the keyboard back to the terminal; the bar and its matches stay.
			if target > .Find && ui.find_has_keyboard(&w.find) {ui.find_blur(&w.find, &app.find_history)}
		}
		pointer_press(app, w, target, e)
		return
	}
	capture := w.gesture.captures[e.button]
	w.gesture.captures[e.button] = nil
	if _, cancelled := capture.(Gesture_Cancelled); cancelled {return}
	if e.button == .Left && w.pane_drag.active && w.pane_drag.picker_window != 0 {
		pane_drag_move(app, w, x, y, .Shift in e.modifiers)
		pane_header_cancel(w)
		_ = pane_drag_release(app, w)
		return
	}
	if e.button == .Left && w.tab_drag.active && w.tab_drag.picker_window != 0 {
		_ = tab_drag_move(app, w, x, y)
		tab_drag_finish(app, w)
		return
	}
	target := pointer_target(app, w, x, y)
	// A modal surface takes every release, except one pressed on a surface above it: the notices.
	owner, owned := gesture_capture_owner(capture)
	if pointer_modal(target) && !(owned && !pointer_modal(owner) && owner < target) {
		pointer_press(app, w, target, e)
		return
	}
	gesture_complete(app, w, capture, e)
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
			gesture_swallow(w, .Right, .Content)
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
		gesture_report(w, e.button)
		term.send_mouse(entry.session, .Press, e.button, {e.button}, e.modifiers, x, y)
	}
}

gesture_move :: proc(app: ^App, w: ^Window, event: platform.Mouse_Move_Event) {
	if w.scroll_drag.active {terminal_scrollbar_move(app, w, f32(event.y)); return}
	if w.phase == .Preparing {return}
	e := event
	e.buttons -= gesture_buttons(w, Gesture_Cancelled)
	if event.buttons != {} && e.buttons == {} {return}
	x, y := f32(e.x), f32(e.y)
	if floating_pointer_move(app, w, e) {return}
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
	target = pointer_held_target(w, target)
	pointer_move(app, w, target, e)
}

// A held button keeps the pointer with the surface it was pressed on until release, whatever buttons a
// move reports. The palette and a confirmation already take the whole window while open, so a press on
// one that has since closed keeps nothing. A button swallowed by a modal surface, or sent to a program,
// leaves the pointer on content.
@(private)
pointer_held_target :: proc(w: ^Window, target: Pointer_Target) -> Pointer_Target {
	for capture in w.gesture.captures {
		owner, owned := gesture_capture_owner(capture)
		if owned && !pointer_modal(owner) && owner != .Palette && owner != .Confirmation {return owner}
	}
	if gesture_swallowing(w) || gesture_buttons(w, Gesture_Reported) != {} {return .Content}
	return target
}

// Moves over terminal content: the text cursor, links, the selection and programs that report the
// mouse. A button swallowed by another surface keeps the arrow and reaches no program.
@(private)
content_move :: proc(app: ^App, w: ^Window, e: platform.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	swallowed := gesture_swallowing(w)
	title := y < window_title_height(w)
	shape: platform.Cursor_Shape = swallowed ? .Arrow : .Text
	if title && !swallowed {shape = chrome_pointer(app, w, x, y)}
	entry := pane_at(app, w, e.x, e.y)
	if shape == .Text && entry == nil && !w.selecting {shape = .Arrow}
	resize, over_divider := divider_cursor(w, x, y)
	over_divider &&= !floating_covers(w, x, y)
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
		held := e.buttons & gesture_buttons(w, Gesture_Reported)
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
