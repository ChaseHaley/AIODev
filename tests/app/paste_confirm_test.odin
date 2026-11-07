package app_test

import "core:testing"
import "core:time"
import app "../../src"

// An arm lasts exactly its wait: the tick that reaches its end returns the window to Idle.
@(test)
paste_confirm_arm_expires_with_its_wait :: proc(t: ^testing.T) {
	w: app.Window
	now := time.tick_now()
	until := time.tick_add(now, time.Second)
	w.paste_confirm = app.Paste_Armed{session = 1, until = until}
	app.paste_confirm_expire(&w, now)
	armed, ok := w.paste_confirm.(app.Paste_Armed)
	testing.expect(t, ok && armed.session == 1)
	app.paste_confirm_expire(&w, until)
	testing.expect(t, w.paste_confirm == nil)
}
