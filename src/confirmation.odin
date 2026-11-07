package main

import "aio:input"
import "aio:localpath"
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

// Asks about `subject`, which the window now owns, presenting it as stated. A question still closing is
// released at once; a caller rewriting an asking question in place has taken what it keeps from it. The
// caller has closed the surfaces the question replaces, and cancelled any pointer gesture that asked it.
confirmation_open :: proc(
	w: ^Window,
	subject: Confirmation_Subject,
	extended := false,
	focus := ui.Confirm_Button.Accept,
	show_option := false,
) {
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
		localpath.open_file_destroy(&subject.file)
	case Process_Remove:
		delete(subject.name)
		delete(subject.source)
	case Profile_Remove:
		delete(subject.id)
	case Settings_Reset:
		delete(subject.source)
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
	confirmation_outcome(app, w, ui.confirm_key(c, e))
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

confirmation_draw :: proc(app: ^App, w: ^Window) -> render.Build_Status {
	c := confirmation_shown(w)
	if c == nil || !ui.presence_visible(c.dialog.presence) {return .Ok}
	text: Confirmation_Text
	switch &subject in c.subject {
	case Pending_Close:
		text = pending_close_text(app, &subject, ui.presence_is_open(c.dialog.presence), w.workspace)
	case Pane_Swap:
		text = pane_swap_text(subject)
	case Pending_File:
		text = pending_file_text(subject)
	case Process_Remove:
		text = editor_process_remove_text(subject)
	case Profile_Remove:
		text = editor_profile_remove_text(app, subject.id)
	case Settings_Reset:
		text = settings_reset_text()
	}
	layers, rects, glyph_count := len(w.list.layers), len(w.list.rects), len(w.list.glyphs)
	result := ui.confirm_draw(
		&c.dialog, &w.list, &w.ui_text, app.theme, f32(w.width), f32(w.height), w.scale,
		text.title, text.body, text.label, text.note, text.option, w.pointer,
	)
	opacity, rise := ui.presence_fade(c.dialog.presence, 4 * w.scale)
	ui.fade_draw(&w.list, layers, rects, glyph_count, opacity, rise)
	return result
}
