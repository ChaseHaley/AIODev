package ui

import "cosmos:render"
import "core:math"
import "core:time"

// One loop of the Working spinner. Every surface that spins, notices included, times it by this.
SPINNER_PERIOD :: 2360 * time.Millisecond
// The phase a spinner holds with animations off: two lines drawn and the third on its way, so the
// still mark reads as a constellation rather than four loose stars.
SPINNER_STILL :: f32(0.55)

// The constellation's four stars on a 12 by 12 grid, joined in order by the spinner's lines.
@(private)
SPINNER_STARS :: [4][2]f32{{2.10, 8.18}, {4.33, 3.82}, {7.26, 7.27}, {9.86, 3.86}}

// The Working spinner in `ink`, filling the square `r`: four fixed stars that a line joins one at a
// time, each star flashing as the line reaches it, then the lines fade together and the loop starts
// again from the first star. `phase` in [0, 1) is the place in the loop.
spinner_draw :: proc(list: ^render.Draw_List, r: render.Rect, ink: render.Color, phase: f32) {
	smooth :: proc(x: f32) -> f32 {
		t := clamp(x, 0, 1)
		return t * t * (3 - 2 * t)
	}
	bell :: proc(t: f32) -> f32 {
		s := math.sin(math.PI * clamp(t, 0, 1))
		return s * s
	}
	unit := r.width / 12
	stars := SPINNER_STARS
	point :: proc(r: render.Rect, unit: f32, p: [2]f32) -> [2]f32 {return {r.x + p.x * unit, r.y + p.y * unit}}
	fade := 1 - smooth((phase - 0.75) / 0.25)
	for i in 0 ..< 3 {
		reach := smooth((phase - 0.02 - 0.21 * f32(i)) / 0.23)
		if reach <= 0 {continue}
		color := ink
		color.a *= 0.85 * fade * smooth(reach / 0.15)
		if color.a <= 0 {continue}
		from := point(r, unit, stars[i])
		to := point(r, unit, stars[i] + (stars[i + 1] - stars[i]) * reach)
		_ = render.push_segment(list, from, to, 1.5 * unit, color)
	}
	for star, i in stars {
		flash := i == 0 ? bell(phase / 0.18) : bell((phase - 0.17 - 0.21 * f32(i - 1)) / 0.22)
		radius := (1.15 + 0.3 * flash) * unit
		color := ink
		color.a *= 0.61 + 0.39 * flash
		c := point(r, unit, star)
		dot := render.Rect{c.x - radius, c.y - radius, 2 * radius, 2 * radius}
		draw_rect(list, {rect = dot, color = color, radius = radius})
	}
}
