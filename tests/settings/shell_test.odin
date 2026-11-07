package settings_test

import "core:testing"
import "core:strings"
import "aio:settings"

@(test)
shell_badges_follow_the_launched_executable :: proc(t: ^testing.T) {
	for row in ([?][3]string{
		{"pwsh.exe -NoLogo", "pwsh", ">_"},
		{"  \"C:\\Program Files\\PowerShell\\7\\pwsh.EXE\" -NoLogo", "pwsh", ">_"},
		{"C:\\Windows\\System32\\CMD.EXE /k", "CMD", "C:"},
		{"wsl.exe --distribution Debian", "wsl", "$"},
		{"/bin/bash --login", "bash", "$"},
		{"custom-shell.exe", "custom-shell", ">_"},
		{"", "", ">_"},
	}) {
		testing.expect_value(t, settings.shell_executable(row[0]), row[1])
		testing.expect_value(t, settings.shell_badge(row[0]), row[2])
	}
}

@(test)
display_titles_strip_controls_and_cap_at_a_complete_utf8_rune :: proc(t: ^testing.T) {
	title := settings.display_title("hello\n\t\x7f\u0085world 🧪")
	defer delete(title)
	testing.expect_value(t, title, "helloworld 🧪")
	long := strings.repeat("🧪", 300, context.temp_allocator)
	capped := settings.display_title(long)
	defer delete(capped)
	testing.expect_value(t, len(capped), 1024)
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
	testing.expect_value(t, settings.profile_base(&s.profiles).icon, "λ")
	testing.expect_value(t, settings.value_text(&s, settings.schema_find("pane.show_headers")^), "false")
}

@(test)
shell_integration_wraps_only_interactive_powershell :: proc(t: ^testing.T) {
	for command in ([?]string{"pwsh.exe -NoLogo -NoProfile", "powershell.exe -NoLogo",
		"pwsh -ExecutionPolicy Bypass -NoLogo", `pwsh -wd C:\src`, `"C:\Program Files\PowerShell\7\pwsh.exe"`}) {
		testing.expect_value(t, settings.shell_command_line(command, false), command)
		wrapped := settings.shell_command_line(command, true)
		testing.expect(t, strings.has_prefix(wrapped, strings.concatenate({command, " -NoExit -EncodedCommand "}, context.temp_allocator)), wrapped)
	}
	for command in ([?]string{"pwsh -c Write-Host", "pwsh -Command Get-Date", "pwsh -File test.ps1",
		"pwsh test.ps1", "pwsh -EncodedCommand ABC", "pwsh -NonInteractive", "cmd.exe /d", "wsl.exe", ""}) {
		testing.expect_value(t, settings.shell_command_line(command, true), command)
	}
}
