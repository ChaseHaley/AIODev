package main

import "aio:input"
import "aio:render"
import "aio:ui"
import "core:time"

// The question a window asks before a change it cannot undo. A window asks at most one: nil is None;
// otherwise the dialog's presence is the phase, Asking while it opens or shows (ui.presence_is_open)
// and Closing while an answered or dismissed question fades out. A closing question keeps its subject,
// so it draws unchanged until the fade settles and the subject is released. The procs in this file are
// the only writers; each subject's file prepares its payload, words it and acts on the answer.
Confirmation :: struct {
	dialog:  ui.Confirm,
	subject: Confirmation_Subject,
}

// What the question is about, holding what its answer and its text need.
Confirmation_Subject :: union {
	Pending_Close,
	Pane_Swap,
	Pending_File,
	Process_Remove,
	Profile_Remove,
	Settings_Reset,
}

Confirmation_Text :: struct {
	title, body, label, note: string,
	// The checkbox beside the buttons; empty shows none.
	option:                   string,
}

// The question the window shows, asking or closing; nil when it asks nothing.
confirmation_shown :: proc(w: ^Window) -> ^Confirmation {
	c, ok := &w.confirmation.?
	return ok ? c : nil
}

// The dialog of the question that is asking, which has the window's input; nil otherwise.
confirmation_current :: proc(w: ^Window) -> ^ui.Confirm {
	c := confirmation_shown(w)
	return c != nil && ui.presence_is_open(c.dialog.presence) ? &c.dialog : nil
}

// The subject of the question shown, asking or closing, when it is a T.
confirmation_subject :: proc(w: ^Window, $T: typeid) -> ^T {
	c := confirmation_shown(w)
	if c == nil {return nil}
	subject, _ := &c.subject.(T)
	return subject
}

// The subject of the question that is asking, when it is a T.
confirmation_asking :: proc(w: ^Window, $T: typeid) -> ^T {
	if confirmation_current(w) == nil {return nil}
	return confirmation_subject(w, T)
}

// Asks about `subject`, which the window now owns, presenting it as stated. The question first closes
// what it replaces (overlay_close_all), except `reopening`: an asking question its caller rewrites in
// place, having taken what it keeps from it. A question still closing is released at once. The caller
// has cancelled any pointer gesture that asked it.
confirmation_ask :: proc(
	app: ^App,
	w: ^Window,
	subject: Confirmation_Subject,
	extended := false,
	focus := ui.Confirm_Button.Accept,
	show_option := false,
	reopening: ^ui.Confirm = nil,
) {
	overlay_close_all(app, w, reopening)
	confirmation_clear(w)
	c := Confirmation{subject = subject}
	ui.confirm_open(&c.dialog, extended, focus, show_option)
	w.confirmation = c
	w.dirty = true
}

// Answers the asking question. The dialog starts closing with its subject intact, then the subject's
// file acts on the answer. Acceptance may retire w, so nothing here inspects it afterwards.
confirmation_finish :: proc(app: ^App, w: ^Window, accept: bool) {
	if confirmation_current(w) == nil {return}
	c := confirmation_shown(w)
	ui.confirm_close(&c.dialog)
	w.dirty = true
	switch &subject in c.subject {
	case Pending_Close:
		pending_close_finish(app, w, &subject, accept)
	case Pane_Swap:
		pane_swap_finish(app, w, subject, c.dialog.option, accept)
	case Pending_File:
		pending_file_finish(app, subject, accept)
	case Process_Remove:
		editor_process_remove_finish(app, w, subject, accept)
	case Profile_Remove:
		editor_profile_remove_finish(app, w, subject, accept)
	case Settings_Reset:
		settings_reset_finish(app, subject, accept)
	}
}

// Releases the subject's payload and returns the window to asking nothing, ending any fade.
confirmation_clear :: proc(w: ^Window) {
	c := confirmation_shown(w)
	if c == nil {return}
	switch &subject in c.subject {
	case Pending_Close:
		pending_close_destroy(&subject)
	case Pane_Swap:
		pane_swap_destroy(&subject)
	case Pending_File:
		pending_file_destroy(&subject)
	case Process_Remove:
		editor_process_remove_destroy(&subject)
	case Profile_Remove:
		editor_profile_remove_destroy(&subject)
	case Settings_Reset:
		settings_reset_destroy(&subject)
	}
	w.confirmation = nil
}

// Dismisses the asking question as its Cancel button would. A close question also lets go of its
// subject at once, since the navigation that dismissed it changes the tabs its text counts; the other
// subjects fade out as answered questions do.
confirmation_cancel :: proc(app: ^App, w: ^Window) {
	confirmation_finish(app, w, false)
	if confirmation_subject(w, Pending_Close) != nil {confirmation_clear(w)}
}

// The window stops showing its workspace. A close question counts the tabs it stops showing, so it
// ends now, putting back any marks its subset replaced; other questions are unaffected.
confirmation_workspace_depart :: proc(app: ^App, w: ^Window) {
	if confirmation_subject(w, Pending_Close) != nil {confirmation_cancel(app, w)}
}

@(private)
confirmation_layout :: proc(w: ^Window, c: ^ui.Confirm) -> ui.Confirm_Layout {
	return ui.confirm_layout(f32(w.width), f32(w.height), w.scale, c.extended, c.show_option)
}

@(private)
confirmation_outcome :: proc(app: ^App, w: ^Window, outcome: ui.Confirm_Outcome) {
	switch outcome {
	case .None:
	case .Changed:
		w.dirty = true
	case .Accept, .Cancel:
		confirmation_finish(app, w, outcome == .Accept)
	}
}

