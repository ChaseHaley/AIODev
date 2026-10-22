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

fade_draw :: proc(
	list: ^render.Draw_List,
	layer_start, rect_start, glyph_start: int,
	opacity, rise: f32,
) {
	for &layer in list.layers[layer_start:] {layer.clip.y += rise}
	for &rect in list.rects[rect_start:] {rect.rect.y += rise; rect.color.a *= opacity}
	for &glyph in list.glyphs[glyph_start:] {glyph.rect.y += rise; glyph.color.a *= opacity}
}

Control_Motion :: struct {
	hover, press: Motion,
}

control_active :: proc(m: Control_Motion) -> bool {
	return motion_active(m.hover) || motion_active(m.press)
}

control_update :: proc(m: ^Control_Motion, hover, press, enabled: bool, now: time.Tick) -> bool {
	motion_target(&m.hover, hover ? 1 : 0, 80 * time.Millisecond, .Linear, enabled, now)
	motion_target(&m.press, press ? 1 : 0, 80 * time.Millisecond, .Linear, enabled, now)
	hover_changed := motion_update(&m.hover, now)
	press_changed := motion_update(&m.press, now)
	return hover_changed || press_changed
}
