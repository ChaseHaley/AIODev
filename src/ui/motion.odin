package ui

import "aio:render"
import "core:time"

Easing :: enum {
	Linear,
	Decelerate,
	Accelerate,
}

// When the frame being built will be on screen; see render.Frame_Time.
Frame_Time :: render.Frame_Time

// A value easing from `from` to `target`. Motions are frame-locked: each is sampled at the display time
// of the frame that draws it, and starts one refresh before the first frame that moves it, so that
// frame already moves one step and the last lands exactly on the target. That first frame is never a
// resuming one (see render.Frame_Time), whose moment on screen is uncertain. `started` stays zero from
// motion_target until then.
Motion :: struct {
	from, value, target: f32,
	started:             time.Tick,
	duration:            time.Duration,
	easing:              Easing,
}

// How long a reordered list item takes to ease into its slot (D-069). Tabs, workspace rows and
// settings profile blocks share it so every reorderable list moves alike.
REORDER_DURATION :: 140 * time.Millisecond

// How long a control takes to light up or settle under hover and press.
@(private)
CONTROL_MOTION_DURATION :: 80 * time.Millisecond

motion_active :: proc(m: Motion) -> bool {return m.value != m.target}

// Samples the motion for `frame`; true when its value changed.
motion_update :: proc(m: ^Motion, frame: Frame_Time) -> bool {
	if !motion_active(m^) {return false}
	if m.started == {} {
		if frame.resuming {return false}
		m.started = time.tick_add(frame.display, -frame.period)
	}
	t := clamp(f32(time.tick_diff(m.started, frame.display)) / f32(m.duration), 0, 1)
	if t >= 1 {m.value = m.target; return true}
	m.value = m.from + (m.target - m.from) * ease(m.easing, t)
	return true
}

// Progress `t` in 0..1 along the easing curve. The curves are cubic-beziers through (0,0) and (1,1):
// decelerate (0.2, 0, 0, 1) and accelerate (0.4, 0, 1, 1).
ease :: proc(easing: Easing, t: f32) -> f32 {
	if easing == .Linear {return t}
	x1, x2 := easing == .Decelerate ? f32(0.2) : f32(0.4), easing == .Decelerate ? f32(0) : f32(1)
	u, lo, hi := t, f32(0), f32(1)
	for _ in 0 ..< 16 {
		u = (lo + hi) / 2
		x := 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
		if x < t {lo = u} else {hi = u}
	}
	return 3 * (1 - u) * u * u + u * u * u
}

// Retargets from the value last drawn; the motion starts with the next frame that samples it. Disabled
// animations land on the target at once.
motion_target :: proc(m: ^Motion, target: f32, duration: time.Duration, easing: Easing, enabled: bool) {
	if !enabled {m.value, m.target = target, target; return}
	if m.target == target {return}
	m.from, m.target, m.started, m.duration, m.easing = m.value, target, {}, duration, easing
}

// Applies `fade` to everything drawn since `mark`, so a surface's fade moves and dims only what it drew.
fade_draw :: proc(list: ^render.Draw_List, mark: render.Draw_Mark, fade: Fade) {
	for &layer in list.layers[mark.layers:] {layer.clip.y += fade.rise}
	for &rect in list.rects[mark.rects:] {rect.rect.y += fade.rise; rect.color.a *= fade.opacity}
	for &glyph in list.glyphs[mark.glyphs:] {glyph.rect.y += fade.rise; glyph.color.a *= fade.opacity}
}

Control_Motion :: struct {
	hover, press: Motion,
}

control_active :: proc(m: Control_Motion) -> bool {
	return motion_active(m.hover) || motion_active(m.press)
}

control_update :: proc(m: ^Control_Motion, hover, press, enabled: bool, frame: Frame_Time) -> bool {
	motion_target(&m.hover, hover ? 1 : 0, CONTROL_MOTION_DURATION, .Linear, enabled)
	motion_target(&m.press, press ? 1 : 0, CONTROL_MOTION_DURATION, .Linear, enabled)
	hover_changed := motion_update(&m.hover, frame)
	press_changed := motion_update(&m.press, frame)
	return hover_changed || press_changed
}
