package ui

import "aio:render"
import "core:math"
import "core:time"

// One program status record as the chrome shows it. Blocked splits by what the program needs.
Status_Glyph :: enum u8 {
	None,
	Idle,
	Working,
	Blocked,
	Permission,
	Question,
	Auth,
	Done,
	Error,
}

// Progress is -1 when the program reported none. Dim marks work the user has read, in the muted ink
// rather than the state's colour. Urgent inks the state's words in its colour rather than muted.
Status_Mark :: struct {
	glyph:    Status_Glyph,
	progress: i8,
	dim:      bool,
	urgent:   bool,
}

// One loop of the Working spinner. Every surface that spins, notices included, times it by this.
STATUS_SPIN_PERIOD :: 2360 * time.Millisecond
// The phase a spinner holds with animations off: two lines drawn and the third on its way, so the
// still mark reads as a constellation rather than four loose stars.
STATUS_SPIN_STILL :: f32(0.55)

// The constellation's four stars on a 12 by 12 grid, joined in order by the spinner's lines.
@(private)
STATUS_SPIN_STARS :: [4][2]f32{{2.10, 8.18}, {4.33, 3.82}, {7.26, 7.27}, {9.86, 3.86}}

@(private)
STATUS_LOCK_ICON :: ''

status_color :: proc(theme: Theme, glyph: Status_Glyph) -> render.Color {
	switch glyph {
	case .None, .Idle:
		return theme.faint
	case .Working:
		return theme.accent
	case .Blocked, .Permission, .Question, .Auth:
		return theme.warning
	case .Done:
		return theme.success
	case .Error:
		return theme.error
	}
	return theme.faint
}

// Draws the mark centered in `area`. `phase` in [0, 1) places the working spinner in its loop, so
// a caller that never advances it draws the spinner at its start.
status_glyph_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	mark: Status_Mark,
	phase: f32,
	scale: f32,
) -> render.Build_Status {
	if mark.glyph == .None {return .Ok}
	size := min(area.width, area.height)
	if size <= 2 * scale {return .Ok}
	r := render.Rect{area.x + (area.width - size) / 2, area.y + (area.height - size) / 2, size, size}
	ink := mark.dim ? theme.muted : status_color(theme, mark.glyph)
	stroke := max(1, math.round(1.5 * scale))
	switch mark.glyph {
	case .None:
	case .Idle:
		inset := size * 0.2
		ring := render.Rect{r.x + inset, r.y + inset, size - 2 * inset, size - 2 * inset}
		draw_rect(list, {rect = ring, color = ink, radius = ring.width / 2, stroke = stroke})
	case .Working:
		if mark.progress >= 0 {
			draw_rect(list, {rect = r, color = theme.border, radius = size / 2, stroke = stroke})
			inner := size * 0.3
			fill := render.Rect{r.x + inner, r.y + inner, size - 2 * inner, size - 2 * inner}
			draw_rect(list, {rect = fill, color = ink, radius = fill.width / 2})
			return .Ok
		}
		status_spinner_draw(list, r, ink, phase)
	case .Blocked, .Permission, .Question, .Auth, .Done, .Error:
		draw_rect(list, {rect = r, color = ink, radius = size / 2})
		symbol := text^
		text_set_size(&symbol, size * 0.72) // design-exempt: a glyph drawn as part of the status mark
		paper := theme.window
		if mark.glyph == .Auth && text.has_icons {
			return draw_icon(text, list, STATUS_LOCK_ICON, r, paper, r.height * 0.57)
		}
		glyph: rune
		#partial switch mark.glyph {
		case .Blocked, .Permission: glyph = '!'
		case .Question: glyph = '?'
		case .Auth: glyph = '*'
		case .Done: glyph = '✓'
		case .Error: glyph = '×'
		}
		return draw_glyph_centered(&symbol, list, glyph, r, paper)
	}
	return .Ok
}

// The Working spinner in `ink`, filling the square `r`: four fixed stars that a line joins one at a
// time, each star flashing as the line reaches it, then the lines fade together and the loop starts
// again from the first star. `phase` in [0, 1) is the place in the loop.
status_spinner_draw :: proc(list: ^render.Draw_List, r: render.Rect, ink: render.Color, phase: f32) {
	smooth :: proc(x: f32) -> f32 {
		t := clamp(x, 0, 1)
		return t * t * (3 - 2 * t)
	}
	bell :: proc(t: f32) -> f32 {
		s := math.sin(math.PI * clamp(t, 0, 1))
		return s * s
	}
	unit := r.width / 12
	stars := STATUS_SPIN_STARS
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

// A thin bar along the bottom of `area` showing reported progress; nothing without progress.
status_progress_draw :: proc(
	list: ^render.Draw_List,
	theme: Theme,
	area: render.Rect,
	mark: Status_Mark,
	scale: f32,
) {
	if mark.progress < 0 || area.width <= 0 {return}
	height := max(1, math.round(2 * scale))
	track := render.Rect{area.x, area.y + area.height - height, area.width, height}
	draw_rect(list, {rect = track, color = theme.border, radius = height / 2})
	done := track
	done.width = track.width * f32(mark.progress) / 100
	if done.width <= 0 {return}
	draw_rect(list, {rect = done, color = status_color(theme, mark.glyph), radius = height / 2})
}
