package ui

import "core:time"

// The durations a surface takes to open and to finish closing.
Presence_Spec :: struct {
	open, close: time.Duration,
}

// A floating surface's open and close motion. advance reports the one step that ends a close, so
// the caller releases its payload exactly once.
Presence :: struct {
	open:        bool,
	release_due: bool,
	spec:        Presence_Spec,
	motion:      Motion,
}

presence_open :: proc(p: ^Presence, spec: Presence_Spec) {
	p.spec = spec
	p.open = true
	p.release_due = false
}

presence_close :: proc(p: ^Presence) {
	p.open = false
	p.release_due = true
}

// Drops the motion after the caller released the payload, returning the presence to closed.
presence_reset :: proc(p: ^Presence) {
	p.open = false
	p.release_due = false
	p.motion = {}
}

presence_visible :: proc(p: Presence) -> bool {
	return p.open || p.motion.value > 0
}

presence_active :: proc(p: Presence) -> bool {
	return motion_active(p.motion)
}

// settled is true on the single advance that finishes a close, so a caller that releases on it
// cannot release twice. Disabled animations snap to the target on that same advance.
presence_advance :: proc(p: ^Presence, enabled: bool, now: time.Tick) -> (changed, settled: bool) {
	if p.open {
		motion_target(&p.motion, 1, p.spec.open, .Decelerate, enabled, now)
	} else {
		motion_target(&p.motion, 0, p.spec.close, .Accelerate, enabled, now)
	}
	changed = motion_update(&p.motion, now)
	if p.open || !p.release_due || motion_active(p.motion) {
		return changed, false
	}
	p.release_due = false
	return changed, true
}

// The rise only happens while closing, so an opening or settled surface keeps its place.
presence_fade :: proc(p: Presence, rise: f32) -> (opacity, offset: f32) {
	return p.motion.value, p.open ? 0 : rise * (1 - p.motion.value)
}
