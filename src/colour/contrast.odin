package colour

import "core:math"

// A foreground composited over its background by the foreground's alpha, both in linear light,
// with their relative luminances.
@(private)
Linear_Pair :: struct {
	foreground, background: RGBA,
	foreground_luminance:   f32,
	background_luminance:   f32,
}

@(private)
linear_component :: proc(value: f32) -> f32 {
	return value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4)
}

@(private)
srgb_component :: proc(value: f32) -> f32 {
	return value <= 0.0031308 ? value * 12.92 : 1.055 * math.pow(value, 1 / f32(2.4)) - 0.055
}

@(private)
luminance :: proc(color: RGBA) -> f32 {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
}

@(private)
linear_pair :: proc(foreground, background: RGBA) -> Linear_Pair {
	fg, bg := foreground, background
	for i in 0 ..< 3 {
		fg[i] = linear_component(fg[i] * fg.a + bg[i] * (1 - fg.a))
		bg[i] = linear_component(bg[i])
	}
	return {fg, bg, luminance(fg), luminance(bg)}
}

@(private)
luminance_ratio :: proc(p: Linear_Pair) -> f32 {
	a, b := p.foreground_luminance, p.background_luminance
	return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

// contrast_ratio is the WCAG contrast ratio of `foreground`, composited by its alpha over the
// opaque `background`.
contrast_ratio :: proc(foreground, background: RGBA) -> f32 {
	return luminance_ratio(linear_pair(foreground, background))
}

// minimum_contrast returns `foreground` when it already reaches `ratio` against `background`, and
// otherwise the nearest opaque colour toward black or white that does. When neither extreme can
// reach `ratio`, it returns whichever extreme contrasts more.
minimum_contrast :: proc(foreground, background: RGBA, ratio: f32) -> RGBA {
	if ratio <= 1 {return foreground}
	p := linear_pair(foreground, background)
	if luminance_ratio(p) >= ratio {return foreground}
	fg := p.foreground
	f, b := p.foreground_luminance, p.background_luminance
	dark := (b + 0.05) / ratio - 0.05
	light := ratio * (b + 0.05) - 0.05
	black_mix := dark >= 0 ? clamp((f - dark) / max(f, 0.000001), 0, 1) : f32(2)
	white_mix := light <= 1 ? clamp((light - f) / max(1 - f, 0.000001), 0, 1) : f32(2)
	target := black_mix <= white_mix ? f32(0) : f32(1)
	mix := min(1, black_mix, white_mix)
	if black_mix > 1 && white_mix > 1 {
		target = b + 0.05 >= 1.05 / (b + 0.05) * 0.05 ? 0 : 1
		mix = 1
	}
	result := RGBA{0, 0, 0, 1}
	for i in 0 ..< 3 {result[i] = clamp(srgb_component(fg[i] + (target - fg[i]) * mix), 0, 1)}
	return result
}
