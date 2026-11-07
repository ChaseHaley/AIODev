package settings_test

import "aio:settings"
import "base:runtime"
import "core:os"
import "core:strings"
import w "core:sys/windows"
import "core:testing"

@(private = "file")
Logged :: struct {
	errors: int,
}

// Counts errors the failed migration save reports, which would otherwise fail the test.
@(private = "file")
logged_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	if level >= .Error {(^Logged)(data).errors += 1}
}

// A migration whose save fails runs the migrated text but hands out the text the file still holds,
// so a page built from it saves against the file rather than conflicting forever.
@(test)
load_source_is_the_file_when_its_migration_cannot_save :: proc(t: ^testing.T) {
	directory, directory_error := os.mkdir_temp("tests/settings", "migration-", context.allocator)
	testing.expect_value(t, directory_error, nil)
	if directory_error != nil {return}
	defer delete(directory)
	defer testing.expect_value(t, os.remove_all(directory), nil)
	path, path_error := strings.concatenate({directory, "/settings.ini"})
	testing.expect_value(t, path_error, nil)
	if path_error != nil {return}
	defer delete(path)
	legacy := "shell.command = cmd.exe\r\nshell.directory = C:\\\r\nfont.size = 12\r\n"
	testing.expect_value(t, os.write_entire_file(path, legacy), nil)
	// Readers may share the file, but nothing may replace it while this handle is open.
	wide := w.utf8_to_wstring(path, context.temp_allocator)
	lock := w.CreateFileW(wide, w.GENERIC_READ, w.FILE_SHARE_READ, nil, w.OPEN_EXISTING, w.FILE_ATTRIBUTE_NORMAL, nil)
	if !testing.expect(t, lock != w.INVALID_HANDLE_VALUE) {return}
	logged: Logged
	previous := context.logger
	context.logger = {procedure = logged_proc, data = &logged, lowest_level = .Debug}
	source: string
	s, diagnostics, created, migrated, migration_error, err := settings.load(path, source_out = &source)
	context.logger = previous
	w.CloseHandle(lock)
	defer delete(source)
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, created, false)
	testing.expect_value(t, migrated, false)
	testing.expect_value(t, migration_error, settings.Save_Error.IO)
	testing.expect(t, logged.errors > 0)
	testing.expect_value(t, settings.profile_base(&s.profiles).command, "cmd.exe")
	testing.expect_value(t, source, legacy)
	text, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, read_error, nil)
	testing.expect_value(t, string(text), source)
}
