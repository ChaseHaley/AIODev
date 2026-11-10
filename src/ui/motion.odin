package ui

import "aio:render"
import "aio:settings"
import "core:time"

// Shorthand for the curves fixed motions use; user-customizable motions take a settings.Motion_Curve.
Easing :: enum {
	Linear,
	Decelerate,
	Accelerate,
}

// The builtin settings curves of the same names, so a fixed motion eases as its customizable namesake.
EASING_CURVES :: [Easing]settings.Motion_Curve {
	.Linear     = {p = {0, 0, 1, 1}},
	.Decelerate = {p = {0.2, 0, 0, 1}},
	.Accelerate = {p = {0.4, 0, 1, 1}},
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
	curve:               settings.Motion_Curve,
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
	m.value = m.from + (m.target - m.from) * settings.motion_curve_ease(m.curve, t)
	return true
}

// Retargets from the value last drawn; the motion starts with the next frame that samples it. Disabled
// animations land on the target at once.
motion_target :: proc(m: ^Motion, target: f32, duration: time.Duration, easing: Easing, enabled: bool) {
	@(static, rodata)
	curves := EASING_CURVES
	motion_target_curve(m, target, duration, curves[easing], enabled)
}

// As motion_target, along a curve of the user's motion settings.
motion_target_curve :: proc(
	m: ^Motion,
	target: f32,
	duration: time.Duration,
	curve: settings.Motion_Curve,
	enabled: bool,
) {
	if !enabled {m.value, m.target = target, target; return}
	if m.target == target {return}
	m.from, m.target, m.started, m.duration, m.curve = m.value, target, {}, duration, curve
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