confirmation_key :: proc(app: ^App, w: ^Window, e: input.Key_Event) -> bool {
	c := confirmation_current(w)
	if c == nil {return false}
	pane_header_cancel(w)
	key_suppress(w, e)
	option := confirmation_text(app, w, confirmation_shown(w), recount = false).option
	confirmation_outcome(app, w, ui.confirm_key(c, e, option))
	return true
}

confirmation_button :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) -> bool {
	c := confirmation_current(w)
	if c == nil {return false}
	outcome := ui.confirm_mouse(c, confirmation_layout(w, c), e.button, e.pressed, f32(e.x), f32(e.y))
	confirmation_outcome(app, w, outcome)
	return true
}

confirmation_hover :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {
	c := confirmation_current(w)
	if c == nil {return false}
	link_hover_clear(w)
	if ui.confirm_hover(c, confirmation_layout(w, c), x, y) {w.dirty = true}
	pointer_set(app, w, c.hover != .None ? .Hand : .Arrow)
	return true
}

// Capture loss cancels a press without dismissing the question or allowing a later release to fire.
confirmation_release :: proc(w: ^Window) {
	c := confirmation_shown(w)
	if c == nil {return}
	ui.armed_cancel(&c.dialog.armed)
	c.dialog.hover = .None
}

confirmation_active :: proc(w: ^Window) -> bool {
	c := confirmation_shown(w)
	return c != nil && (ui.presence_active(c.dialog.presence) || ui.control_active(c.dialog.hover_motion))
}

confirmation_advance :: proc(app: ^App, w: ^Window, now: time.Tick) {
	c := confirmation_shown(w)
	if c == nil {return}
	changed, settled := ui.presence_advance(&c.dialog.presence, app.animations, now)
	changed =
		ui.control_update(&c.dialog.hover_motion, c.dialog.hover != .None, false, app.animations, now) ||
		changed
	if changed || settled {w.dirty = true}
	if settled {confirmation_clear(w)}
}

// The words of the question shown. A close question that is still asking recounts what it closes
// when `recount` is set; reading the text for anything but drawing leaves the counts alone.
@(private)
confirmation_text :: proc(app: ^App, w: ^Window, c: ^Confirmation, recount: bool) -> Confirmation_Text {
	switch &subject in c.subject {
	case Pending_Close:
		counting := recount && ui.presence_is_open(c.dialog.presence)
		return pending_close_text(app, &subject, counting, w.workspace)
	case Pane_Swap:
		return pane_swap_text(subject)
	case Pending_File:
		return pending_file_text(subject)
	case Process_Remove:
		return editor_process_remove_text(subject)
	case Profile_Remove:
		return editor_profile_remove_text(subject)
	case Settings_Reset:
		return settings_reset_text()
	}
	return {}
}

confirmation_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	c := confirmation_shown(w)
	if c == nil || !ui.presence_visible(c.dialog.presence) {return .Ok}
	text := confirmation_text(app, w, c, recount = true)
	return ui.confirm_draw(
		&c.dialog, &w.list, &w.ui_text, app.theme, f32(w.width), f32(w.height), w.scale,
		text.title, text.body, text.label, text.note, text.option,
		ui.presence_fade(c.dialog.presence, ui.RISE_DIALOG * w.scale), w.pointer,
	)
}

when AIO_CONTROL {
	// The close, file and swap questions' keys. Each reads the question only while it is about that
	// key's subject.
	confirmation_state_report :: proc(r: ^State_Report, app: ^App, w: ^Window) {
		question := confirmation_shown(w)
		opacity := question != nil ? question.dialog.motion.value : 0
		closing := confirmation_subject(w, Pending_Close)
		close_open := confirmation_asking(w, Pending_Close) != nil
		confirm: Confirmation_Text
		close_workspace: u32
		if closing != nil {
			confirm = pending_close_text(app, closing, close_open, w.workspace)
			if target, ok := closing.target.(Close_Workspace); ok {close_workspace = target.workspace}
		}
		file := confirmation_subject(w, Pending_File)
		swap := confirmation_subject(w, Pane_Swap)
		state_value(r, "confirm.open", close_open)
		state_valuef(r, "confirm.opacity", "%g", closing != nil ? opacity : 0)
		state_text(r, "confirm.title", close_open ? confirm.title : "")
		state_text(r, "confirm.body", close_open ? confirm.body : "")
		state_value(r, "confirm.workspace", close_workspace)
		state_value(r, "file.open", confirmation_asking(w, Pending_File) != nil)
		state_text(r, "file.path", file != nil ? file.file.path : "")
		state_text(r, "file.target", file != nil ? file.file.target : "")
		state_value(r, "swap.open", confirmation_asking(w, Pane_Swap) != nil)
		state_valuef(r, "swap.opacity", "%g", swap != nil ? opacity : 0)
		state_text(r, "swap.profile", swap != nil ? swap.profile_id : "")
	}
}

// Confirmation pointer surface

@(private)
confirmation_claims :: proc(app: ^App, w: ^Window, x, y: f32) -> bool {return confirmation_current(w) != nil}

@(private)
confirmation_pointer_hover :: proc(
	app: ^App,
	w: ^Window,
	owner: Pointer_Target,
	e: input.Mouse_Move_Event,
) {
	if owner == .Confirmation {_ = confirmation_hover(app, w, f32(e.x), f32(e.y))}
}

@(private)
confirmation_press :: proc(app: ^App, w: ^Window, e: input.Mouse_Button_Event) {
	_ = confirmation_button(app, w, e)
}

@(private)
confirmation_pointer_cancel :: proc(_: ^App, w: ^Window) {
	confirmation_release(w)
}
