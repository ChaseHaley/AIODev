package ui

import "core:time"

// The durations a surface takes to open and to finish closing.
Presence_Spec :: struct {
	open, close: time.Duration,
}

// A floating surface's open intent, closing motion and release bookkeeping. The surface is
// visible from the moment it opens until its closing motion settles, and advance reports that
// settle exactly once so the caller can release the payload behind it.
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

// Steps the opening or closing motion. settled is true on the single advance that finishes a
// close, so a caller that releases on it cannot release twice. Disabled animations snap the
// motion to its target, which makes that advance the same one that closes the surface.
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

// The opacity and upward offset a surface applies to the content drawn during this frame. The
// rise only happens while closing, so an opening or settled-open surface keeps its place.
presence_fade :: proc(p: Presence, rise: f32) -> (opacity, offset: f32) {
	return p.motion.value, p.open ? 0 : rise * (1 - p.motion.value)
}
