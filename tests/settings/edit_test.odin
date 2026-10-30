package settings_test

import "core:os"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
editing_a_theme_file_color_saves_and_selects_a_custom_theme :: proc(t: ^testing.T) {
	source := "# keep\r\ntheme.name = tide-light\r\nfont.size = 14\r\n"
	updated, created, issue, err := settings.theme_color_edit(
		source, "tab_bar", "rgb(1, 2, 3)", themes_directory = THEMES,
	)
	defer delete(updated)
	defer delete(created)
	testing.expect_value(t, err, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, created, "tide-light-custom")
	testing.expect(t, strings.has_prefix(updated, "# keep\r\n"))
	testing.expect(t, strings.contains(updated, "theme.custom.tide-light-custom.base = tide-light\r\n"))
	testing.expect(t, strings.contains(updated, "theme.custom.tide-light-custom.tab_bar = #010203\r\n"))
	s, diagnostics, parse_error := settings.parse(updated, themes_directory = THEMES)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.theme.name, "tide-light-custom")
	testing.expect_value(t, s.font.size, 14)
	testing.expect_value(t, s.active_theme.colors[.Tab_Bar], settings.Theme_Color{1, 2, 3, 255})
	base := shipped_theme("tide-light")
	testing.expect_value(t, s.active_theme.colors[.Text], base.colors[.Text])

	again, again_created, _, again_error := settings.theme_color_edit(updated, "border", "#11223344")
	defer delete(again)
	defer delete(again_created)
	testing.expect_value(t, again_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, again_created, "")
	testing.expect(t, strings.contains(again, "theme.custom.tide-light-custom.border = #11223344"))
	testing.expect(t, !strings.contains(again, "tide-light-custom-2"))

	reset, _, _, reset_error := settings.theme_color_edit(again, "tab_bar", "")
	defer delete(reset)
	testing.expect_value(t, reset_error, settings.Theme_Edit_Error.None)
	testing.expect(t, !strings.contains(reset, "tab_bar"))
	testing.expect(t, strings.contains(reset, "theme.custom.tide-light-custom.base"))

	unchanged, none, _, unchanged_error := settings.theme_color_edit(source, "tab_bar", "")
	defer delete(unchanged)
	defer delete(none)
	testing.expect_value(t, unchanged_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, unchanged, source)
	testing.expect_value(t, none, "")
}

@(test)
theme_color_edit_rejects_values_the_color_cannot_take :: proc(t: ^testing.T) {
	cases := [?][2]string{{"cursor", "not a color"}, {"tab_bar", "#12"}}
	for c in cases {
		updated, created, issue, err := settings.theme_color_edit("theme.name = studio\n", c[0], c[1])
		testing.expect_value(t, err, settings.Theme_Edit_Error.Invalid)
		testing.expect(t, issue != "")
		testing.expect_value(t, updated, "")
		delete(updated)
		delete(created)
	}
	updated, created, _, err := settings.theme_color_edit("", "unknown_color", "#000000")
	testing.expect_value(t, err, settings.Theme_Edit_Error.Unavailable)
	delete(updated)
	delete(created)
}

