package term_view

import "aio:render"
import "core:math"

@(private)
Contrast_Entry :: struct {
	foreground, background, adjusted: render.Color,
	ratio:                            f32,
}

Contrast_Cache :: struct {
	entries: [128]Contrast_Entry,
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
luminance :: proc(color: render.Color) -> f32 {
	return 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
}

contrast_ratio :: proc(foreground, background: render.Color) -> f32 {
	fg, bg := foreground, background
	for i in 0 ..< 3 {
		fg[i] = linear_component(fg[i] * fg.a + bg[i] * (1 - fg.a))
		bg[i] = linear_component(bg[i])
	}
	a, b := luminance(fg), luminance(bg)
	return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

minimum_contrast :: proc(foreground, background: render.Color, ratio: f32) -> render.Color {
	if ratio <= 1 || contrast_ratio(foreground, background) >= ratio {return foreground}
	fg, bg := foreground, background
	for i in 0 ..< 3 {
		fg[i] = linear_component(fg[i] * fg.a + bg[i] * (1 - fg.a))
		bg[i] = linear_component(bg[i])
	}
	f, b := luminance(fg), luminance(bg)
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
	result := render.Color{0, 0, 0, 1}
	for i in 0 ..< 3 {result[i] = clamp(srgb_component(fg[i] + (target - fg[i]) * mix), 0, 1)}
	return result
}

@(private)
minimum_contrast_cached :: proc(
	cache: ^Contrast_Cache,
	foreground, background: render.Color,
	ratio: f32,
) -> render.Color {
	hash := u32(2166136261)
	for color in ([2]render.Color{foreground, background}) {
		for component in color {hash = (hash ~ u32(clamp(component, 0, 1) * 255)) * 16777619}
	}
	entry := &cache.entries[hash % u32(len(cache.entries))]
	if entry.ratio != ratio || entry.foreground != foreground || entry.background != background {
		entry^ = {foreground, background, minimum_contrast(foreground, background, ratio), ratio}
	}
	return entry.adjusted
}
