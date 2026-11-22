package app_test

import "core:testing"
import "core:time"
import app "../../src"
import "cosmos:ui"

// The arm holds exactly while its Paste notice shows: a pointer resting on the paused notice keeps the
// confirmation it offers, and the notice running out ends it.
@(test)
paste_confirm_holds_while_its_notice_shows :: proc(t: ^testing.T) {
	s: app.App
	ui.notices_init(&s.notices)
	defer ui.notices_destroy(&s.notices)
	w: app.Window
	testing.expect(t, !app.paste_confirm_pending(&s, &w, 1), "nothing is armed")
	app.paste_confirm_arm(&s, &w, 1)
	testing.expect(t, app.paste_confirm_pending(&s, &w, 1))
	testing.expect(t, !app.paste_confirm_pending(&s, &w, 2), "another pane's paste does not confirm")
	now := time.tick_now()
	testing.expect(t, ui.notices_pointer_over(&s.notices, true, now, false))
	testing.expect(t, !ui.notices_expire(&s.notices, false, time.tick_add(now, time.Minute)))
	testing.expect(t, app.paste_confirm_pending(&s, &w, 1), "the paused notice keeps the arm")
	testing.expect(t, ui.notices_pointer_over(&s.notices, false, time.tick_add(now, time.Minute), false))
	testing.expect(t, ui.notices_expire(&s.notices, false, time.tick_add(now, time.Minute + 11*time.Second)))
	testing.expect(t, !app.paste_confirm_pending(&s, &w, 1), "the notice running out ends the arm")
}
