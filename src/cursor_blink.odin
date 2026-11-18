package main

import "core:time"

// The focused cursor's blink; nil is Off, a steady cursor. On shows the cursor while `visible` and
// flips it when `deadline` passes, `interval` later each time. The procs in this file are the only
// writers.
Cursor_Blink :: union {
	Cursor_Blink_On,
}

Cursor_Blink_On :: struct {
	visible:  bool,
	deadline: time.Tick,
	interval: time.Duration,
}

// How long the cursor stays shown, and then hidden, while it blinks.
cursor_blink_interval :: proc(app: ^App) -> time.Duration {
	return time.Duration(app.settings.cursor.blink_interval) * time.Millisecond
}

// Whether the focused cursor is in its shown phase.
cursor_visible :: proc(w: ^Window) -> bool {
	on, blinking := w.cursor_blink.(Cursor_Blink_On)
	return !blinking || on.visible
}

// A window that does not draw, minimized or hidden, needs no blink, so it never wakes the loop for one.
cursor_blink_deadline :: proc(w: ^Window) -> (time.Tick, bool) {
	on, blinking := w.cursor_blink.(Cursor_Blink_On)
	return on.deadline, blinking && window_drawable(w)
}

// The frame just built found whether the focused cursor blinks; a change starts or stops the cycle,
// and `interval` is the cursor.blink_interval setting. Drawing reports the fact because only the
// captured render state knows it.
cursor_blink_observe :: proc(w: ^Window, blinking: bool, interval: time.Duration, now: time.Tick) {
	if !blinking {
		w.cursor_blink = nil
		return
	}
	if on, running := &w.cursor_blink.(Cursor_Blink_On); running {
		on.interval = interval
		return
	}
	w.cursor_blink = Cursor_Blink_On{true, time.tick_add(now, interval), interval}
}

cursor_blink_tick :: proc(w: ^Window, now: time.Tick) {
	on, blinking := &w.cursor_blink.(Cursor_Blink_On)
	if !blinking || time.tick_diff(on.deadline, now) < 0 {return}
	on.visible = !on.visible
	on.deadline = time.tick_add(now, on.interval)
	w.dirty = true
}

// Restarts the cycle with the cursor shown, so typing never hides the cursor.
cursor_blink_reset :: proc(w: ^Window, now: time.Tick) {
	if on, blinking := &w.cursor_blink.(Cursor_Blink_On); blinking {
		on.visible, on.deadline = true, time.tick_add(now, on.interval)
	}
}

// A hidden linked window drops its cycle, so it shows its cursor when it comes back.
cursor_blink_stop :: proc(w: ^Window) {
	w.cursor_blink = nil
}
