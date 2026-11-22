package main

import "cosmos:platform"
import "aio:term"
import "core:time"
import "cosmos:ui"

// The text names the duration: change both together.
@(private)
PASTE_CONFIRM_DURATION :: 10 * time.Second
@(private)
PASTE_CONFIRM_TEXT ::
	"The clipboard text has line breaks, so the shell will run each line as a command. " +
	"Paste again within 10 seconds to confirm."

// A multiline paste waiting to be confirmed; nil is Idle. Armed names the pane's session, so only a
// second paste into that pane counts as the confirmation. The Paste notice is the wait: arming puts it,
// cancelling clears it, and the arm holds while the notice shows. The pointer over the notices pauses
// their countdowns, so it holds the wait too, and the notice never offers a confirmation that has
// lapsed. The procs below are the only writers.
Paste_Confirm :: union {
	Paste_Armed,
}

Paste_Armed :: struct {
	session: u32,
}

// Pastes into the shell. Text the shell would run line by line waits for a second paste into the
// same pane while the Paste notice shows.
paste_clipboard :: proc(app: ^App, w: ^Window, entry: ^Session_Entry) {
	text, ok := platform.clipboard_get_text(&app.platform, context.temp_allocator)
	if !ok || len(text) == 0 {
		return
	}
	if entry.status != .Running {
		notify(app, .Error, "Could not paste: the shell is not running.")
		return
	}
	confirmed :=
		.Multiline_Paste not_in app.settings.interface.confirm || paste_confirm_pending(app, w, entry.id)
	switch term.paste(entry.session, text, confirmed) {
	case .Sent:
		paste_confirm_cancel(app, w)
	case .Unsafe:
		paste_confirm_arm(app, w, entry.id)
	case .Failed:
		notify(app, .Error, "Could not paste: the shell is not accepting input.")
	}
}

// Waits for a second paste into `session`, showing the Paste notice for the wait.
paste_confirm_arm :: proc(app: ^App, w: ^Window, session: u32) {
	w.paste_confirm = Paste_Armed{session}
	ui.notices_put(
		&app.notices,
		u32(Notice_Key.Paste),
		.Warning,
		PASTE_CONFIRM_TEXT,
		PASTE_CONFIRM_DURATION,
		app.animations,
		clock_now(&app.clock),
	)
	mark_all_dirty(app)
}

paste_confirm_cancel :: proc(app: ^App, w: ^Window) {
	if w.paste_confirm == nil {
		return
	}
	w.paste_confirm = nil
	ui.notices_clear(&app.notices, u32(Notice_Key.Paste), app.animations)
	mark_all_dirty(app)
}

// Whether a second paste into `session` confirms: its arm is set and the Paste notice still shows.
paste_confirm_pending :: proc(app: ^App, w: ^Window, session: u32) -> bool {
	armed, ok := w.paste_confirm.(Paste_Armed)
	return ok && armed.session == session && ui.notices_showing(&app.notices, u32(Notice_Key.Paste))
}
