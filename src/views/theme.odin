package views

import "aio:settings"
import "cosmos:colour"
import "cosmos:render"
import "cosmos:ui"
import "cosmos:theme"

// Every interface colour, resolved from the settings theme: the roles Cosmos widgets draw with, which
// a view passes on as `theme.base`, and the colours only AIODev's views use.
Theme :: struct {
	using base:              ui.Theme,
	// Markdown code, inline code and frontmatter fills.
	code_background:         render.Color,
	// The colours of Markdown's elements.
	markdown:                Markdown_Colors,
	// The fills behind added and removed lines of a diff.
	diff_added, diff_removed: render.Color,
	// The terminal's 16 colours, which syntax colouring and per-agent tints take their hues from, so
	// every theme's code reads like its terminal.
	palette:                 [16]render.Color,
}

// The interface theme from a resolved family theme and the interface settings that tune the hover.
theme_from :: proc(t: theme.Theme, interface: settings.Interface_Settings) -> Theme {
	c :: proc(t: theme.Theme, token: theme.Token) -> render.Color {
		value := t.colors[token]
		return colour.rgba(value.rgb, f32(value.a) / 255)
	}
	palette: [16]render.Color
	for &entry, i in palette {entry = c(t, theme.Token(int(theme.Token.Palette_0) + i))}
	return {
		base = ui.theme_from(t, f32(interface.hover_lift), f32(interface.hover_gloss)),
		palette = palette,
		code_background = c(t, .Code_Background),
		markdown = markdown_colors_from(t),
		diff_added = c(t, .Diff_Added),
		diff_removed = c(t, .Diff_Removed),
	}
}

