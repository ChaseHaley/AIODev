package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

THEMES :: "themes"

@(test)
shipped_themes_resolve_after_parsing :: proc(t: ^testing.T) {
	cases := [?]struct {id: string, background, ansi_red: settings.Color, light: bool} {
		{"studio-dark", {0x12, 0x12, 0x15}, {0xff, 0x7c, 0x87}, false},
		{"studio-light", {0xff, 0xff, 0xff}, {0xc0, 0x2f, 0x3f}, true},
		{"tide-dark", {0x15, 0x1e, 0x26}, {0xf2, 0x82, 0x82}, false},
		{"tide-light", {0xf8, 0xfa, 0xfc}, {0xb5, 0x3a, 0x3a}, true},
		{"ember-dark", {0x22, 0x1d, 0x1a}, {0xef, 0x7d, 0x6f}, false},
		{"ember-light", {0xfb, 0xf8, 0xf5}, {0xb3, 0x3e, 0x2e}, true},
		{"tokyonight-night", {0x1a, 0x1b, 0x26}, {0xf7, 0x76, 0x8e}, false},
		{"tokyonight-storm", {0x24, 0x28, 0x3b}, {0xf7, 0x76, 0x8e}, false},
		{"tokyonight-moon", {0x22, 0x24, 0x36}, {0xff, 0x75, 0x7f}, false},
		{"tokyonight-day", {0xe1, 0xe2, 0xe7}, {0xf5, 0x2a, 0x65}, true},
	}
	for fixture in cases {
		s, d, err := settings.parse(fmt.tprintf("theme.name = %s\n", fixture.id), themes_directory = THEMES)
		defer settings.destroy(&s)
		defer settings.diagnostics_destroy(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(d), 0)
		theme := s.active_theme
		testing.expect_value(t, s.colors.background, fixture.background)
		testing.expect_value(t, s.colors.palette[1], fixture.ansi_red)
		testing.expect_value(t, s.colors.foreground, theme.colors[.Foreground].rgb)
		testing.expect_value(t, theme.light, fixture.light)
		testing.expect_value(t, theme, shipped_theme(fixture.id))
	}
}

