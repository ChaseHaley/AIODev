package views

import "aio:settings"
import "cosmos:colour"
import "cosmos:render"
import "cosmos:ui"

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

// The interface theme from a resolved settings theme and the interface settings that tune the hover.
theme_from :: proc(t: settings.Theme, interface: settings.Interface_Settings) -> Theme {
	c :: proc(t: settings.Theme, token: settings.Theme_Token) -> render.Color {
		value := t.colors[token]
		return colour.rgba(value.rgb, f32(value.a) / 255)
	}
	text, raised, accent := t.colors[.Text].rgb, t.colors[.Surface].rgb, t.colors[.Accent].rgb
	palette: [16]render.Color
	for &entry, i in palette {entry = c(t, settings.Theme_Token(int(settings.Theme_Token.Palette_0) + i))}
	return {
		base = {
			window = c(t, .Window),
			pane = c(t, .Pane),
			surface = c(t, .Surface),
			text = c(t, .Text),
			muted = c(t, .Muted),
			faint = c(t, .Faint),
			accent = c(t, .Accent),
			accent_text = c(t, .Accent_Text),
			border = c(t, .Border),
			selection = c(t, .Selection),
			focus = c(t, .Focus),
			caret = colour.rgba(settings.theme_cursor(t)),
			caret_text = colour.rgba(settings.theme_cursor_text(t)),
			text_selection = c(t, .Selection_Background),
			text_selection_text = t.colors[.Selection_Foreground].a != 0 ? c(t, .Selection_Foreground) : nil,
			error = c(t, .Danger),
			success = c(t, .Success),
			warning = c(t, .Warning),
			info = c(t, .Info),
			tab_bar = c(t, .Tab_Bar),
			tab_text = c(t, .Tab_Text),
			tab_active = c(t, .Tab_Active),
			tab_active_text = c(t, .Tab_Active_Text),
			tab_indicator = c(t, .Tab_Indicator),
			rail_active = c(t, .Rail_Active),
			pane_border = c(t, .Pane_Border),
			pane_focus = c(t, .Pane_Focus),
			scrollbar_track = c(t, .Scrollbar_Track),
			scrollbar = c(t, .Scrollbar),
			scrollbar_hover = c(t, .Scrollbar_Hover),
			scrollbar_active = c(t, .Scrollbar_Active),
			// Light mode's hover is paper: the opaque raised-surface colour, so the seat drawn
			// underneath cannot show through and darken the tile, and its shape comes from the
			// hairline and the seat rather than from ink. Dark mode keeps the translucent lift.
			hover = t.light ? colour.rgba(raised) : colour.rgba(text, 0.05),
			pressed = colour.rgba(text, t.light ? 0.08 : 0.09),
			shadow = {0, 0, 0, t.light ? 0.12 : 0.35},
			scrim = {0, 0, 0, t.light ? 0.08 : 0.18},
			// White light reads as a specular edge on dark surfaces. On a white control the rim
			// must stay faint, or it becomes the dark edge the paper fill exists to avoid.
			rim = colour.rgba(t.light ? accent : text, t.light ? 0.20 : 0.80),
			hover_edge = t.light ? colour.rgba(text, 0.10) : render.Color{0, 0, 0, 0},
			hover_lift = f32(interface.hover_lift),
			hover_gloss = f32(interface.hover_gloss),
		},
		palette = palette,
		code_background = c(t, .Code_Background),
		markdown = markdown_colors_from(t),
		diff_added = c(t, .Diff_Added),
		diff_removed = c(t, .Diff_Removed),
	}
}

