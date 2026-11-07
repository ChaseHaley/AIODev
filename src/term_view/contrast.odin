package term_view

import "aio:colour"
import "aio:render"

@(private)
Contrast_Entry :: struct {
	foreground, background, adjusted: render.Color,
	ratio:                            f32,
}

Contrast_Cache :: struct {
	entries: [128]Contrast_Entry,
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
		entry^ = {foreground, background, colour.minimum_contrast(foreground, background, ratio), ratio}
	}
	return entry.adjusted
}
