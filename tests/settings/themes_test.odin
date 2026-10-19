package settings_test

import "core:testing"
import "core:fmt"
import "aio:settings"

@(test)
themes_resolve_after_parsing_and_preserve_terminal_overrides :: proc(t: ^testing.T) {
	backgrounds := [settings.Theme_Name][settings.Theme_Mode]settings.Color{
		.Studio = {.Dark = {0x12, 0x12, 0x15}, .Light = {0xff, 0xff, 0xff}},
		.Tide = {.Dark = {0x15, 0x1e, 0x26}, .Light = {0xf8, 0xfa, 0xfc}},
		.Ember = {.Dark = {0x22, 0x1d, 0x1a}, .Light = {0xfb, 0xf8, 0xf5}},
	}
	for name, i in ([?]string{"studio", "tide", "ember"}) {
		for mode, j in ([?]string{"dark", "light"}) {
			text := fmt.tprintf("colors.cursor = #abcdef\ntheme.mode = %s\ntheme.name = %s\n", mode, name)
			s, d, err := settings.parse(text)
			defer settings.destroy(&s)
			defer settings.diagnostics_destroy(&d)
			testing.expect_value(t, err, nil)
			testing.expect_value(t, len(d), 0)
			theme := settings.theme_resolve(s.theme)
			testing.expect_value(t, theme.pane, backgrounds[settings.Theme_Name(i)][settings.Theme_Mode(j)])
			testing.expect_value(t, s.colors.background, theme.pane)
			testing.expect_value(t, s.colors.foreground, theme.text)
			testing.expect_value(t, s.colors.palette, theme.terminal.palette)
			testing.expect_value(t, s.colors.cursor, settings.Color{0xab, 0xcd, 0xef})
			testing.expect_value(t, settings.value_text(&s, settings.schema_find("colors.background")^), "")
		}
	}
	s, d, err := settings.parse("theme.name = tide\ntheme.mode = light\ncolors.background = #010203\n"+
		"colors.palette.15 = #040506\ncolors.selection_background = #070809\ncolors.cursor =\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, s.colors.background, settings.Color{1, 2, 3})
	testing.expect_value(t, s.colors.palette[15], settings.Color{4, 5, 6})
	testing.expect_value(t, s.colors.selection_background, settings.Color{7, 8, 9})
	testing.expect_value(t, s.colors.cursor, settings.Color{0x14, 0x21, 0x2b})
	testing.expect_value(t, settings.theme_resolve(s.theme).pane, settings.Color{0xf8, 0xfa, 0xfc})
}

@(test)
theme_and_shape_validation :: proc(t: ^testing.T) {
	s, d, err := settings.parse("theme.name = unknown\ntheme.mode = auto\npane.gap = 25\npane.corner_radius = -1")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 4)
	testing.expect_value(t, s.theme, settings.Theme_Settings{})
	testing.expect_value(t, s.pane, settings.Pane_Settings{5, 7, true, 20, 5})
	for fixture in ([?]string{"pane.gap = 0\npane.corner_radius = 0", "pane.gap = 24\npane.corner_radius = 16"}) {
		limits, issues, parse_error := settings.parse(fixture)
		defer settings.destroy(&limits)
		defer settings.diagnostics_destroy(&issues)
		testing.expect_value(t, parse_error, nil)
		testing.expect_value(t, len(issues), 0)
	}
}