@(test)
the_compiled_default_survives_an_empty_themes_folder :: proc(t: ^testing.T) {
	s, d, err := settings.parse("theme.name = tide-dark\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 1)
	testing.expect_value(t, len(s.themes), 1)
	testing.expect_value(t, s.themes[0].id, settings.DEFAULT_THEME_ID)
	testing.expect_value(t, s.active_theme, shipped_theme(settings.DEFAULT_THEME_ID))
	testing.expect_value(t, settings.theme_default(), shipped_theme(settings.DEFAULT_THEME_ID))

	defaults, default_error := settings.defaults()
	defer settings.destroy(&defaults)
	testing.expect_value(t, default_error, nil)
	testing.expect_value(t, defaults.theme.name, settings.DEFAULT_THEME_ID)
	testing.expect_value(t, defaults.active_theme, settings.theme_default())
}

@(test)
custom_theme_inherits_its_base_and_overrides_single_colors :: proc(t: ^testing.T) {
	s, d, err := settings.parse(
		"theme.name = ocean\ntheme.custom.ocean.base = tide-light\n" +
		"theme.custom.ocean.tab_bar = #010203\ntheme.custom.ocean.border = #04050680\n" +
		"theme.custom.ocean.palette.15 = #070809\ntheme.custom.other.cursor = #0a0b0c\n",
		themes_directory = THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, len(s.themes), 12)
	base := shipped_theme("tide-light")
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
custom_themes_stack_on_custom_bases_and_survive_cycles :: proc(t: ^testing.T) {
	s, d, err := settings.parse(
		"theme.name = top\ntheme.custom.top.base = middle\ntheme.custom.top.cursor = #010101\n" +
		"theme.custom.middle.base = ember-light\ntheme.custom.middle.tab_bar = #020202\n" +
		"theme.custom.loop.base = loop\ntheme.custom.loop.accent = #030303\n",
		themes_directory = THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	base := shipped_theme("ember-light")
	testing.expect_value(t, s.active_theme.colors[.Cursor], settings.Theme_Color{1, 1, 1, 255})
	testing.expect_value(t, s.active_theme.colors[.Tab_Bar], settings.Theme_Color{2, 2, 2, 255})
	testing.expect_value(t, s.active_theme.colors[.Window], base.colors[.Window])
	loop := settings.custom_theme_resolve(&s, settings.custom_theme_find(&s, "loop"))
	testing.expect_value(t, loop.colors[.Accent], settings.Theme_Color{3, 3, 3, 255})
	testing.expect_value(t, loop.colors[.Window], settings.theme_default().colors[.Window])
}

@(test)
theme_validation_reports_and_falls_back :: proc(t: ^testing.T) {
	s, d, err := settings.parse(
		"theme.name = unknown\ntheme.mode = auto\npane.gap = 25\npane.corner_radius = -1\n" +
		"theme.custom.Bad.cursor = #000000\n" +
		"theme.custom.mine.nope = #000000\ntheme.custom.mine.cursor = #00000080\n" +
		"theme.custom.mine.base = Studio\ntheme.custom.mine = #000000\n",
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 8)
	testing.expect_value(t, s.theme.name, "unknown")
	testing.expect_value(t, s.active_theme, settings.theme_default())
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

	missing, missing_d, missing_error := settings.parse(
		"theme.name = mine\ntheme.custom.mine.base = gone\ntheme.custom.mine.cursor = #010203\n",
	)
	defer settings.destroy(&missing)
	defer settings.diagnostics_destroy(&missing_d)
	testing.expect_value(t, missing_error, nil)
	if testing.expect_value(t, len(missing_d), 1) {
		testing.expect(t, strings.contains(missing_d[0].message, "\"gone\""))
	}
	testing.expect_value(t, missing.active_theme.colors[.Cursor], settings.Theme_Color{1, 2, 3, 255})
	testing.expect_value(t, missing.active_theme.colors[.Window], settings.theme_default().colors[.Window])
}

@(test)
theme_ids_follow_profile_rules :: proc(t: ^testing.T) {
	for id in ([?]string{"ocean", "studio", "studio-2", "tokyonight-day"}) {
		testing.expectf(t, settings.theme_id_valid(id), "%q should be valid", id)
	}
	for id in ([?]string{"", "Ocean", "-x", "a b", "a.b"}) {
		testing.expectf(t, !settings.theme_id_valid(id), "%q should be invalid", id)
	}
}

@(test)
legacy_theme_name_and_mode_become_one_theme_id :: proc(t: ^testing.T) {
	Case :: struct {source, expected: string}
	cases := [?]Case {
		{"theme.name = \"tide\"\ntheme.mode = light\n", "theme.name = \"tide-light\"\n"},
		{"theme.mode = light\n", "theme.name = \"studio-light\"\n"},
		{"theme.name = tokyonight-storm\ntheme.mode = dark\n", "theme.name = \"tokyonight-storm\"\n"},
		{"theme.name = tokyonight-moon\ntheme.mode = light\n", "theme.name = \"tokyonight-day\"\n"},
		{"theme.name = mine\ntheme.mode = light\n", "theme.name = mine\n"},
		{
			"# Color theme: studio, tide, ember, tokyonight-night, tokyonight-storm, tokyonight-moon, " +
			"or a custom ID.\ntheme.name = \"ember\"\n\n" +
			"# Variant of a built-in theme: dark or light. Custom themes keep their own colors.\n" +
			"theme.mode = dark\n# kept\nfont.size = 13\n",
			"# Color theme ID: a file in the themes folder, such as studio-light, or a custom theme.\n" +
			"theme.name = \"ember-dark\"\n\n# kept\nfont.size = 13\n",
		},
	}
	for c in cases {
		updated, migrated, err := settings.migrate_theme_variant_text(c.source)
		defer delete(updated)
		testing.expect_value(t, err, nil)
		testing.expect(t, migrated)
		testing.expect_value(t, updated, c.expected)
	}
	_, untouched, _ := settings.migrate_theme_variant_text("theme.name = tide\n")
	testing.expect(t, !untouched)

	s, d, err := settings.parse(
		"theme.name = mine\ntheme.custom.mine.base = tokyonight-night-light\n", themes_directory = THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, s.active_theme, shipped_theme("tokyonight-day"))
}

@(test)
themes_show_free_text_names_while_ids_stay_the_key :: proc(t: ^testing.T) {
	s, d, err := settings.parse(
		"theme.name = mine\ntheme.custom.mine.name = \"Late Night: Ünïcode / <Mine>?\"\n" +
		"theme.custom.mine.base = tide-dark\n",
		themes_directory = THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, settings.theme_display_name(&s, "mine"), "Late Night: Ünïcode / <Mine>?")
	testing.expect_value(t, settings.theme_display_name(&s, "tokyonight-storm"), "Tokyo Night Storm")
	testing.expect_value(t, settings.theme_display_name(&s, "nothing"), "nothing")

	updated, created, issue, edit_error := settings.theme_color_edit(
		"theme.name = tide-dark\n", "accent", "#010203", themes_directory = THEMES,
	)
	defer delete(updated)
	defer delete(created)
	testing.expect_value(t, edit_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect(t, strings.contains(updated, "theme.custom.tide-dark-custom.name = \"Tide Dark Custom\"\n"))
	named, message, alloc := settings.edit_text(updated, "theme.custom.tide-dark-custom.name", "Mine, with spaces!")
	defer delete(named)
	defer delete(message)
	testing.expect_value(t, alloc, nil)
	testing.expect_value(t, message, "")
	copy, copy_id, copy_error := settings.theme_duplicate(named, themes_directory = THEMES)
	defer delete(copy)
	defer delete(copy_id)
	testing.expect_value(t, copy_error, settings.Theme_Edit_Error.None)
	c, cd, ce := settings.parse(copy, themes_directory = THEMES)
	defer settings.destroy(&c)
	defer settings.diagnostics_destroy(&cd)
	testing.expect_value(t, ce, nil)
	testing.expect_value(t, len(cd), 0)
	testing.expect_value(t, settings.theme_display_name(&c, "tide-dark-custom"), "Mine, with spaces!")
	testing.expect_value(t, settings.theme_display_name(&c, copy_id), "Mine, with spaces! Copy")
}
