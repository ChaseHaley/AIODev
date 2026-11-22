package settings

import "cosmos:theme"

// `name` is the active theme's ID: a theme file's or a custom theme's.
Theme_Settings :: struct {
	name: string,
}

// The terminal colors a theme gives every session.
theme_terminal :: proc(t: theme.Theme) -> Color_Settings {
	c := Color_Settings {
		foreground                 = t.colors[.Foreground].rgb,
		background                 = t.colors[.Background].rgb,
		cursor                     = theme.cursor(t),
		cursor_text                = theme.cursor_text(t),
		light                      = t.terminal_light,
		selection_background       = t.colors[.Selection_Background].rgb,
		search_foreground          = t.colors[.Search_Foreground].rgb,
		search_background          = t.colors[.Search_Background].rgb,
		search_selected_background = t.colors[.Search_Selected_Background].rgb,
	}
	if selection := t.colors[.Selection_Foreground]; selection.a != 0 {
		c.selection_foreground = selection.rgb
	}
	for &value, i in c.palette {
		value = t.colors[theme.Token(int(theme.Token.Palette_0) + i)].rgb
	}
	return c
}
