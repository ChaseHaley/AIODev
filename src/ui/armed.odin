package ui

// Armed tracks one pointer activation: a press arms exactly one target and only a
// release over that same target fires it. A release over any other target, capture
// loss, focus loss or cancellation disarms without firing. Callers keep their hit
// testing, focus, capture and drawing policy, and decide which target means no target.
Armed :: struct($T: typeid) {
	target: T,
	down:   bool,
}

// armed_press arms `target` and reports whether the activation state changed.
armed_press :: proc(a: ^Armed($T), target: T) -> (changed: bool) {
	changed = !a.down || a.target != target
	a.target, a.down = target, true
	return
}

// armed_release disarms and reports the armed target only when the release lands on it.
armed_release :: proc(a: ^Armed($T), target: T) -> (fired: T, ok: bool) {
	if a.down && a.target == target {
		fired, ok = a.target, true
	}
	a.target, a.down = {}, false
	return
}

// armed_cancel disarms without firing and reports whether a press was outstanding.
armed_cancel :: proc(a: ^Armed($T)) -> (changed: bool) {
	changed = a.down
	a.target, a.down = {}, false
	return
}

// armed_down reports whether a press is outstanding, including one that armed no target.
armed_down :: proc(a: Armed($T)) -> bool {return a.down}

// armed_target returns the target the outstanding press armed.
armed_target :: proc(a: Armed($T)) -> T {return a.target}

// armed_is reports whether `target` is armed by an outstanding press.
armed_is :: proc(a: Armed($T), target: T) -> bool {return a.down && a.target == target}
