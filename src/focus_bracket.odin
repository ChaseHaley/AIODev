package main

import "aio:layout"
import "aio:term"
import "aio:ui"

// Which pane holds a window's focus. Entered names the pane whose terminal hears the window's focus
// reports and whose finished work counts as seen; nil is Left, the gap while the window changes what
// it shows, after the old pane heard its focus-out and before any pane hears a focus-in. The procs in
// this file are the only writers.
Focus_Bracket :: union {
	Focus_Entered,
}

Focus_Entered :: struct {
	content: layout.Content,
}

// A new window holds the pane it opens on. Nothing is reported: the window has no focus yet, and
// whatever the pane heard last came from the window or pane it was shown in before.
focus_init :: proc(w: ^Window) {
	content, shown := focus_shown(w)
	w.focus_bracket = shown ? Focus_Entered{content} : nil
}

// Takes focus from the entered pane before the window changes what it shows: the pane hears a
// focus-out, and the window drops everything that belonged to it. A window that has left already
// stays as it is, so a second leave reports nothing twice.
focus_leave :: proc(app: ^App, w: ^Window) {
	entered, ok := w.focus_bracket.(Focus_Entered)
	if !ok {return}
	w.focus_bracket = nil
	theme_delete_disarm(&w.resources)
	window_overlays_cancel(app, w)
	entry := workspace_session_for_content(app, entered.content)
	if entry != nil {status_focus_leave(app, entry)}
	leader_cancel(w)
	if entry != nil {term.send_focus(entry.session, false)}
	if ui.find_is_open(&w.find) {
		target: Find_Target
		if entered.content.kind == .Markdown {
			if pane := markdown_find(app, entered.content.id); pane != nil {target = pane}
		} else if entry != nil {
			target = entry
		}
		if target != nil {find_close(app, w, target)}
	}
	selection_cancel(w)
	divider_cancel(w)
	w.wheel_remainder = 0
	paste_confirm_cancel(app, w)
}

// Gives focus to the pane the window now shows, leaving first a different pane that still holds it.
// The pane that holds it already hears nothing again; the window is refreshed either way.
focus_enter :: proc(app: ^App, w: ^Window) {
	content, shown := focus_shown(w)
	if entered, ok := w.focus_bracket.(Focus_Entered); ok && (!shown || entered.content != content) {
		focus_leave(app, w)
	}
	if shown && w.focus_bracket == nil {
		w.focus_bracket = Focus_Entered{content}
		if entry := workspace_session_for_content(app, content); entry != nil {
			term.send_focus(entry.session, w.focused)
		}
	}
	cursor_blink_reset(w)
	status_focus_enter(app, w)
	w.dirty = true
	window_update_title(app, w)
}

// The session of the entered pane, which hears the window gain and lose focus. Nil while the window
// has left its pane, whose replacement reports the window's focus as it enters.
focus_session :: proc(app: ^App, w: ^Window) -> ^Session_Entry {
	entered, ok := w.focus_bracket.(Focus_Entered)
	return ok ? workspace_session_for_content(app, entered.content) : nil
}

@(private = "file")
focus_shown :: proc(w: ^Window) -> (layout.Content, bool) {
	if w.tree == nil || w.tree.focus == layout.INVALID_NODE {return {}, false}
	pane, is_pane := w.tree.nodes[w.tree.focus].(layout.Pane)
	return pane.content, is_pane
}
