package settings_test

import "aio:settings"
import "core:strings"
import "core:testing"
import fixtures "../fixtures"

@(test)
markdown_colors_default_to_the_shared_colors_in_every_shipped_theme :: proc(t: ^testing.T) {
	tokens := settings.THEME_TOKENS
	count := 0
	for file in fixtures.SHIPPED_THEMES {
		theme, ok := fixtures.shipped_theme_file(file)
		if !ok {continue}
		count += 1
		for token in settings.Theme_Token {
			if target, follows := settings.TOKEN_DEFAULT_LINKS[token].?; follows {
				testing.expectf(t, token in theme.linked, "%s follows by default in %s", tokens[token].key, file.name)
				testing.expectf(
					t,
					theme.colors[token] == theme.colors[target],
					"%s is %v in %s, not %s's %v",
					tokens[token].key,
					theme.colors[token],
					file.name,
					tokens[target].key,
					theme.colors[target],
				)
			} else if tokens[token].kind == .Clear {
				testing.expectf(t, theme.colors[token].a == 0, "%s is none in %s", tokens[token].key, file.name)
			}
		}
		// Each draws what Markdown drew from the shared colors: the same colors, not copies.
		testing.expect_value(t, theme.colors[.Md_Link_Text], theme.colors[.Accent])
		testing.expect_value(t, theme.colors[.Md_Wikilink_Text], theme.colors[.Accent])
		testing.expect_value(t, theme.colors[.Md_Quote_Text], theme.colors[.Muted])
		testing.expect_value(t, theme.colors[.Md_Table_Border], theme.colors[.Border])
		testing.expect_value(t, theme.colors[.Md_Inline_Code_Background], theme.colors[.Code_Background])
		testing.expect_value(t, theme.colors[.Md_H2_Text].a, u8(0))
	}
	testing.expect(t, count >= 20)
}

@(test)
the_heading_pair_reaches_every_level_and_a_level_can_differ :: proc(t: ^testing.T) {
	s, d, err := parse_themes(
		"theme.name = mine\ntheme.custom.mine.base = tide-dark\ntheme.custom.mine.markdown_heading_text = #aabbcc\n" +
		"theme.custom.mine.markdown_h2_text = #112233\ntheme.custom.mine.markdown_heading_background = accent\n",
		THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	c := s.active_theme.colors
	pair := settings.Theme_Color{0xaa, 0xbb, 0xcc, 255}
	for token in ([?]settings.Theme_Token{.Md_H1_Text, .Md_H3_Text, .Md_H4_Text, .Md_H5_Text, .Md_H6_Text}) {
		testing.expect_value(t, c[token], pair)
	}
	testing.expect_value(t, c[.Md_H2_Text], settings.Theme_Color{0x11, 0x22, 0x33, 255})
	for token in ([?]settings.Theme_Token{.Md_H1_Background, .Md_H2_Background, .Md_H6_Background}) {
		testing.expect_value(t, c[token], c[.Accent])
	}
	// Changing the colors followed moves what follows them.
	moved, md, me := parse_themes(
		"theme.name = mine\ntheme.custom.mine.base = tide-dark\ntheme.custom.mine.accent = #010203\n",
		THEMES,
	)
	defer settings.destroy(&moved)
	defer settings.diagnostics_destroy(&md)
	testing.expect_value(t, me, nil)
	testing.expect_value(t, moved.active_theme.colors[.Md_Link_Text], settings.Theme_Color{1, 2, 3, 255})
	testing.expect_value(t, moved.active_theme.colors[.Md_Wikilink_Text], settings.Theme_Color{1, 2, 3, 255})
	testing.expect_value(t, moved.active_theme.colors[.Md_Task_Done_Background], settings.Theme_Color{1, 2, 3, 255})
}

@(test)
none_is_a_value_that_overrides_a_default_link_and_reset_restores_the_link :: proc(t: ^testing.T) {
	source := "theme.name = tide-dark\n"
	// Setting none saves a line of its own, unlike resetting, which removes it.
	none, created, issue, edit_error := edit_color(source, "markdown_inline_code_background", "#00000000", THEMES)
	defer delete(none)
	defer delete(created)
	testing.expect_value(t, edit_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect(t, strings.contains(none, ".markdown_inline_code_background = #00000000\n"), none)
	s, d, err := parse_themes(none, THEMES)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, s.active_theme.colors[.Md_Inline_Code_Background], settings.Theme_Color{})
	testing.expect(t, .Md_Inline_Code_Background not_in s.active_theme.linked)
	testing.expect_value(t, s.active_theme.colors[.Md_Code_Block_Background], s.active_theme.colors[.Code_Background])

	reset, _, _, reset_error := settings.theme_color_edit(&s, none, "markdown_inline_code_background", "")
	defer delete(reset)
	testing.expect_value(t, reset_error, settings.Theme_Edit_Error.None)
	testing.expect(t, !strings.contains(reset, "markdown_inline_code_background"), reset)
	back, bd, be := parse_themes(reset, THEMES)
	defer settings.destroy(&back)
	defer settings.diagnostics_destroy(&bd)
	testing.expect_value(t, be, nil)
	testing.expect(t, .Md_Inline_Code_Background in back.active_theme.linked)
	testing.expect_value(
		t,
		back.active_theme.colors[.Md_Inline_Code_Background],
		back.active_theme.colors[.Code_Background],
	)

	// A translucent fill keeps its alpha.
	tint, tint_id, _, tint_error := edit_color(source, "markdown_h1_background", "#33445566", THEMES)
	defer delete(tint)
	defer delete(tint_id)
	testing.expect_value(t, tint_error, settings.Theme_Edit_Error.None)
	testing.expect(t, strings.contains(tint, ".markdown_h1_background = #33445566\n"), tint)
}

@(test)
a_color_that_may_be_none_is_followed_only_by_another_that_may_be :: proc(t: ^testing.T) {
	s, d, err := parse_themes(
		"theme.name = mine\ntheme.custom.mine.text = markdown_h1_text\n" +
		"theme.custom.mine.markdown_h3_text = cursor\ntheme.custom.mine.markdown_h4_text = markdown_h5_text\n",
		THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 2)
	base := settings.theme_default()
	testing.expect_value(t, s.active_theme.colors[.Text], base.colors[.Text])
	testing.expect_value(t, s.active_theme.target[.Md_H4_Text], settings.Theme_Token.Md_H5_Text)
	testing.expect(t, .Md_H4_Text in s.active_theme.linked)
}

@(test)
the_default_theme_stays_concrete_with_the_markdown_colors_filled_in :: proc(t: ^testing.T) {
	base := settings.theme_default()
	// It follows the default links like every theme, and holds no link of its own.
	testing.expect_value(t, explicit_links(base), bit_set[settings.Theme_Token]{})
	testing.expect(t, .Md_Link_Text in base.linked)
	testing.expect_value(t, base.colors[.Md_Link_Text], base.colors[.Accent])
	testing.expect_value(t, base.colors[.Md_Paragraph_Text], base.colors[.Text])
	testing.expect_value(t, base.colors[.Md_Strong_Background], settings.Theme_Color{})
}
