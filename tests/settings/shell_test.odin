package settings_test

import "core:testing"
import "aio:settings"

@(test)
shell_badges_follow_the_launched_executable_and_explicit_override :: proc(t: ^testing.T) {
	for row in ([?][3]string{
		{"pwsh.exe -NoLogo", "pwsh", ">_"},
		{"  \"C:\\Program Files\\PowerShell\\7\\pwsh.EXE\" -NoLogo", "pwsh", ">_"},
		{"C:\\Windows\\System32\\CMD.EXE /k", "CMD", "C:"},
		{"wsl.exe --distribution Debian", "wsl", "$"},
		{"/bin/bash --login", "bash", "$"},
		{"custom-shell.exe", "custom-shell", ">_"},
		{"", "", ">_"},
	}) {
		executable := settings.shell_executable(row[0])
		testing.expect_value(t, executable, row[1])
		testing.expect_value(t, settings.shell_icon(executable, ""), row[2])
		testing.expect_value(t, settings.shell_icon(executable, "λ"), "λ")
	}
}

@(test)
reported_directories_decode_file_uris_without_corrupting_plain_paths :: proc(t: ^testing.T) {
	for row in ([?][2]string{
		{"file://machine/C:/Users/Some%20Name", "C:/Users/Some Name"},
		{"file:///home/user/caf%C3%A9", "/home/user/café"},
		{"C:\\literal%20name", "C:\\literal%20name"},
		{"/home/user", "/home/user"},
		{"file:///bad%XX%00", "/bad%XX%00"},
		{"file:///bad%ff", "file:///bad%ff"},
		{"", ""},
	}) {
		text, err := settings.directory_label(row[0])
		defer delete(text)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, text, row[1])
	}
}

@(test)
header_settings_reload_and_serialize_through_the_shared_schema :: proc(t: ^testing.T) {
	s, diagnostics, err := settings.parse("pane.show_headers=false\nshell.icon=λ\n")
	defer settings.destroy(&s)
	defer settings.diagnostics_destroy(&diagnostics)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(diagnostics), 0)
	testing.expect(t, !s.pane.show_headers)
	testing.expect_value(t, s.shell.icon, "λ")
	testing.expect_value(t, settings.value_text(&s, settings.schema_find("pane.show_headers")^), "false")
}
