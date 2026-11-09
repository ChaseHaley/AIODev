package main

import "core:time"

@(private)
CURSOR_BLINK_INTERVAL :: 530 * time.Millisecond

// The focused cursor's blink; nil is Off, a steady cursor. On shows the cursor while `visible` and
// flips it when `deadline` passes. The procs in this file are the only writers.
Cursor_Blink :: union {
	Cursor_Blink_On,
}

Cursor_Blink_On :: struct {
	visible:  bool,
	deadline: time.Tick,
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

// The frame just built found whether the focused cursor blinks; a change starts or stops the cycle.
// Drawing reports the fact because only the captured render state knows it.
cursor_blink_observe :: proc(w: ^Window, blinking: bool, now: time.Tick) {
	if blinking == (w.cursor_blink != nil) {return}
	if !blinking {
		w.cursor_blink = nil
		return
	}
	w.cursor_blink = Cursor_Blink_On{true, time.tick_add(now, CURSOR_BLINK_INTERVAL)}
}

cursor_blink_tick :: proc(w: ^Window, now: time.Tick) {
	on, blinking := &w.cursor_blink.(Cursor_Blink_On)
	if !blinking || time.tick_diff(on.deadline, now) < 0 {return}
	on.visible = !on.visible
	on.deadline = time.tick_add(now, CURSOR_BLINK_INTERVAL)
	w.dirty = true
}

// Restarts the cycle with the cursor shown, so typing never hides the cursor.
cursor_blink_reset :: proc(w: ^Window, now: time.Tick) {
	if on, blinking := &w.cursor_blink.(Cursor_Blink_On); blinking {
		on^ = {true, time.tick_add(now, CURSOR_BLINK_INTERVAL)}
	}
}

// A hidden linked window drops its cycle, so it shows its cursor when it comes back.
cursor_blink_stop :: proc(w: ^Window) {
	w.cursor_blink = nil
}
