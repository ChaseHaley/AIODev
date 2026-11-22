package settings_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"
import "cosmos:theme"

@(test)
theme_tokens_have_unique_keys_titles_and_valid_kinds :: proc(t: ^testing.T) {
	tokens := theme.TOKENS
	for a in theme.Token {
		info := tokens[a]
		testing.expectf(t, info.key != "" && info.title != "" && info.description != "", "%v needs text", a)
		testing.expectf(t, !strings.contains(info.title, "."), "%v title must be readable", a)
		if theme.token_terminal(a) {
			testing.expectf(t, info.kind != .Translucent, "terminal color %s must be opaque", info.key)
		}
		found, ok := theme.token_find(info.key)
		testing.expectf(t, ok && found == a, "%s must find itself", info.key)
		for b in theme.Token {
			if a == b {continue}
			testing.expectf(t, info.key != tokens[b].key, "%s is duplicated", info.key)
			testing.expectf(t, info.title != tokens[b].title, "%s is duplicated", info.title)
		}
	}
	testing.expect_value(t, tokens[.Selection_Foreground].kind, theme.Kind.Optional)
}

@(test)
every_token_round_trips_through_a_custom_theme :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, "theme.name = mine\ntheme.custom.mine.base = tide-light\n")
	tokens := theme.TOKENS
	expected: [theme.Token]theme.Color
	for token, i in theme.Token {
		alpha := tokens[token].kind == .Translucent ? u8(0x80) : u8(0xff)
		expected[token] = {u8(i + 1), u8(i + 11), u8(i + 21), alpha}
		fmt.sbprintf(
			&b,
			"theme.custom.mine.%s = %s\n",
			tokens[token].key,
			theme.color_text(token, expected[token]),
		)
	}
	s, diagnostics, err := parse_themes(strings.to_string(b), THEMES)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	for token in theme.Token {
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

