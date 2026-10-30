package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
theme_tokens_have_unique_keys_titles_and_valid_kinds :: proc(t: ^testing.T) {
	tokens := settings.THEME_TOKENS
	for a in settings.Theme_Token {
		info := tokens[a]
		testing.expectf(t, info.key != "" && info.title != "" && info.description != "", "%v needs text", a)
		testing.expectf(t, !strings.contains(info.title, "."), "%v title must be readable", a)
		if settings.token_terminal(a) {
			testing.expectf(t, info.kind != .Translucent, "terminal color %s must be opaque", info.key)
		}
		found, ok := settings.token_find(info.key)
		testing.expectf(t, ok && found == a, "%s must find itself", info.key)
		for b in settings.Theme_Token {
			if a == b {continue}
			testing.expectf(t, info.key != tokens[b].key, "%s is duplicated", info.key)
			testing.expectf(t, info.title != tokens[b].title, "%s is duplicated", info.title)
		}
	}
	testing.expect_value(t, tokens[.Selection_Foreground].kind, settings.Token_Kind.Optional)
}

@(test)
every_token_round_trips_through_a_custom_theme :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "theme.name = mine\ntheme.custom.mine.base = tide-light\n")
	tokens := settings.THEME_TOKENS
	expected: [settings.Theme_Token]settings.Theme_Color
	for token, i in settings.Theme_Token {
		alpha := tokens[token].kind == .Translucent ? u8(0x80) : u8(0xff)
		expected[token] = {u8(i + 1), u8(i + 11), u8(i + 21), alpha}
		fmt.sbprintf(
			&b,
			"theme.custom.mine.%s = %s\n",
			tokens[token].key,
			settings.theme_color_text(token, expected[token]),
		)
	}
	s, diagnostics, err := settings.parse(strings.to_string(b))
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	for token in settings.Theme_Token {
		testing.expectf(
			t,
			s.active_theme.colors[token] == expected[token],
			"%s resolved to %v",
			tokens[token].key,
			s.active_theme.colors[token],
		)
	}
	testing.expect_value(t, s.colors.palette[15], expected[.Palette_15].rgb)
	testing.expect_value(t, s.colors.selection_foreground.?, expected[.Selection_Foreground].rgb)
}

@(test)
builtin_light_matches_mode_and_selection_text_keeps_cell_colors :: proc(t: ^testing.T) {
	for name in settings.Theme_Name {
		for mode in settings.Theme_Mode {
			theme := settings.builtin_theme({name, mode})
			testing.expect_value(t, theme.light, mode == .Light)
			testing.expect_value(t, theme.terminal_light, mode == .Light)
			testing.expect_value(t, theme.colors[.Selection_Foreground].a, 0)
			testing.expect(t, settings.theme_terminal(theme).selection_foreground == nil)
			testing.expect_value(t, theme.colors[.Border].a, mode == .Light ? 23 : 20)
		}
	}
}
