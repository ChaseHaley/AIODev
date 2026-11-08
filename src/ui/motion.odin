package ui

import "aio:render"
import "core:time"

Easing :: enum {
	Linear,
	Decelerate,
	Accelerate,
}
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

motion_update :: proc(m: ^Motion, now: time.Tick) -> bool {
	if !motion_active(m^) {return false}
	t := clamp(f32(time.tick_diff(m.started, now)) / f32(m.duration), 0, 1)
	if t >= 1 {m.value = m.target; return true}
	u := t
	if m.easing != .Linear {
		x1, x2 :=
			m.easing == .Decelerate ? f32(0.2) : f32(0.4),
			m.easing == .Decelerate ? f32(0) : f32(1)
		lo, hi := f32(0), f32(1)
		for _ in 0 ..< 16 {
			u = (lo + hi) / 2
			x := 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u
			if x < t {lo = u} else {hi = u}
		}
		u = 3 * (1 - u) * u * u + u * u * u
	}
	m.value = m.from + (m.target - m.from) * u
	return true
}

motion_target :: proc(
	m: ^Motion,
	target: f32,
	duration: time.Duration,
	easing: Easing,
	enabled: bool,
	now: time.Tick,
) {
	if enabled && m.target == target {return}
	motion_update(m, now)
	if !enabled {m.value, m.target = target, target; return}
	if m.target == target {return}
	m.from, m.target, m.started, m.duration, m.easing = m.value, target, now, duration, easing
}

// Where a surface's drawing starts in a draw list, so its fade moves and dims only what it drew.
Fade_Mark :: struct {
	layers, rects, glyphs: int,
}

fade_mark :: proc(list: ^render.Draw_List) -> Fade_Mark {
	return {len(list.layers), len(list.rects), len(list.glyphs)}
}

// Applies `fade` to everything drawn since `mark`.
fade_draw :: proc(list: ^render.Draw_List, mark: Fade_Mark, fade: Fade) {
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

control_update :: proc(m: ^Control_Motion, hover, press, enabled: bool, now: time.Tick) -> bool {
	motion_target(&m.hover, hover ? 1 : 0, CONTROL_MOTION_DURATION, .Linear, enabled, now)
	motion_target(&m.press, press ? 1 : 0, CONTROL_MOTION_DURATION, .Linear, enabled, now)
	hover_changed := motion_update(&m.hover, now)
	press_changed := motion_update(&m.press, now)
	return hover_changed || press_changed
}
