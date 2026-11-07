package main

import "aio:input"
import "aio:layout"
import "aio:platform"
import "aio:term"
import "aio:ui"

// The pointer over pane content and anything uncovered: pane focus, a settings page press, links, the
// selection, and programs that report the mouse.

@(private)
pane_at :: proc(app: ^App, w: ^Window, x, y: i32) -> ^Session_Entry {
	pane, found := layout.hit_test(w.panes[:], f32(x), f32(y))
	if selection_active(w) {return selection_entry(app, w)}
	if !found {return nil}
	return workspace_session_for_content(app, pane.content)
}

@(private)
reports_mouse :: proc(entry: ^Session_Entry, modifiers: input.Modifiers) -> bool {
	return .Shift not_in modifiers && term.mouse_tracking(entry.session)
}

@(private)
content_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return true}

@(private)
content_hover :: proc(app: ^App, w: ^Window, owner: Pointer_Target, e: input.Mouse_Move_Event) {
	if owner == .Content {content_move(app, w, e)} else {link_hover_clear(w)}
}

@(private)
content_cancel :: proc(_: ^App, w: ^Window) {
	selection_cancel(w)
	link_hover_clear(w)
}

@(private)
content_leave :: proc(_: ^App, w: ^Window) {
	link_hover_clear(w)
}

// A press on pane content focuses the pane, then reaches a settings page, a link, the selection or a
// program that reports the mouse. That program also receives the release, wherever it lands.
@(private)
content_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	x, y := f32(e.x), f32(e.y)
	if !selection_active(w) {
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
	if e.button == .Left && !selection_active(w) && .Control in e.modifiers {
		if link_click(app, w, x, y) {
			return
		}
	}
	if e.button == .Right && !selection_active(w) && .Control in e.modifiers {
		if document_menu_open_link(app, w, x, y) {
			gesture_swallow(w, .Right, .Content)
			return
		}
	}
	if e.button == .Left && (selection_active(w) || !reports_mouse(entry, e.modifiers)) {
		selection_begin(w, entry, x, y, e.time_ns)
		return
	}
	if reports_mouse(entry, e.modifiers) {
		gesture_report(w, e.button, entry.id)
		term.send_mouse(entry.session, .Press, e.button, {e.button}, e.modifiers, x, y)
	}
}

// The release of a press a program received goes to that program, though the pointer has since moved
// to another pane.
@(private)
content_report_release :: proc(app: ^App, session: u32, e: input.Mouse_Button_Event) {
	if entry := session_find(app, session); entry != nil && reports_mouse(entry, e.modifiers) {
		term.send_mouse(entry.session, .Release, e.button, {}, e.modifiers, f32(e.x), f32(e.y))
	}
}

// Moves over terminal content: the text cursor, links, the selection and programs that report the
// mouse. A button swallowed by another surface keeps the arrow and reaches no program.
@(private)
content_move :: proc(app: ^App, w: ^Window, e: input.Mouse_Move_Event) {
	x, y := f32(e.x), f32(e.y)
	swallowed := gesture_swallowing(w)
	title := y < window_title_height(w)
	shape: platform.Cursor_Shape = swallowed ? .Arrow : .Text
	if title && !swallowed {shape = chrome_pointer(app, w, x, y)}
	entry := pane_at(app, w, e.x, e.y)
	if shape == .Text && entry == nil && !selection_active(w) {shape = .Arrow}
	resize, over_divider := divider_cursor(w, x, y)
	over_divider &&= !floating_covers(w, x, y)
	if over_divider && !swallowed {shape = resize}
	if selection_active(w) || over_divider || title || swallowed {
		link_hover_clear(w)
	} else if link_hover_update(app, w, x, y) {
		shape = .Hand
	}
	pointer_set(app, w, shape)
	if swallowed || entry == nil {return}
	if selection_active(w) {
		selection_move(w, entry, x, y)
	} else if reports_mouse(entry, e.modifiers) {
		held := e.buttons & gesture_buttons(w, Gesture_Reported)
		if e.buttons != {} && held == {} {return}
		term.send_mouse(entry.session, .Motion, nil, held, e.modifiers, x, y)
	}
}
