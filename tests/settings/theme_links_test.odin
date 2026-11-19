package settings_test

import "aio:settings"
import "core:strings"
import "core:testing"
import fixtures "../fixtures"

// The colors a theme follows because it says so: those that follow by default are left out, as every
// theme follows them.
explicit_links :: proc(t: settings.Theme) -> bit_set[settings.Theme_Token] {
	linked := t.linked
	for follows, token in settings.TOKEN_DEFAULT_LINKS {
		if follows != nil {linked -= {token}}
	}
	return linked
}

@(test)
a_followed_color_takes_the_color_it_ends_at_and_chains_resolve :: proc(t: ^testing.T) {
	s, d, err := parse_themes(
		"theme.name = mine\ntheme.custom.mine.base = tide-light\ntheme.custom.mine.accent = #112233\n" +
		"theme.custom.mine.cursor = accent\ntheme.custom.mine.focus = pane_focus\n" +
		"theme.custom.mine.pane_focus = accent\ntheme.custom.mine.cursor_text = accent_text\n",
		THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	active := s.active_theme
	base := fixtures.shipped_theme("tide-light")
	testing.expect_value(t, active.colors[.Cursor], settings.Theme_Color{0x11, 0x22, 0x33, 255})
	testing.expect_value(t, active.colors[.Pane_Focus], settings.Theme_Color{0x11, 0x22, 0x33, 255})
	testing.expect_value(t, active.colors[.Focus], settings.Theme_Color{0x11, 0x22, 0x33, 255})
	testing.expect_value(t, active.colors[.Cursor_Text], base.colors[.Accent_Text])
	testing.expect_value(
		t,
		explicit_links(active),
		bit_set[settings.Theme_Token]{.Cursor, .Focus, .Pane_Focus, .Cursor_Text},
	)
	testing.expect_value(t, active.target[.Focus], settings.Theme_Token.Pane_Focus)
	testing.expect_value(t, s.colors.cursor, settings.Color{0x11, 0x22, 0x33})
	testing.expect_value(t, settings.theme_cursor(active), settings.Color{0x11, 0x22, 0x33})
	testing.expect_value(t, settings.theme_base(&s), base)
}

@(test)
a_follower_moves_with_a_color_its_base_theme_defines :: proc(t: ^testing.T) {
	// The link is kept as a link through the base chain: the base's accent, not a copy of it, is followed.
	for id in ([?]string{"tide-dark", "ember-light"}) {
		source := strings.concatenate(
			{"theme.name = mine\ntheme.custom.mine.base = ", id, "\ntheme.custom.mine.cursor = accent\n"},
			context.temp_allocator,
		)
		s, d, err := parse_themes(source, THEMES)
		defer settings.destroy(&s)
		defer settings.diagnostics_destroy(&d)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, len(d), 0)
		accent := fixtures.shipped_theme(id).colors[.Accent]
		testing.expect_value(t, s.active_theme.colors[.Cursor], accent)
	}
	s, d, err := parse_themes(
		"theme.name = top\ntheme.custom.top.base = middle\ntheme.custom.top.accent = #0a0b0c\n" +
		"theme.custom.middle.base = tide-dark\ntheme.custom.middle.cursor = accent\n",
		THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	testing.expect_value(t, s.active_theme.colors[.Cursor], settings.Theme_Color{0x0a, 0x0b, 0x0c, 255})
	testing.expect(t, .Cursor in s.active_theme.linked)
}

@(test)
colors_that_follow_each_other_in_a_loop_fall_back_with_a_diagnostic :: proc(t: ^testing.T) {
	s, d, err := parse_themes(
		"theme.name = mine\ntheme.custom.mine.text = muted\ntheme.custom.mine.muted = faint\n" +
		"theme.custom.mine.faint = text\ntheme.custom.mine.tab_text = text\ntheme.custom.mine.accent = #010203\n",
		THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	if testing.expect_value(t, len(d), 1) {
		testing.expect(t, strings.contains(d[0].message, "in a loop"))
		testing.expect(t, strings.contains(d[0].message, "text -> muted -> faint -> text"))
	}
	fallback := settings.theme_default()
	for token in ([?]settings.Theme_Token{.Text, .Muted, .Faint, .Tab_Text}) {
		testing.expect_value(t, s.active_theme.colors[token], fallback.colors[token])
	}
	testing.expect_value(t, explicit_links(s.active_theme), bit_set[settings.Theme_Token]{})
	testing.expect_value(t, s.active_theme.colors[.Accent], settings.Theme_Color{1, 2, 3, 255})
}

@(test)
a_link_to_an_unknown_color_or_one_that_may_be_empty_is_refused :: proc(t: ^testing.T) {
	s, d, err := parse_themes(
		"theme.name = mine\ntheme.custom.mine.cursor = acent\ntheme.custom.mine.text = text\n" +
		"theme.custom.mine.muted = cursor\ntheme.custom.mine.faint = #0a0b0c\n",
		THEMES,
	)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	if testing.expect_value(t, len(d), 3) {
		testing.expect(t, strings.contains(d[0].message, "no theme color is named \"acent\""))
		testing.expect(t, strings.contains(d[1].message, "cannot follow itself"))
		testing.expect(t, strings.contains(d[2].message, "may be empty"))
	}
	base := settings.theme_default()
	testing.expect_value(t, s.active_theme.colors[.Cursor], base.colors[.Cursor])
	testing.expect_value(t, s.active_theme.colors[.Text], base.colors[.Text])
	testing.expect_value(t, s.active_theme.colors[.Muted], base.colors[.Muted])
	testing.expect_value(t, s.active_theme.colors[.Faint], settings.Theme_Color{10, 11, 12, 255})
	testing.expect_value(t, explicit_links(s.active_theme), bit_set[settings.Theme_Token]{})
}

@(test)
no_shipped_theme_follows_a_color :: proc(t: ^testing.T) {
	count := 0
	for file in fixtures.SHIPPED_THEMES {
		theme, ok := fixtures.shipped_theme_file(file)
		if !ok {continue}
		count += 1
		testing.expect_value(t, explicit_links(theme), bit_set[settings.Theme_Token]{})
	}
	testing.expect(t, count >= 20)
}

@(test)
editing_a_color_to_follow_another_survives_save_copy_and_export :: proc(t: ^testing.T) {
	// The first edit of a theme file saves a custom copy that holds the link, not the color it showed.
	updated, created, issue, edit_error := edit_color("theme.name = tide-dark\n", "cursor", "accent", THEMES)
	defer delete(updated)
	defer delete(created)
	testing.expect_value(t, edit_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect(t, strings.contains(updated, "theme.custom.tide-dark-custom.cursor = accent\n"))
	s, d, err := parse_themes(updated, THEMES)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&d)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(d), 0)
	accent := fixtures.shipped_theme("tide-dark").colors[.Accent]
	testing.expect_value(t, s.active_theme.colors[.Cursor], accent)
	testing.expect_value(t, s.active_theme.target[.Cursor], settings.Theme_Token.Accent)

	// Changing the target moves the follower; the saved line for the follower stays a link.
	changed, _, _, change_error := settings.theme_color_edit(&s, updated, "accent", "#445566")
	defer delete(changed)
	testing.expect_value(t, change_error, settings.Theme_Edit_Error.None)
	moved, md, me := parse_themes(changed, THEMES)
	defer settings.destroy(&moved)
	defer settings.diagnostics_destroy(&md)
	testing.expect_value(t, me, nil)
	testing.expect_value(t, moved.active_theme.colors[.Cursor], settings.Theme_Color{0x44, 0x55, 0x66, 255})
	testing.expect(t, strings.contains(changed, "theme.custom.tide-dark-custom.cursor = accent\n"))

	// Unlinking keeps the resolved color as the color's own.
	unlinked, _, _, unlink_error := settings.theme_color_edit(&moved, changed, "cursor", "#445566")
	defer delete(unlinked)
	testing.expect_value(t, unlink_error, settings.Theme_Edit_Error.None)
	testing.expect(t, strings.contains(unlinked, "theme.custom.tide-dark-custom.cursor = #445566\n"))

	// A copy and an exported file keep the link as a link.
	copy, copy_id, copy_error := settings.theme_duplicate(&moved, changed)
	defer delete(copy)
	defer delete(copy_id)
	testing.expect_value(t, copy_error, settings.Theme_Edit_Error.None)
	testing.expect(t, strings.contains(copy, ".cursor = accent\n"))
	text, ok := settings.theme_file_text("exported", moved.active_theme, "Exported", allocator = context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(text, `"cursor": "accent"`))
	file, file_issue := settings.theme_file_parse(text)
	testing.expect_value(t, file_issue, "")
	testing.expect_value(t, file.linked, moved.active_theme.linked)
	testing.expect_value(t, settings.custom_theme_resolve(nil, &file), moved.active_theme)
}

@(test)
an_edit_that_would_make_a_loop_is_refused :: proc(t: ^testing.T) {
	source := "theme.name = mine\ntheme.custom.mine.base = tide-dark\ntheme.custom.mine.muted = text\n"
	updated, _, issue, edit_error := edit_color(source, "text", "muted", THEMES)
	defer delete(updated)
	testing.expect_value(t, edit_error, settings.Theme_Edit_Error.Invalid)
	testing.expect(t, strings.contains(issue, "in a loop"))
	testing.expect_value(t, updated, "")

	_, _, self_issue, self_error := edit_color(source, "text", "text", THEMES)
	testing.expect_value(t, self_error, settings.Theme_Edit_Error.Invalid)
	testing.expect(t, strings.contains(self_issue, "cannot follow itself"))
}

@(test)
theme_files_may_follow_colors_but_not_loop_or_name_unknown_ones :: proc(t: ^testing.T) {
	file, issue := settings.theme_file_parse(
		`{"version":1,"id":"shared","colors":{"accent":"#123456","cursor":"accent","focus":"pane_focus","pane_focus":"accent"}}`,
	)
	testing.expect_value(t, issue, "")
	resolved := settings.custom_theme_resolve(nil, &file)
	testing.expect_value(t, resolved.colors[.Focus], settings.Theme_Color{0x12, 0x34, 0x56, 255})
	testing.expect_value(t, resolved.colors[.Cursor], settings.Theme_Color{0x12, 0x34, 0x56, 255})
	for invalid in ([?]string {
		`{"version":1,"id":"shared","colors":{"text":"muted","muted":"text"}}`,
		`{"version":1,"id":"shared","colors":{"cursor":"acent"}}`,
		`{"version":1,"id":"shared","colors":{"text":"text"}}`,
		`{"version":1,"id":"shared","colors":{"muted":"cursor"}}`,
	}) {
		_, problem := settings.theme_file_parse(invalid)
		testing.expect(t, problem != "", invalid)
	}
}
