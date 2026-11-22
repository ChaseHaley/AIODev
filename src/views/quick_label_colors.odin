package views

import "cosmos:colour"
import "cosmos:render"

// The colour a quick label's setting names: one of settings.QUICK_LABEL_PRESETS, which takes its hue
// from the theme so it reads in every theme, or `#rrggbb`. Anything else shows the muted ink.
@(require_results)
quick_label_color :: proc(theme: Theme, value: string) -> render.Color {
	switch value {
	case "blue":
		return theme.palette[4]
	case "yellow":
		return theme.palette[3]
	case "red":
		return theme.palette[1]
	case "green":
		return theme.palette[2]
	case "teal":
		return theme.palette[6]
	case "violet":
		return theme.palette[5]
	case "gray":
		return theme.muted
	case "orange":
		// The terminal palette has no orange, so it sits halfway between its red and yellow.
		red, yellow := theme.palette[1], theme.palette[3]
		return {(red.r + yellow.r) / 2, (red.g + yellow.g) / 2, (red.b + yellow.b) / 2, 1}
	}
	if rgb, ok, _ := colour.parse(value, .Strict); ok {return colour.rgba(rgb)}
	return theme.muted
}

// A label's colour as text over `background`, lifted by the diff's minimum contrast the way code
// text is, so a custom colour stays readable in every theme.
@(require_results)
quick_label_ink :: proc(
	theme: Theme,
	value: string,
	background: render.Color,
	minimum_contrast: f32,
) -> render.Color {
	ink := quick_label_color(theme, value)
	return render.Color(colour.minimum_contrast(colour.RGBA(ink), colour.RGBA(background), minimum_contrast))
}