@(test)
themes_duplicate_rename_and_delete_as_whole_blocks :: proc(t: ^testing.T) {
	source := "theme.name = mine\ntheme.custom.mine.base = ember-dark\ntheme.custom.mine.cursor = #010203\n"
	copy, created, err := settings.theme_duplicate(source)
	defer delete(copy)
	defer delete(created)
	testing.expect_value(t, err, settings.Theme_Edit_Error.None)
	testing.expect_value(t, created, "mine-copy")
	s, diagnostics, parse_error := settings.parse(copy, themes_directory = THEMES)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.theme.name, "mine-copy")
	testing.expect_value(t, len(s.themes), 12)
	testing.expect_value(t, s.active_theme.colors[.Cursor], settings.Theme_Color{1, 2, 3, 255})
	testing.expect_value(t, settings.custom_theme_find(&s, "mine-copy").base, "ember-dark")
	settings.destroy(&s)
	settings.diagnostics_destroy(&diagnostics)

	renamed, issue, rename_error := settings.theme_rename(source, "night")
	defer delete(renamed)
	testing.expect_value(t, rename_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, issue, "")
	testing.expect_value(t, renamed, "theme.name = \"night\"\ntheme.custom.night.base = ember-dark\ntheme.custom.night.cursor = #010203\n")
	for id in ([?]string{"studio-dark", "Bad"}) {
		refused, reason, refuse_error := settings.theme_rename(source, id)
		testing.expect_value(t, refuse_error, settings.Theme_Edit_Error.Invalid)
		testing.expect(t, reason != "")
		delete(refused)
	}
	taken, taken_reason, taken_error := settings.theme_rename(copy, "mine")
	testing.expect_value(t, taken_error, settings.Theme_Edit_Error.Invalid)
	testing.expect_value(t, taken_reason, "Another theme uses this ID.")
	delete(taken)

	deleted, selected, delete_error := settings.theme_delete(source, themes_directory = THEMES)
	defer delete(deleted)
	defer delete(selected)
	testing.expect_value(t, delete_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, selected, "ember-dark")
	testing.expect_value(t, deleted, "theme.name = \"ember-dark\"\n")
	// Without its base file, deleting falls back to the default theme.
	orphan, orphan_selected, orphan_error := settings.theme_delete(source)
	defer delete(orphan)
	defer delete(orphan_selected)
	testing.expect_value(t, orphan_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, orphan_selected, settings.DEFAULT_THEME_ID)

	file_copy, file_created, file_error := settings.theme_duplicate(
		"theme.name = tide-dark\n", themes_directory = THEMES,
	)
	defer delete(file_copy)
	defer delete(file_created)
	testing.expect_value(t, file_error, settings.Theme_Edit_Error.None)
	testing.expect_value(t, file_created, "tide-dark-custom")
	testing.expect(t, strings.contains(file_copy, "theme.custom.tide-dark-custom.base = tide-dark\n"))
	for refuse in ([?]string{"theme.name = tide-dark\n", ""}) {
		_, _, unavailable := settings.theme_delete(refuse, themes_directory = THEMES)
		testing.expect_value(t, unavailable, settings.Theme_Edit_Error.Unavailable)
		_, _, rename_unavailable := settings.theme_rename(refuse, "x", themes_directory = THEMES)
		testing.expect_value(t, rename_unavailable, settings.Theme_Edit_Error.Unavailable)
	}
}

@(test)
legacy_color_overrides_migrate_into_a_custom_theme :: proc(t: ^testing.T) {
	source := "theme.name = tide-light\n\n" +
		"# Shell foreground; empty follows the theme.\ncolors.foreground =\n" +
		"# Default background color.\ncolors.background = #0f1115\n" +
		"# mine\ncolors.palette.3 = #112233\ncolors.selection_foreground =\nfont.size = 13\n"
	updated, migrated, err := settings.migrate_theme_text(source)
	defer delete(updated)
	testing.expect_value(t, err, nil)
	testing.expect(t, migrated)
	testing.expect(t, !strings.contains(updated, "colors."))
	testing.expect(t, !strings.contains(updated, "empty follows"))
	testing.expect(t, !strings.contains(updated, "Default background"))
	testing.expect(t, strings.contains(updated, "# mine\n"))
	s, diagnostics, parse_error := settings.parse(updated, themes_directory = THEMES)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, s.theme.name, "tide-light-custom")
	base := shipped_theme("tide-light")
	testing.expect_value(t, s.colors.background, settings.Color{0x0f, 0x11, 0x15})
	testing.expect_value(t, s.colors.palette[3], settings.Color{0x11, 0x22, 0x33})
	testing.expect_value(t, s.colors.foreground, base.colors[.Foreground].rgb)
	testing.expect(t, s.colors.selection_foreground == nil)
	testing.expect_value(t, s.font.size, 13)

	empty_only, empty_migrated, empty_error := settings.migrate_theme_text("colors.cursor =\nfont.size = 13\n")
	defer delete(empty_only)
	testing.expect_value(t, empty_error, nil)
	testing.expect(t, empty_migrated)
	testing.expect_value(t, empty_only, "font.size = 13\n")
	_, untouched, _ := settings.migrate_theme_text("font.size = 13\n")
	testing.expect(t, !untouched)
}

