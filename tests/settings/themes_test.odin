package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
builtin_themes_resolve_after_parsing :: proc(t: ^testing.T) {
	backgrounds := #partial [settings.Theme_Name][settings.Theme_Mode]settings.Color{
		.Studio = {.Dark = {0x12, 0x12, 0x15}, .Light = {0xff, 0xff, 0xff}},
		.Tide = {.Dark = {0x15, 0x1e, 0x26}, .Light = {0xf8, 0xfa, 0xfc}},
		.Ember = {.Dark = {0x22, 0x1d, 0x1a}, .Light = {0xfb, 0xf8, 0xf5}},
	}
	for name, i in ([?]string{"studio", "tide", "ember"}) {
		for mode, j in ([?]string{"dark", "light"}) {
			text := fmt.tprintf("theme.mode = %s\ntheme.name = %s\n", mode, name)
			s, d, err := settings.parse(text)
			defer settings.destroy(&s)
			defer settings.diagnostics_destroy(&d)
			testing.expect_value(t, err, nil)
			testing.expect_value(t, len(d), 0)
			theme := s.active_theme
			expected := backgrounds[settings.Theme_Name(i)][settings.Theme_Mode(j)]
			testing.expect_value(t, theme.colors[.Pane].rgb, expected)
			testing.expect_value(t, s.colors.background, expected)
			testing.expect_value(t, s.colors.foreground, theme.colors[.Text].rgb)
			testing.expect_value(t, theme, settings.builtin_theme({settings.Theme_Name(i), settings.Theme_Mode(j)}))
		}
	}
}

@(test)
tokyo_variants_resolve_and_support_custom_bases :: proc(t: ^testing.T) {
	cases := [?]struct {name: string, background, ansi_red: settings.Color} {
		{"tokyonight-night", {0x1a, 0x1b, 0x26}, {0xf7, 0x76, 0x8e}},
		{"tokyonight-storm", {0x24, 0x28, 0x3b}, {0xf7, 0x76, 0x8e}},
		{"tokyonight-moon", {0x22, 0x24, 0x36}, {0xff, 0x75, 0x7f}},
	}
	for fixture in cases {
		text := fmt.tprintf("theme.name = %s\ntheme.mode = dark\n", fixture.name)
		s, d, err := settings.parse(text)
		defer settings.destroy(&s)
		defer settings.diagnostics_destroy(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(d), 0)
		testing.expect_value(t, s.colors.background, fixture.background)
		testing.expect_value(t, s.colors.palette[1], fixture.ansi_red)
		base, ok := settings.builtin_parse(fmt.tprintf("%s-light", fixture.name))
		testing.expect(t, ok)
		day := settings.builtin_theme(base)
		testing.expect(t, day.light)
		testing.expect_value(t, day.colors[.Background].rgb, settings.Color{0xe1, 0xe2, 0xe7})
		testing.expect_value(t, day.colors[.Palette_1].rgb, settings.Color{0xf5, 0x2a, 0x65})
	}
}

@(test)
custom_theme_inherits_its_base_and_overrides_single_colors :: proc(t: ^testing.T) {
	s, d, err := settings.parse(
		"theme.mode = dark\ntheme.name = ocean\ntheme.custom.ocean.base = tide-light\n" +
		"theme.custom.ocean.tab_bar = #010203\ntheme.custom.ocean.border = #04050680\n" +
		"theme.custom.ocean.palette.15 = #070809\ntheme.custom.other.cursor = #0a0b0c\n",
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, len(s.themes), 2)
	base := settings.builtin_theme({.Tide, .Light})
	testing.expect_value(t, s.active_theme.colors[.Tab_Bar], settings.Theme_Color{1, 2, 3, 255})
	testing.expect_value(t, s.active_theme.colors[.Border], settings.Theme_Color{4, 5, 6, 0x80})
	testing.expect_value(t, s.colors.palette[15], settings.Color{7, 8, 9})
	testing.expect_value(t, s.active_theme.colors[.Cursor], base.colors[.Cursor])
	testing.expect_value(t, s.active_theme.colors[.Window], base.colors[.Window])
	testing.expect(t, s.active_theme.light)
	testing.expect(t, settings.theme_custom(&s))
	testing.expect_value(t, settings.theme_base(&s), base)
}

@(test)
theme_validation_reports_and_falls_back :: proc(t: ^testing.T) {
	s, d, err := settings.parse(
		"theme.name = unknown\ntheme.mode = auto\npane.gap = 25\npane.corner_radius = -1\n" +
		"theme.custom.studio.cursor = #000000\ntheme.custom.Bad.cursor = #000000\n" +
		"theme.custom.mine.nope = #000000\ntheme.custom.mine.cursor = #00000080\n" +
		"theme.custom.mine.base = studio\ntheme.custom.mine = #000000\n",
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 10)
	testing.expect_value(t, s.theme.name, "unknown")
	testing.expect_value(t, s.active_theme, settings.builtin_theme({.Studio, .Dark}))
	testing.expect_value(t, s.pane, settings.Pane_Settings{5, 7, true, true, 20, 5})
	unknown := false
	for diagnostic in d {
		if diagnostic.key == "theme.name" && strings.contains(diagnostic.message, "unknown theme") {unknown = true}
	}
	testing.expect(t, unknown)
	for fixture in ([?]string{"pane.gap = 0\npane.corner_radius = 0", "pane.gap = 24\npane.corner_radius = 16"}) {
		limits, issues, parse_error := settings.parse(fixture)
		defer settings.destroy(&limits)
		defer settings.diagnostics_destroy(&issues)
		testing.expect_value(t, parse_error, nil)
		testing.expect_value(t, len(issues), 0)
	}
}

@(test)
custom_theme_ids_never_shadow_builtins :: proc(t: ^testing.T) {
	testing.expect(t, settings.theme_id_valid("ocean"))
	testing.expect(t, settings.theme_id_valid("studio-2"))
	for id in ([?]string{"", "studio", "tide", "ember", "Ocean", "-x", "a b", "a.b"}) {
		testing.expectf(t, !settings.theme_id_valid(id), "%q should be invalid", id)
	}
	b, ok := settings.builtin_parse("ember-light")
	testing.expect(t, ok)
	testing.expect_value(t, b, settings.Builtin_Theme{.Ember, .Light})
	testing.expect_value(t, settings.builtin_id(b), "ember-light")
	for text in ([?]string{"ember", "ember-", "-light", "embers-light", "ember-lights"}) {
		_, valid := settings.builtin_parse(text)
		testing.expectf(t, !valid, "%q should be rejected", text)
	}
}
