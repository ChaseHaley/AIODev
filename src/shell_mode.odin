package main

import "aio:layout"
import "cosmos:render"
import "aio:term"
import "aio:ui"
import "core:math"

// Height of the optional bottom-of-pane shell mode strip in DIP.
SHELL_MODE_FOOTER_HEIGHT :: 22

pane_footer_height :: proc(app: ^App, scale: f32, entry: ^Session_Entry) -> f32 {
	if app.settings.pane.shell_mode_badge != .Footer {return 0}
	if entry == nil || entry.session == nil {return 0}
	if term.shell_mode(entry.session) == .None {return 0}
	return math.round(SHELL_MODE_FOOTER_HEIGHT * scale)
}

shell_mode_label :: proc(mode: term.Shell_Mode) -> string {
	switch mode {
	case .None:
		return ""
	case .Insert:
		return "INSERT"
	case .Normal:
		return "NORMAL"
	case .Visual:
		return "VISUAL"
	case .Visual_Line:
		return "V-LINE"
	}
	return ""
}

shell_mode_color :: proc(theme: ui.Theme, mode: term.Shell_Mode) -> render.Color {
	switch mode {
	case .None:
		return theme.muted
	case .Insert:
		return theme.success
	case .Normal:
		return theme.accent
	case .Visual, .Visual_Line:
		return theme.palette[5]
	}
	return theme.accent
}

// Label and accent color for a pane header's shell mode pill, or empty when not shown there.
shell_mode_header_pill :: proc(app: ^App, entry: ^Session_Entry) -> (label: string, color: render.Color) {
	if app.settings.pane.shell_mode_badge != .Header {return}
	if entry == nil || entry.session == nil {return}
	mode := term.shell_mode(entry.session)
	if mode == .None {return}
	return shell_mode_label(mode), shell_mode_color(app.theme, mode)
}

// Draws the bottom-of-pane shell mode strip (.Footer) or floating corner pill (.Corner).
shell_mode_overlay_draw :: proc(
	app: ^App,
	w: ^Window,
	pane: layout.Pane_Rect,
	entry: ^Session_Entry,
) -> render.Build_Status {
	placement := app.settings.pane.shell_mode_badge
	if placement != .Footer && placement != .Corner {return .Ok}
	if entry == nil || entry.session == nil {return .Ok}
	mode := term.shell_mode(entry.session)
	if mode == .None {return .Ok}

	label := shell_mode_label(mode)
	color := shell_mode_color(app.theme, mode)
	scale := w.scale
	r := pane.rect
	radius := window_pane_radius(app, w)
	small := ui.text_styled(&w.ui_text, .Detail)
	text_w := ui.text_width(&small, label)
	pad_x := ui.SPACE_2 * scale
	pill_w := text_w + 2 * pad_x
	pill_h := math.round(16 * scale)

	if placement == .Footer {
		footer_h := pane_footer_height(app, scale, entry)
		if footer_h <= 0 || r.height < footer_h + pane_header_height(scale) {return .Ok}
		strip := render.Rect{r.x, r.y + r.height - footer_h, r.width, footer_h}
		if render.push_layer(&w.list, {r.x, r.y, r.width, r.height}, radius) != .None {return .Ok}
		ui.draw_rect(&w.list, {rect = strip, color = app.theme.pane})
		hairline := app.theme.border
		hairline.a *= 0.45
		ui.draw_rect(&w.list, {rect = {strip.x, strip.y, strip.width, max(1, math.round(scale))}, color = hairline})
		pill := render.Rect{
			strip.x + ui.SPACE_2 * scale,
			strip.y + math.round((strip.height - pill_h) / 2),
			min(pill_w, max(0, strip.width - 2 * ui.SPACE_2 * scale)),
			pill_h,
		}
		if pill.width <= 0 {return .Ok}
		fill := color
		fill.a *= 0.18
		ui.draw_rect(&w.list, {rect = pill, color = fill, radius = pill.height / 2})
		return ui.draw_fading_text(
			&small,
			&w.list,
			label,
			pill.x + pad_x,
			pill.y + (pill.height - small.line_height) / 2 + small.ascent,
			color,
			max(0, pill.width - 2 * pad_x),
		)
	}

	// .Corner: floating rounded pill at the bottom-right corner of the pane card.
	margin_x := ui.SPACE_2 * scale + 2 * scale
	margin_y := ui.SPACE_2 * scale
	pill := render.Rect{
		r.x + r.width - pill_w - margin_x,
		r.y + r.height - pill_h - margin_y,
		pill_w,
		pill_h,
	}
	if pill.x < r.x + ui.SPACE_2 * scale || pill.y < r.y + pane_header_height(scale) {return .Ok}
	if render.push_layer(&w.list, {r.x, r.y, r.width, r.height}, radius) != .None {return .Ok}
	// Opaque base from pane surface + tinted overlay so the pill stays legible over terminal text.
	ui.draw_rect(&w.list, {rect = pill, color = app.theme.surface, radius = pill.height / 2})
	fill := color
	fill.a *= 0.22
	ui.draw_rect(&w.list, {rect = pill, color = fill, radius = pill.height / 2})
	border := color
	border.a *= 0.45
	ui.draw_rect(
		&w.list,
		{
			rect = pill,
			color = border,
			radius = pill.height / 2,
			stroke = max(1, math.round(scale)),
		},
	)
	return ui.draw_fading_text(
		&small,
		&w.list,
		label,
		pill.x + pad_x,
		pill.y + (pill.height - small.line_height) / 2 + small.ascent,
		color,
		max(0, pill.width - 2 * pad_x),
	)
}
