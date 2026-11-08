package ui

import "core:time"

// The durations a surface takes to open and to finish closing.
Presence_Spec :: struct {
	open, close: time.Duration,
}

// Surfaces centred over a scrim, the command palette and confirmations, open and close alike, and
// sink RISE_DIALOG as they fade.
DIALOG_PRESENCE :: Presence_Spec {
	open  = 120 * time.Millisecond,
	close = 90 * time.Millisecond,
}

// Where a floating surface is in its open and close motion. The procs in this file are the only
// writers, so the motion always means what the phase says: rising to 1 while Opening, held at 1
// when Open, falling to 0 while Closing and at rest at 0 when Closed.
Presence_Phase :: enum u8 {
	// The zero value, so a surface built as a plain value is closed with nothing to release.
	Closed,
	Opening,
	Open,
	Closing,
	// Nothing remains to draw, but the caller still holds its payload until the next advance.
	Release_Due,
}

Presence :: struct {
	phase:  Presence_Phase,
	spec:   Presence_Spec,
	motion: Motion,
}

// Opening a surface that is still closing reverses its fade from where it is and keeps the
// caller's payload, since the close never settled.
presence_open :: proc(p: ^Presence, spec: Presence_Spec) {
	p.spec = spec
	if p.phase != .Open {p.phase = .Opening}
}

// Closing always owes the caller one settle, even from Closed, so a caller can rely on its
// release running exactly once after every close.
presence_close :: proc(p: ^Presence) {
	p.phase = p.motion.value == 0 && !motion_active(p.motion) ? .Release_Due : .Closing
}

// A surface that is already fully shown, ready to close from its open state.
presence_shown :: proc(spec: Presence_Spec) -> Presence {
	return {phase = .Open, spec = spec, motion = {value = 1, target = 1}}
}

// Drops the motion after the caller released the payload, returning the presence to closed.
presence_reset :: proc(p: ^Presence) {
	p^ = {spec = p.spec}
}

// Opening or open: the surface takes input.
presence_is_open :: proc(p: Presence) -> bool {
	return p.phase == .Opening || p.phase == .Open
}

presence_visible :: proc(p: Presence) -> bool {
	return presence_is_open(p) || p.motion.value > 0
}

// Still owes an advance: a motion in flight, or a change of phase it has not reached yet.
presence_active :: proc(p: Presence) -> bool {
	return p.phase == .Opening || p.phase == .Closing || p.phase == .Release_Due
}

// settled is true on the single advance that finishes a close, so a caller that releases on it
// cannot release twice. Disabled animations snap to the target on that same advance.
presence_advance :: proc(p: ^Presence, enabled: bool, frame: Frame_Time) -> (changed, settled: bool) {
	switch p.phase {
	case .Closed, .Open:
		return false, false
	case .Release_Due:
		presence_reset(p)
		return false, true
	case .Opening:
		motion_target(&p.motion, 1, p.spec.open, .Decelerate, enabled)
	case .Closing:
		motion_target(&p.motion, 0, p.spec.close, .Accelerate, enabled)
	}
	changed = motion_update(&p.motion, frame)
	if motion_active(p.motion) {return changed, false}
	if p.phase == .Opening {
		p.phase = .Open
		return changed, false
	}
	p.phase = .Closed
	return changed, true
}

// How a surface looks at this point of its presence: its opacity and how far it has sunk.
Fade :: struct {
	opacity, rise: f32,
}

FADE_NONE :: Fade{opacity = 1}

// `rise` is the surface's full sink distance (RISE_DIALOG or RISE_NOTICE times the scale). The rise
// only happens while closing, so an opening or settled surface keeps its place.
presence_fade :: proc(p: Presence, rise: f32) -> Fade {
	return {p.motion.value, presence_is_open(p) ? 0 : rise * (1 - p.motion.value)}
}
