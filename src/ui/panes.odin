package ui

import "aio:render"
import "core:math"

pane_gap :: proc(gap, scale: f32) -> f32 {return max(1, math.round(gap * scale))}

pane_area :: proc(width, height, tab_height, gap, scale: f32) -> render.Rect {
	inset := math.round(gap * scale)
	return {
		inset,
		tab_height + inset,
		max(0, width - 2 * inset),
		max(0, height - tab_height - 2 * inset),
	}
}
