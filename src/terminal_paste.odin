package main

import "aio:platform"
import "aio:term"
import "aio:ui"
import "core:time"

// The text names the duration: change both together.
@(private)
PASTE_CONFIRM_DURATION :: 10 * time.Second
@(private)
PASTE_CONFIRM_TEXT ::
	"The clipboard text has line breaks, so the shell will run each line as a command. " +
	"Paste again within 10 seconds to confirm."

// A multiline paste waiting to be confirmed; nil is Idle. Armed names the pane's session, so only a
// second paste into that pane within the wait counts as the confirmation. The Paste notice shows the
// wait: arming puts it, cancelling clears it, and it expires with the arm. The procs below are the
// only writers.
Paste_Confirm :: union {
	Paste_Armed,
}

Paste_Armed :: struct {
	session: u32,
	until:   time.Tick,
}

// Pastes into the shell. Text the shell would run line by line waits for a second paste into the
// same pane within PASTE_CONFIRM_DURATION.
paste_clipboard :: proc(app: ^App, w: ^Window, entry: ^Session_Entry) {
	text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
	if !ok || len(text) == 0 {
		return
	}
	if entry.status != .Running {
		notify(app, .Error, "Could not paste: the shell is not running.")
		return
	}
	now := time.tick_now()
	armed, is_armed := w.paste_confirm.(Paste_Armed)
	confirmed :=
		!app.settings.terminal.confirm_multiline_paste ||
		(is_armed && armed.session == entry.id && time.tick_diff(now, armed.until) > 0)
	switch term.paste(entry.session, text, confirmed) {
	case .Sent:
		paste_confirm_cancel(app, w)
	case .Unsafe:
		// The notice expires no earlier than the arm, so its wake-up finds the arm already over.
		w.paste_confirm = Paste_Armed{entry.id, time.tick_add(now, PASTE_CONFIRM_DURATION)}
		ui.notices_put(
			&app.notices,
			u32(Notice_Key.Paste),
			.Warning,
			PASTE_CONFIRM_TEXT,
			PASTE_CONFIRM_DURATION,
		)
		mark_all_dirty(app)
	case .Failed:
		notify(app, .Error, "Could not paste: the shell is not accepting input.")
	}
}

paste_confirm_cancel :: proc(app: ^App, w: ^Window) {
	if w.paste_confirm == nil {
		return
	}
	w.paste_confirm = nil
	ui.notices_clear(&app.notices, u32(Notice_Key.Paste))
	mark_all_dirty(app)
}

// Ends an arm whose wait ran out. Its notice expires by itself.
paste_confirm_expire :: proc(w: ^Window, now: time.Tick) {
	if armed, ok := w.paste_confirm.(Paste_Armed); ok && time.tick_diff(now, armed.until) <= 0 {
		w.paste_confirm = nil
	}
}

paste_confirm_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	armed, ok := w.paste_confirm.(Paste_Armed)
	return armed.until, ok
}
