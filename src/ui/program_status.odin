package ui

import "aio:glyphs"
import "aio:render"
import "core:math"

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

// Progress is -1 when the program reported none. Dim marks finished work the user has seen.
Status_Mark :: struct {
	glyph:    Status_Glyph,
	progress: i8,
	dim:      bool,
}

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

status_blocked :: proc(glyph: Status_Glyph) -> bool {
	return glyph == .Blocked || glyph == .Permission || glyph == .Question || glyph == .Auth
}

// Draws the mark centered in `area`. `phase` in [0, 1) places the working spinner's dot, so a
// caller that never advances it draws a still spinner.
status_glyph_draw :: proc(
	list: ^render.Draw_List,
	text: ^Text,
	theme: Theme,
	area: render.Rect,
	mark: Status_Mark,
	phase: f32,
	scale: f32,
) -> glyphs.Result {
	if mark.glyph == .None {return .Ok}
	size := min(area.width, area.height)
	if size <= 2 * scale {return .Ok}
	r := render.Rect{area.x + (area.width - size) / 2, area.y + (area.height - size) / 2, size, size}
	ink := status_color(theme, mark.glyph)
	if mark.dim {ink.a *= 0.55}
	stroke := max(1, math.round(1.5 * scale))
	switch mark.glyph {
	case .None:
	case .Idle:
		inset := size * 0.2
		ring := render.Rect{r.x + inset, r.y + inset, size - 2 * inset, size - 2 * inset}
		draw_rect(list, {rect = ring, color = ink, radius = ring.width / 2, stroke = stroke})
	case .Working:
		track := theme.border
		draw_rect(list, {rect = r, color = track, radius = size / 2, stroke = stroke})
		if mark.progress >= 0 {
			inner := size * 0.3
			fill := render.Rect{r.x + inner, r.y + inner, size - 2 * inner, size - 2 * inner}
			draw_rect(list, {rect = fill, color = ink, radius = fill.width / 2})
			return .Ok
		}
		dot := max(2 * scale, size * 0.3)
		angle := phase * 2 * math.PI - math.PI / 2
		orbit := (size - stroke) / 2
		cx := r.x + size / 2 + math.cos(angle) * orbit
		cy := r.y + size / 2 + math.sin(angle) * orbit
		draw_rect(list, {rect = {cx - dot / 2, cy - dot / 2, dot, dot}, color = ink, radius = dot / 2})
	case .Blocked, .Permission, .Question, .Auth, .Done, .Error:
		draw_rect(list, {rect = r, color = ink, radius = size / 2})
		symbol := text^
		text_set_size(&symbol, size * 0.72)
		paper := theme.window
		if mark.glyph == .Auth && text.has_icons {
			return draw_icon(text, list, STATUS_LOCK_ICON, r, paper, 0.95)
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

// A short label for the state: what a blocked program needs, or a percentage while working.
status_headline :: proc(mark: Status_Mark, buffer: []u8) -> string {
	switch mark.glyph {
	case .None:
		return ""
	case .Idle:
		return "Idle"
	case .Working:
		if mark.progress >= 0 && len(buffer) >= 4 {
			n := int(mark.progress)
			i := len(buffer)
			i -= 1
			buffer[i] = '%'
			for {
				i -= 1
				buffer[i] = u8('0' + n % 10)
				n /= 10
				if n == 0 {break}
			}
			return string(buffer[i:])
		}
		return "Working"
	case .Blocked:
		return "Needs you"
	case .Permission:
		return "Needs permission"
	case .Question:
		return "Has a question"
	case .Auth:
		return "Needs sign-in"
	case .Done:
		return "Done"
	case .Error:
		return "Failed"
	}
	return ""
}
