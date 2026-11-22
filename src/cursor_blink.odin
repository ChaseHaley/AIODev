package main

import "cosmos:host"
import "core:time"

// How long the cursor stays shown, and then hidden, while it blinks.
cursor_blink_interval :: proc(app: ^App) -> time.Duration {
	return time.Duration(app.settings.cursor.blink_interval) * time.Millisecond
}

// A window that does not draw, minimized or hidden, needs no blink, so it never wakes the loop for one.
cursor_blink_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	deadline, blinking := host.blink_deadline(w.cursor_blink)
	return deadline, blinking && window_drawable(w)
}

cursor_blink_tick :: proc(w: ^Window, now: time.Tick) {
	if host.blink_tick(&w.cursor_blink, now) {w.dirty = true}
}