@(test)
editor_round_trips_every_schema_kind :: proc(t: ^testing.T) {
	s, err := settings.defaults()
	testing.expect_value(t, err, nil)
	defer settings.destroy(&s)
	for entry in settings.SCHEMA {
		text, message, edit_error := settings.edit_text("", entry.key, settings.value_text(&s, entry))
		testing.expect_value(t, edit_error, nil)
		testing.expect_value(t, message, "")
		parsed, diagnostics, parse_error := settings.parse(text)
		testing.expect_value(t, parse_error, nil)
		testing.expect_value(t, len(diagnostics), 0)
		testing.expect_value(t, settings.value_text(&parsed, entry), settings.value_text(&s, entry))
		settings.destroy(&parsed)
		settings.diagnostics_destroy(&diagnostics)
		delete(text)
		delete(message)
	}
}

@(test)
editor_preserves_unrelated_text_and_removes_target_duplicates :: proc(t: ^testing.T) {
	fixture :: "\xef\xbb\xbf# keep\r\nfont.size = 10\r\nunknown = raw # text\r\n\r\nfont.size = 14"
	text, message, err := settings.edit_text(fixture, "font.size", "15.5")
	defer delete(text)
	defer delete(message)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, message, "")
	testing.expect_value(t, text, "\xef\xbb\xbf# keep\r\nfont.size = 15.5\r\nunknown = raw # text\r\n\r\n")
	appended, m, e := settings.edit_text("# no newline", "shell.command", `  pwsh -c "echo #hello"  `)
	defer delete(appended)
	defer delete(m)
	testing.expect_value(t, e, nil)
	parsed, diagnostics, parse_error := settings.parse(appended)
	defer settings.destroy(&parsed)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, parse_error, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect_value(t, parsed.shell.command, `  pwsh -c "echo #hello"  `)
	testing.expect(t, strings.has_prefix(appended, "# no newline\n"))
}

@(test)
editor_rejects_invalid_values_without_output :: proc(t: ^testing.T) {
	for pair in ([?][2]string{
		{"font.size", "0"}, {"font.size", "NaN"}, {"font.size", "inf"},
		{"cursor.style", "triangle"}, {"cursor.blink", "yes"},
		{"window.rows", "2.5"}, {"theme.custom.mine.cursor", "#ffffff0"},
		{"theme.custom.mine.border", "#ffffff8"}, {"theme.custom.Studio.cursor", "#ffffff"},
		{"font.family", ""}, {"shell.command", "bad\ncommand"}, {"font.family", "\xff"},
		{"unknown", "anything"}, {"keys.edit.copy", "bad\x00value"},
	}) {
		text, message, err := settings.edit_text("# original", pair[0], pair[1])
		testing.expect_value(t, err, nil)
		testing.expect_value(t, text, "")
		testing.expect(t, message != "")
		delete(text)
		delete(message)
	}
}

@(test)
editor_save_detects_conflicts_and_cleans_up :: proc(t: ^testing.T) {
	context.logger = {}
	dir, err := os.make_directory_temp("", "aio-settings-*", context.allocator)
	testing.expect_value(t, err, nil)
	if err != nil { return }
	defer delete(dir)
	defer os.remove(dir)
	path := strings.concatenate({dir, "/settings.ini"}, context.temp_allocator)
	defer os.remove(path)
	testing.expect_value(t, os.write_entire_file(path, "original"), nil)
	testing.expect_value(t, settings.save(path, "original", "updated"), settings.Save_Error.None)
	testing.expect_value(t, settings.save(path, "original", "lost update"), settings.Save_Error.Conflict)
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(data), "updated")
	testing.expect_value(t, os.remove(path), nil)
	testing.expect_value(t, settings.save(path, "updated", "recreated"), settings.Save_Error.IO)
	folder, open_error := os.open(dir)
	testing.expect_value(t, open_error, nil)
	defer os.close(folder)
	files, list_error := os.read_dir(folder, -1, context.temp_allocator)
	testing.expect_value(t, list_error, nil)
	testing.expect_value(t, len(files), 0)
}
