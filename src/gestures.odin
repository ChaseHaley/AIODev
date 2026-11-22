package main

import "cosmos:input"
import "aio:views"
import "cosmos:ui"
import "cosmos:host"

// What each mouse button is doing between its press and its release (host.Captures). The procs in this
// file are the only writers. A held press belongs to a surface, or to a tab chrome press; a surface
// swallows a press when neither half may reach pane content or a program, and the release then goes to
// that surface alone, or to a modal surface open at the time; a content press is reported to the program
// in a session, which keeps it though the release lands on another pane.
Gesture_State :: host.Captures(Gesture_Owner, Pointer_Target, u32)
Gesture_Capture :: host.Capture(Gesture_Owner, Pointer_Target, u32)
Gesture_Held :: host.Capture_Held(Gesture_Owner)
Gesture_Swallowed :: host.Capture_Swallowed(Pointer_Target)
Gesture_Reported :: host.Capture_Forwarded(u32)
Gesture_Cancelled :: host.Capture_Cancelled

Gesture_Owner :: union #no_nil {
	Pointer_Target,
	Gesture_Tab_Press,
}

// A Left press on a tab, the new-tab button or a rail footer control, drawn pressed until its release.
// The strip draws the press on whichever of its controls the pointer is over; the rail on `target`.
Gesture_Tab_Press :: struct {
	target: Tab_Chrome_Target,
}

