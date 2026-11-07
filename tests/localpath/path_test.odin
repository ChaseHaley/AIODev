package localpath_test

import "aio:localpath"
import "base:runtime"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
path_shapes_name_drive_prefixes_without_authorizing_them :: proc(t: ^testing.T) {
	for row in ([?]struct {path: string, prefix, absolute, local: bool} {
		{`C:\a.txt`, true, true, true},
		{`c:/a.txt`, true, true, true},
		{`C:a.txt`, true, false, false},
		{`C:`, true, false, false},
		{`1:\a.txt`, false, false, false},
		{`\\server\share`, false, false, false},
		{`C:\a.txt:stream`, true, true, false},
		{`C:\NUL`, true, true, false},
		{`relative\a.txt`, false, false, false},
	}) {
		testing.expectf(t, localpath.has_drive_prefix(row.path) == row.prefix, "%q prefix", row.path)
		testing.expectf(t, localpath.is_drive_absolute(row.path) == row.absolute, "%q absolute", row.path)
		testing.expectf(t, localpath.local_absolute(row.path) == row.local, "%q local", row.path)
	}
}

@(test)
active_file_types_need_confirmation_even_without_pathext :: proc(t: ^testing.T) {
	for path in ([?]string{`C:\a.EXE`, `C:\a.ps1`, `C:\a.lnk`, `C:\a.url`, `C:\a.msi`,
		`C:\a.hta`, `C:\a.scf`, `C:\a.library-ms`, `C:\a.settingcontent-ms`, `C:\a.appref-ms`,
		`C:\a.msu`, `C:\a.search-ms`, `C:\a.iqy`, `C:\a.xll`, `C:\a.iso`, `C:\a.vhdx`}) {
		testing.expectf(t, localpath.file_needs_confirmation(path, ""), "%s must be confirmed", path)
	}
	testing.expect(t, localpath.file_needs_confirmation(`C:\a.custom`, ".EXE;;.CUSTOM;"))
	testing.expect(t, !localpath.file_needs_confirmation(`C:\a.txt`, ".EXE;;"))
}

@(test)
home_expansion_covers_only_the_home_prefixes :: proc(t: ^testing.T) {
	home, home_error := os.user_home_dir(context.allocator)
	defer delete(home)
	for input in ([]string{"~", "~/child", "~\\child", "~other", "relative"}) {
		output, expand_error := localpath.expand_home(input)
		defer delete(output)
		if input == "~" || strings.has_prefix(input, "~/") || strings.has_prefix(input, "~\\") {
			testing.expect_value(t, expand_error, home_error)
			if home_error != nil {continue}
		} else {testing.expect_value(t, expand_error, nil)}
		if input == "~" {
			testing.expect_value(t, output, home)
		}
		if strings.has_prefix(input, "~/") || strings.has_prefix(input, "~\\") {
			testing.expect(t, strings.has_prefix(output, home))
		} else if input != "~" {testing.expect_value(t, output, input)}
	}
	path, path_error := localpath.expand_home("relative", runtime.nil_allocator())
	testing.expect_value(t, path, "")
	testing.expect_value(t, path_error, os.Error(runtime.Allocator_Error.Out_Of_Memory))
}

@(test)
settings_paths_resolve_beside_the_settings_file :: proc(t: ^testing.T) {
	relative, relative_error := localpath.settings_relative(`icons\a.png`, `C:\cfg\settings.ini`)
	defer delete(relative)
	testing.expect_value(t, relative_error, localpath.Settings_Path_Error.None)
	testing.expect_value(t, relative, `C:\cfg\icons\a.png`)
	absolute, absolute_error := localpath.settings_relative(`D:\a.png`, `C:\cfg\settings.ini`)
	defer delete(absolute)
	testing.expect_value(t, absolute_error, localpath.Settings_Path_Error.None)
	testing.expect_value(t, absolute, `D:\a.png`)
	_, failed := localpath.settings_relative("a.png", `C:\cfg\settings.ini`, runtime.nil_allocator())
	testing.expect_value(t, failed, localpath.Settings_Path_Error.Expand)
}

@(test)
reported_directories_decode_file_uris_without_corrupting_plain_paths :: proc(t: ^testing.T) {
	for row in ([?][2]string{
		{"file://machine/C:/Users/Some%20Name", `C:\Users\Some Name`},
		{"file://server/share/Some%20Name", `\\server\share\Some Name`},
		{`C:/Users/mixed\path`, `C:\Users\mixed\path`},
		{"//server/share", `\\server\share`},
		{"file:///home/user/caf%C3%A9", "/home/user/café"},
		{"C:\\literal%20name", "C:\\literal%20name"},
		{"/home/user", "/home/user"},
		{"file:///bad%XX%00", "/bad%XX%00"},
		{"file:///bad%ff", "file:///bad%ff"},
		{"", ""},
	}) {
		text, err := localpath.directory_label(row[0])
		defer delete(text)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, text, row[1])
	}
}
