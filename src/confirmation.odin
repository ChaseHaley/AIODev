package main

import "aio:glyphs"
import "aio:platform"
import "aio:ui"
import "core:time"

// The subjects retain their payload and acceptance policy. Event, motion and frame callers
// only know this owner, including while a dismissed question finishes fading out.
@(private)
confirmation_subjects :: proc(w: ^Window) -> [3]^ui.Confirm {
	return {&w.pending_close.confirm, &w.pending_swap.confirm, &w.pending_file.confirm}
}

confirmation_current :: proc(w: ^Window) -> ^ui.Confirm {
	for c in confirmation_subjects(w) {if c.open {return c}}
	return nil
}

@(private)
confirmation_layout :: proc(w: ^Window, c: ^ui.Confirm) -> ui.Confirm_Layout {
	return ui.confirm_layout(f32(w.width), f32(w.height), w.scale, c.extended, c.show_option)
}

@(private)
confirmation_outcome :: proc(app: ^App, w: ^Window, c: ^ui.Confirm, outcome: ui.Confirm_Outcome) {
	switch outcome {
	case .None:
	case .Changed:
		w.dirty = true
	case .Accept, .Cancel:
		// Acceptance may retire w. Nothing after the subject's completion may inspect it.
		if c == &w.pending_close.confirm {pending_close_finish(app, w, outcome == .Accept)}
		else if c == &w.pending_swap.confirm {pane_swap_finish(app, w, outcome == .Accept)}
		else {pending_file_finish(app, w, outcome == .Accept)}
	}
}

confirmation_key :: proc(app: ^App, w: ^Window, e: platform.Key_Event) -> bool {
	c := confirmation_current(w)
	if c == nil {return false}
	pane_header_cancel(w)
	if e.pressed {w.suppressed_key = e}
	confirmation_outcome(app, w, c, ui.confirm_key(c, e))
	return true
}

confirmation_button :: proc(app: ^App, w: ^Window, e: platform.Mouse_Button_Event) -> bool {
	c := confirmation_current(w)
	if c == nil {return false}
	outcome := ui.confirm_mouse(c, confirmation_layout(w, c), e.button, e.pressed, f32(e.x), f32(e.y))
	confirmation_outcome(app, w, c, outcome)
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
	for c in confirmation_subjects(w) {
		ui.armed_cancel(&c.armed)
		c.hover = .None
	}
}

confirmation_clear :: proc(w: ^Window) {
	pending_close_clear(&w.pending_close)
	pane_swap_clear(&w.pending_swap)
	pending_file_clear(&w.pending_file)
}

confirmation_cancel :: proc(app: ^App, w: ^Window) {
	if w.pending_close.confirm.open {pending_close_finish(app, w, false)}
	if w.pending_swap.confirm.open {pane_swap_finish(app, w, false)}
	if w.pending_file.confirm.open {pending_file_finish(app, w, false)}
	// Close navigation drops its recorded subject immediately; shell switching keeps its
	// existing fade-out policy and releases the cached profile when that fade settles.
	pending_close_clear(&w.pending_close)
}

confirmation_active :: proc(w: ^Window) -> bool {
	for c in confirmation_subjects(w) {
		if c.open && c.motion.value != 1 || c.release_due || ui.presence_active(c.presence) ||
		   ui.control_active(c.hover_motion) {return true}
	}
	return false
}

confirmation_advance :: proc(app: ^App, w: ^Window, now: time.Tick) {
	for c in confirmation_subjects(w) {
		changed, settled := ui.presence_advance(&c.presence, app.animations, now)
		changed = ui.control_update(&c.hover_motion, c.hover != .None, false, app.animations, now) || changed
		if changed || settled {w.dirty = true}
		if settled {
			if c == &w.pending_close.confirm {pending_close_clear(&w.pending_close)}
			else if c == &w.pending_swap.confirm {pane_swap_clear(&w.pending_swap)}
			else {pending_file_clear(&w.pending_file)}
		}
	}
}

confirmation_draw :: proc(app: ^App, w: ^Window) -> glyphs.Result {
	for c in confirmation_subjects(w) {
		if !ui.presence_visible(c.presence) {continue}
		content: Pending_Close_Text
		option: string
		if c == &w.pending_close.confirm {
			content = pending_close_text(app, &w.pending_close, w.workspace)
		} else if c == &w.pending_file.confirm {
			content = pending_file_text(&w.pending_file)
		} else {
			content.title, content.body, content.note, content.label = pane_swap_text(&w.pending_swap)
			option = "Don't ask again"
		}
		layers, rects, glyph_count := len(w.list.layers), len(w.list.rects), len(w.list.glyphs)
		result := ui.confirm_draw(
			c, &w.list, &w.ui_text, app.theme, f32(w.width), f32(w.height), w.scale,
			content.title, content.body, content.label, content.note, option, w.pointer,
		)
		opacity, rise := ui.presence_fade(c.presence, 4 * w.scale)
		ui.fade_draw(&w.list, layers, rects, glyph_count, opacity, rise)
		if result != .Ok {return result}
	}
	return .Ok
}
