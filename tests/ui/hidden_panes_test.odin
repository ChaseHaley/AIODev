package ui_test

import "core:math"
import "core:testing"
import "aio:render"
import "aio:ui"

// The map's cards share one scale with the tab (D-089): inside its padding the map has the tiled area's
// shape, 340 DIP wide while the window has room, and narrower, still in shape, when it has not.
@(test)
hidden_panes_map_takes_the_tiled_area_shape :: proc(t: ^testing.T) {
	scale := f32(1.5)
	pad := ui.SPACE_2 * scale
	glyph := render.Rect{900, 40, 28 * scale, 24 * scale}
	inner :: proc(r: render.Rect, pad: f32) -> [2]f32 {return {r.width - 2 * pad, r.height - 2 * pad}}
	for area in ([?][2]f32{{1600, 900}, {700, 1000}, {1200, 1200}}) {
		r := ui.hidden_panes_map_rect(glyph, area, 2000, 2000, scale)
		size := inner(r, pad)
		testing.expectf(t, math.abs(r.width - 340 * scale) < 0.01, "%v: the map is 340 DIP wide", area)
		testing.expectf(t, math.abs(size.y / size.x - area.y / area.x) < 0.001, "%v: the map keeps its shape", area)
	}
	// A short window: the map fits under the glyph and keeps the shape by narrowing.
	r := ui.hidden_panes_map_rect(glyph, {700, 1000}, 2000, 400, scale)
	size := inner(r, pad)
	testing.expect(t, r.y + r.height <= 400 - ui.SPACE_1 * scale + 0.01, "the map stays inside the window")
	testing.expect(t, r.width < 340 * scale, "the map narrows")
	testing.expect(t, math.abs(size.y / size.x - 1000.0 / 700.0) < 0.001, "the narrowed map keeps its shape")
}
