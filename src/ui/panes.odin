package ui

import "aio:render"
import "core:math"

pane_gap :: proc(gap, scale: f32) -> f32 {return max(1, math.round(gap * scale))}

pane_area :: proc(width, height, chrome_height, gap, scale: f32) -> render.Rect {
	inset := math.round(gap * scale)
	return {
		inset,
		chrome_height + inset,
		max(0, width - 2 * inset),
		max(0, height - chrome_height - 2 * inset),
	}
}
