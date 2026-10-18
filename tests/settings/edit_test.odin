package settings_test

import "core:os"
import "core:fmt"
import "core:strings"
import "core:testing"
import "aio:settings"

@(test)
follow_theme_resets_only_shell_defaults_explicitly :: proc(t: ^testing.T) {
	for pair in ([?][2]string{{"#0f1115", "#d6dae0"}, {"#123456", "#abcdef"}}) {
		source := fmt.tprintf("# keep\r\ntheme.mode = light\r\ncolors.background = %s\r\n"+
			"colors.foreground = %s\r\ncolors.palette.1 = #112233\r\n"+
			"colors.cursor = #445566\r\nfont.size = 14\r\n", pair[0], pair[1])
		before, issues, parse_error := settings.parse(source)
		defer settings.destroy(&before)
		defer settings.diagnostics_destroy(&issues)
		testing.expect_value(t, parse_error, nil)
		testing.expect(t, before.color_overrides.background != nil)
		text, err := settings.follow_theme_text(source)
		defer delete(text)
		testing.expect_value(t, err, nil)
		after, diagnostics, after_error := settings.parse(text)
		defer settings.destroy(&after)
		defer settings.diagnostics_destroy(&diagnostics)
		testing.expect_value(t, after_error, nil)
		testing.expect_value(t, len(diagnostics), 0)
		testing.expect_value(t, after.colors.background, settings.theme_resolve(after.theme).terminal.background)
		testing.expect_value(t, after.colors.foreground, settings.theme_resolve(after.theme).terminal.foreground)
		testing.expect_value(t, after.colors.palette[1], settings.Color{0x11, 0x22, 0x33})
		testing.expect_value(t, after.colors.cursor, settings.Color{0x44, 0x55, 0x66})
		testing.expect(t, strings.has_prefix(text, "# keep\r\n"))
		testing.expect_value(t, after.font.size, 14)
		again, again_error := settings.follow_theme_text(text)
		defer delete(again)
		testing.expect_value(t, again_error, nil)
		testing.expect_value(t, again, text)
	}
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
		{"window.rows", "2.5"}, {"colors.cursor", "#ffffff0"},
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