@(private)
gesture_owner_target :: proc(owner: Gesture_Owner) -> Pointer_Target {
	switch o in owner {
	case Pointer_Target: return o
	case Gesture_Tab_Press: return .Tabs
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
gesture_buttons :: proc(w: ^Window, $T: typeid) -> input.Mouse_Buttons {
	return host.capture_buttons(&w.gesture, T)
}

// A surface consumed a held button, so pane content shows no hover and programs see no motion.
gesture_swallowing :: proc(w: ^Window) -> bool {return gesture_buttons(w, Gesture_Swallowed) != {}}

// The tab chrome target a held Left press draws pressed, or nil.
gesture_tab_pressed :: proc(w: ^Window) -> Tab_Chrome_Target {
	held, ok := w.gesture.buttons[.Left].(Gesture_Held)
	if !ok {return nil}
	pressed, _ := held.owner.(Gesture_Tab_Press)
	return pressed.target
}

// The surface holding `button` consumes it: one call per press, from that surface's press handler. A
// press the handler already cancelled stays cancelled.
gesture_swallow :: proc(w: ^Window, button: input.Mouse_Button, by: Pointer_Target) {
	host.capture_swallow(&w.gesture, button, by)
}

// A content press the program in `session` receives.
@(private)
gesture_report :: proc(w: ^Window, button: input.Mouse_Button, session: u32) {
	host.capture_forward(&w.gesture, button, session)
}

// A surface passes its press on to `owner`, which then holds it.
gesture_hand_off :: proc(w: ^Window, button: input.Mouse_Button, owner: Pointer_Target) {
	host.capture_hand_off(&w.gesture, button, owner)
}

// A Left press on the tabs that draws `target` pressed until its release.
gesture_tab_press :: proc(w: ^Window, target: Tab_Chrome_Target) {
	held, ok := w.gesture.buttons[.Left].(Gesture_Held)
	if ok && gesture_owner_target(held.owner) == .Tabs {
		w.gesture.buttons[.Left] = Gesture_Held{Gesture_Tab_Press{target}}
	}
}

// The tabs changed under a held press: it stops drawing pressed and still finishes with the tabs.
gesture_tab_unpress :: proc(w: ^Window) {
	held, ok := w.gesture.buttons[.Left].(Gesture_Held)
	if ok && gesture_owner_target(held.owner) == .Tabs {w.gesture.buttons[.Left] = Gesture_Held{.Tabs}}
}

// The held button stops reaching anything until it is released.
gesture_cancel_button :: proc(w: ^Window, button: input.Mouse_Button) {
	host.capture_cancel(&w.gesture, button)
}

// Capture loss: every held button is cancelled and every surface drops its pointer state.
@(private)
gesture_clear :: proc(app: ^App, w: ^Window) {
	for button in input.Mouse_Button {gesture_cancel_button(w, button)}
	host.pointer_cancel(&pointer_surfaces, app, w)
	leader_cancel(w)
	autoscroll_stop(w)
	scroll_hold_end(w)
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
gesture_complete :: proc(app: ^App, w: ^Window, capture: Gesture_Capture, e: input.Mouse_Button_Event) {
	switch c in capture {
	case Gesture_Held:
		if pointer_release(app, w, gesture_owner_target(c.owner), e) {return}
	case Gesture_Swallowed:
		if !pointer_release(app, w, c.by, e) {w.dirty = true}
		return
	case Gesture_Reported, Gesture_Cancelled:
	}
	if gesture_finish(app, w, e) {return}
	if reported, ok := capture.(Gesture_Reported); ok {content_report_release(app, reported.to, e)}
}

// The shared completion of a release its surface declined: a confirmation, the palette and the
// selection.
@(private)
gesture_finish :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	if confirmation_button(app, w, e) {return true}
	w.dirty = true
	x, y := f32(e.x), f32(e.y)
	if palette_active(app, w) {
		if e.button == .Left {on_palette_outcome(app, w, views.palette_pointer_release(&app.palette), 0)}
		return true
	}
	if e.button != .Left {return false}
	if selection_active(w) {selection_finish(app, w, x, y); return true}
	return false
}

// Whether the surface under a release takes it instead of the surface that holds its press: a modal
// surface takes every release, except one pressed on a surface above it that is not modal (the notices)
// and the drop of a drag that holds a workspace dropdown open.
@(private = "file")
gesture_release_taken :: proc(
	w: ^Window,
	under: Pointer_Target,
	capture: Gesture_Capture,
	button: input.Mouse_Button,
) -> bool {
	if !pointer_modal(under) || button == .Left && drag_holds_dropdown(w) {return false}
	owner, owned := gesture_capture_owner(capture)
	return !(owned && !pointer_modal(owner) && owner < under)
}

gesture_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	if w.phase == .Preparing {return}
	if autoscroll_active(w) {
		if e.pressed {
			// A press while scrolling only ends it, and its release reaches nothing.
			autoscroll_end(app, w)
			w.gesture.buttons[e.button] = Gesture_Cancelled{}
			return
		}
		if e.button == .Middle && autoscroll_release(app, w) {
			_ = host.capture_release(&w.gesture, .Middle)
			return
		}
	}
	x, y := f32(e.x), f32(e.y)
	if e.pressed {
		if e.button == .Left {scroll_hold_end(w)}
		target := pointer_target(app, w, x, y)
		modal := pointer_modal(target)
		if !modal {
			if ui.armed_down(w.find.armed) {target = .Find} else if selection_active(w) {target = .Content}
		}
		if e.button == .Left && target != .Changes_Page {w.changes_divider_click = {}}
		host.capture_press(&w.gesture, e.button, target)
		if !modal {
			w.dirty = true
			if target in POINTER_BLURS_FIND && ui.find_has_keyboard(&w.find) {
				ui.find_blur(&w.find, &app.find_history)
			}
		}
		if !modal && autoscroll_begin(app, w, target, e) {
			gesture_swallow(w, e.button, target)
			return
		}
		pointer_press(app, w, target, e)
		return
	}
	if e.button == .Left {scroll_hold_end(w)}
	capture := host.capture_release(&w.gesture, e.button)
	if _, cancelled := capture.(Gesture_Cancelled); cancelled {return}
	target := pointer_target(app, w, x, y)
	if gesture_release_taken(w, target, capture, e.button) {
		pointer_press(app, w, target, e)
		return
	}
	gesture_complete(app, w, capture, e)
}

gesture_move :: proc(app: ^App, w: ^Window, event: input.Mouse_Move_Event) {
	if w.phase == .Preparing {return}
	if autoscroll_move(app, w, event) {return}
	// A held track press follows the pointer; a move without the button means its release was missed.
	if .Left in event.buttons {scroll_hold_move(w, f32(event.x), f32(event.y))} else {scroll_hold_end(w)}
	e := event
	e.buttons -= gesture_buttons(w, Gesture_Cancelled)
	if event.buttons != {} && e.buttons == {} {return}
	x, y := f32(e.x), f32(e.y)
	target := pointer_target(app, w, x, y)
	switch pointer_held(app, w, target, e) {
	case .Free:
	case .Taken:
		return
	case .Ended:
		target = pointer_target(app, w, x, y)
	}
	if !pointer_modal(target) {target = pointer_held_target(w, target)}
	pointer_move(app, w, target, e)
}

// A held button keeps the pointer with the surface it was pressed on until release, whatever buttons a
// move reports, when that surface holds presses. A button swallowed by a modal surface, or sent to a
// program, leaves the pointer on content.
@(private)
pointer_held_target :: proc(w: ^Window, target: Pointer_Target) -> Pointer_Target {
	for capture in w.gesture.buttons {
		owner, owned := gesture_capture_owner(capture)
		if owned && pointer_surfaces[owner].holds {return owner}
	}
	if gesture_swallowing(w) || gesture_buttons(w, Gesture_Reported) != {} {return .Content}
	return target
}
